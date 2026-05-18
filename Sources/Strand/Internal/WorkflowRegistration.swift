import Logging
import Metrics
import NIOCore
import PostgresNIO
import ServiceLifecycle
import Synchronization
import Tracing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Workflow._makeToken() default implementation
//
// Lives here (not Workflow.swift) because it closes over _WorkflowTaskCache<Self>
// and WorkflowRegistration<Self>, both defined in this file.
// The cache is created once per workflow TYPE at registration time and shared
// across every activation of that type, enabling the cached-Task model.
extension Workflow {
    public static func _makeToken() -> _WorkflowToken {
        let cache = _WorkflowTaskCache<Self>()
        return _WorkflowToken(name: workflowName, preferredQueue: nil) { claimed, exec in
            try await WorkflowRegistration<Self>().activate(
                claimed: claimed,
                exec: exec,
                cache: cache
            )
        }
    }
}

// MARK: - _WorkflowTaskCache

/// Per-workflow-type cache of live handler Tasks.
///
/// One instance per workflow type, created at token-registration time and captured
/// by the token closure. The handler `Task` stays parked on its continuations
/// between activations, consuming no thread. On re-activation the worker delivers
/// real results via the Resume API and calls `drain()` to continue from where
/// the handler paused.
///
/// `@unchecked Sendable`: access to the dictionary is serialised by the `Mutex`;
/// access to the cached executor is serialised by Postgres
/// (`FOR UPDATE SKIP LOCKED` prevents two workers from claiming the same run).
final class _WorkflowTaskCache<W: Workflow>: @unchecked Sendable {

    struct CachedState: @unchecked Sendable {
        let executor: StrandWorkflowExecutor
        let task: Task<Void, Never>
        let handlerResult: ArcBox<Result<W.Output, Error>?>
        let stateBox: ArcBox<W>
        let activation: _WorkflowActivation<W>
    }

    private let _mutex = Mutex<[UUID: CachedState]>([:])

    func get(_ taskID: UUID) -> CachedState? {
        _mutex.withLock { $0[taskID] }
    }

    func set(_ taskID: UUID, _ state: CachedState) {
        _mutex.withLock { $0[taskID] = state }
    }

    func remove(_ taskID: UUID) {
        _ = _mutex.withLock { $0.removeValue(forKey: taskID) }
    }

    /// Cancel every cached Task — called on worker shutdown so that all
    /// parked handler Tasks are torn down cleanly.
    func cancelAll() {
        _mutex.withLock { states in
            for (_, state) in states {
                state.executor.cancelPending()
                state.executor.drain()
                state.task.cancel()
            }
            states.removeAll()
        }
    }

    /// Cancel and evict ONE workflow’s handler Task.
    ///
    /// Called from `WorkflowRegistration.activate`’s cancellation handler so
    /// that a `ClaimTimeoutError` or unexpected failure on workflow A does
    /// **not** cancel the handler Tasks of unrelated workflows B, C, … that
    /// are running concurrently on the same worker.
    ///
    /// For worker shutdown every active activation fires this independently
    /// for its own `taskID` — the net result is identical to `cancelAll()`
    /// but without cross-contamination between workflows.
    func evictOne(_ taskID: UUID) {
        let cached = _mutex.withLock { states -> CachedState? in
            defer { states.removeValue(forKey: taskID) }
            return states[taskID]
        }
        guard let cached else { return }
        cached.executor.cancelPending()
        cached.executor.drain()
        cached.task.cancel()
    }
}

// MARK: - WorkflowRegistration

/// Internal activation implementation for `Workflow`-conforming types.
struct WorkflowRegistration<W: Workflow>: Sendable {

    /// Runs one activation of workflow type `W` for the given claimed task.
    ///
    /// Returns the encoded result `ByteBuffer` on successful completion, or `nil`
    /// when the activation suspended (handler Task left parked on a continuation).
    func activate(
        claimed: ClaimedTask,
        exec: _WorkerExec,
        cache: _WorkflowTaskCache<W>
    ) async throws -> ByteBuffer? {
        // Cancellation handler: fires when THIS activation task is cancelled
        // (ClaimTimeoutError, worker shutdown, or any other fatal error).
        //
        // Critically: use evictOne rather than cancelAll.
        // cancelAll() would cancel the handler Tasks of EVERY workflow currently
        // running on this worker, not just the one that timed out. That would
        // orphan workflows B, C, … whenever workflow A hits its claim timeout.
        //
        // evictOne() cancels only this workflow’s handler Task and removes it
        // from the cache. The next attempt (failRun creates attempt N+1) will
        // then take the fresh path (_activate) and rebuild from checkpoints
        // rather than trying to resumeActivation on a cancelled handler.
        //
        // Worker shutdown: each concurrent activation fires evictOne for its own
        // taskID independently — net result is identical to cancelAll, just
        // scoped correctly.
        try await withTaskCancellationHandler {
            try await _activate(claimed: claimed, exec: exec, cache: cache)
        } onCancel: {
            cache.evictOne(claimed.taskID)
        }
    }

    private func _activate(
        claimed: ClaimedTask,
        exec: _WorkerExec,
        cache: _WorkflowTaskCache<W>
    ) async throws -> ByteBuffer? {

        // ── Cached path: Task is alive and parked on its continuations ────────────
        if let cached = cache.get(claimed.taskID) {
            return try await resumeActivation(claimed: claimed, exec: exec, cached: cached, cache: cache)
        }

        // ── Fresh path: first activation (or after a crash / cache miss) ─────────

        // ── 1. Checkpoint cache ───────────────────────────────────────────────────
        let checkpointRows = try await Queries.getCheckpointStates(
            on: exec.postgres,
            taskID: claimed.taskID,
            logger: exec.logger
        )
        var checkpointCache: [Int: ByteBuffer] = [:]
        var checkpointNameCache: [Int: String] = [:]
        for row in checkpointRows {
            checkpointCache[row.seqNum] = row.stateBuffer
            checkpointNameCache[row.seqNum] = row.name
        }

        // ── 1b. Version marker cache ─────────────────────────────────────────────
        let versionMarkerRows = try await WorkflowStateQueries.listVersionMarkers(
            on: exec.postgres,
            namespaceID: exec.namespace,
            taskID: claimed.taskID,
            logger: exec.logger
        )
        var versionMarkerCache: [String: Bool] = [:]
        for row in versionMarkerRows { versionMarkerCache[row.changeID] = row.value }

        // ── 2. Workflow state ────────────────────────────────────────────────────
        let storedStateBuf = try await WorkflowStateQueries.loadState(
            on: exec.postgres,
            taskID: claimed.taskID,
            namespaceID: exec.namespace,
            logger: exec.logger
        )
        var workflowState: W
        if let buf = storedStateBuf {
            // Restore the struct exactly as it was at the end of the previous activation.
            workflowState = try JSON.decode(W.self, from: buf)
        } else {
            // First activation — no stored state yet. Use the protocol-required
            // `init()` so non-optional stored properties work without any
            // Codable boilerplate (no custom `init(from:)` needed).
            workflowState = W()
        }

        // ── History sequence ──────────────────────────────────────────────────
        // Use historySeq == 1 (no events written yet) as the "first activation" signal
        // instead of `storedStateBuf == nil`. `workflow_state` is only saved on signal
        // delivery or completion, so storedStateBuf is nil on every pure activity-wait
        // re-activation — causing a duplicate WORKFLOW_STARTED event.
        var historySeq = try await WorkflowStateQueries.nextHistorySeq(
            on: exec.postgres,
            taskID: claimed.taskID,
            logger: exec.logger
        )
        // Count of events written before this activation — exposed via ctx.historyEventCount.
        let historyEventCount = historySeq - 1
        let isFirstActivation = historySeq == 1
        if isFirstActivation {
            try await WorkflowStateQueries.appendHistory(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                seq: historySeq,
                eventType: .workflowStarted,
                eventData: nil,
                logger: exec.logger
            )
            historySeq += 1
        }

        // ── 3. Signals ────────────────────────────────────────────────────────────
        try await applyAndPersistSignals(to: &workflowState, exec: exec, claimed: claimed, historySeq: &historySeq)

        // ── 4. Pre-load results the executor needs for fast-path replay ───────────
        let executor = StrandWorkflowExecutor()

        // 4a. Terminal child activities — runActivity / runChildWorkflow returns or
        //     throws immediately for these (COMPLETED = return, FAILED = throw).
        let completedChildren = try await WorkflowStateQueries.loadCompletedChildActivities(
            on: exec.postgres,
            parentTaskID: claimed.taskID,
            logger: exec.logger
        )
        executor.resolveCompleted(completedChildren)
        // CHILD_WORKFLOW_COMPLETED history is written by the step-2 loop in
        // applyScheduleCommands when it processes the .childWorkflowCompleted command.
        // runChildWorkflow emits that command exactly once — a checkpoint written
        // alongside it causes subsequent replays to short-circuit at fast-path-1.

        // ── 5. Build activation context ────────────────────────────────────────────
        // Capture wall-clock time once here so WorkflowContext.activationTime
        // is stable for the entire duration of this activation.
        let activationTime = Date()
        let claimTimeoutSecs = Int(exec.options.claimTimeout.components.seconds)
        let stateBox = ArcBox(workflowState)
        let activation = _WorkflowActivation<W>(
            taskUUID: claimed.taskID,
            runUUID: claimed.runID,
            taskName: claimed.taskName,
            queueName: exec.queue,
            attempt: claimed.attempt,
            claimTimeoutSeconds: claimTimeoutSecs,
            wakeEvent: claimed.wakeEvent,
            eventPayload: claimed.eventPayloadBuffer,
            headers: claimed.headers,
            schedulingMetadata: claimed.schedulingMetadata,
            postgres: exec.postgres,
            logger: exec.logger,
            executor: executor,
            stateBox: stateBox,
            checkpointCache: checkpointCache,
            checkpointNameCache: checkpointNameCache,
            versionMarkerCache: versionMarkerCache,
            namespace: exec.namespace,
            activationTime: activationTime,
            historyEventCount: historyEventCount
        )
        let context = WorkflowContext<W>(activation: activation)
        let input = try JSON.decode(W.Input.self, from: claimed.paramsBuffer)

        // ── 6. Run handler on the executor ─────────────────────────────────────────
        // All WorkflowContext operations (runActivity, sleep, waitForEvent, uuid, random)
        // emit WorkflowCommands into executor.pendingCommands — zero DB I/O inside the
        // handler. When a task suspends (pending activity, timer, event), it parks a
        // CheckedContinuation in the executor.
        //
        // ArcBox<Result?> shares the handler outcome between the Task closure and the
        // outer activation code through the serial drain() synchronisation point.
        // No concurrent mutations occur in practice: the closure runs only during
        // drain(), which returns before the outer code reads handlerResult.
        let handlerResult = ArcBox<Result<W.Output, Error>?>(nil)
        let handlerTask = Task(executorPreference: executor) {
            do {
                let output = try await stateBox.value.run(context: context, input: input)
                handlerResult.value = .success(output)
            } catch {
                handlerResult.value = .failure(error)
            }
        }

        // Run the handler on the serial executor until it either completes or
        // every in-flight task has parked its continuation (pending activity,
        // timer, or event wait).
        executor.drain()

        // ── Condition fast-path ─────────────────────────────────────
        // A signal or state change may have arrived before the handler reached
        // context.condition — evaluate immediately rather than parking the run.
        // Each resume may unblock more of the handler and emit new commands,
        // so drain after each satisfied condition until none remain.
        while executor.evaluateAndResumeFirstSatisfiedCondition() {
            executor.drain()
        }

        // ── Local activity execution loop ─────────────────
        try await runLocalActivities(
            exec: exec,
            claimed: claimed,
            executor: executor,
            activation: activation,
            handlerResult: handlerResult,
            claimTimeoutSecs: claimTimeoutSecs,
            expireConditions: false
        )

        // ── 7. Apply commands, handle result, suspend or complete ─────────────────
        return try await applyScheduleCommands(
            commands: executor.pendingCommands,
            executor: executor,
            claimed: claimed,
            exec: exec,
            activation: activation,
            cache: cache,
            handlerResult: handlerResult,
            handlerTask: handlerTask,
            stateBox: stateBox,
            historySeq: &historySeq,
            claimTimeoutSecs: claimTimeoutSecs
        )
    }

    // MARK: - Cached re-activation

    /// Re-activates a workflow whose handler Task is still alive and parked on
    /// continuations from the previous activation.
    ///
    /// Instead of replaying the handler from scratch this method:
    ///   1. Applies any pending signals to the live `stateBox`.
    ///   2. Writes checkpoints for newly completed child activities.
    ///   3. Resumes the specific continuations that now have results.
    ///   4. Calls `drain()` to let the handler continue from where it paused.
    ///   5. Applies new schedule commands to Postgres (identical to fresh path).
    private func resumeActivation(
        claimed: ClaimedTask,
        exec: _WorkerExec,
        cached: _WorkflowTaskCache<W>.CachedState,
        cache: _WorkflowTaskCache<W>
    ) async throws -> ByteBuffer? {

        let executor = cached.executor
        let handlerResult = cached.handlerResult
        let stateBox = cached.stateBox
        let activation = cached.activation
        let handlerTask = cached.task
        let claimTimeoutSecs = Int(exec.options.claimTimeout.components.seconds)

        // ── History sequence ──────────────────────────────────────────────────
        var historySeq = try await WorkflowStateQueries.nextHistorySeq(
            on: exec.postgres,
            taskID: claimed.taskID,
            logger: exec.logger
        )
        let historyEventCount = historySeq - 1
        // Refresh the history event count on each cached re-activation so
        // ctx.historyEventCount reflects accumulated events across all prior activations.
        cached.activation.historyEventCount = historyEventCount

        // ── External checkpoint refresh ──────────────────────────────────────────────
        // `client.markVersion` writes checkpoints directly to the DB without sending
        // a signal. It is only meaningful during a workflow sleep (timer wait), so we
        // only scan for external writes when the run was NOT woken by a child-workflow
        // or event completion (those set wake_event; timers and signals leave it nil).
        // On the hot path (child completion, wake_event != nil) we skip the scan
        // entirely — eliminating a full checkpoint-table roundtrip per child.
        if claimed.wakeEvent == nil {
            let freshCheckpoints = try await Queries.getCheckpointStates(
                on: exec.postgres,
                taskID: claimed.taskID,
                logger: exec.logger
            )
            for row in freshCheckpoints where activation.cachedCheckpoint(for: row.seqNum) == nil {
                activation.cacheCheckpoint(seqNum: row.seqNum, name: row.name, buffer: row.stateBuffer)
            }
            // Refresh version markers — picks up markVersion(...) calls made while the
            // workflow was sleeping between activations.
            let freshMarkers = try await WorkflowStateQueries.listVersionMarkers(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                logger: exec.logger
            )
            for marker in freshMarkers {
                // Always overwrite — markVersion can change the value while workflow sleeps.
                activation.cacheVersionMarker(changeID: marker.changeID, value: marker.value)
            }
        }

        // ── Signals ──────────────────────────────────────────────────────────
        try await applyAndPersistSignals(to: &stateBox.value, exec: exec, claimed: claimed, historySeq: &historySeq)

        // ── Completed children ──────────────────────────────────────────────────
        let completedChildren = try await WorkflowStateQueries.loadCompletedChildActivities(
            on: exec.postgres,
            parentTaskID: claimed.taskID,
            logger: exec.logger
        )

        // Child-activity results are already durable in strand.task_completions.
        // The crash-recovery (fresh) path reads them from there via fast path 2
        // (resolveCompleted → preloadedResults), so writing them again to
        // strand.checkpoints is redundant.  We still extend the claim so that
        // activations processing many simultaneous completions don't expire.
        if !completedChildren.isEmpty {
            try await Queries.extendClaim(
                on: exec.postgres,
                namespaceID: exec.namespace,
                runID: claimed.runID,
                extendBySeconds: claimTimeoutSecs,
                logger: exec.logger
            )
        }

        // Populate preloaded results and start-time metadata. The start-time metadata
        // feeds ACTIVITY_STARTED history writes in applyScheduleCommands. The preloaded
        // results enable fast-path-2 for any sibling activities that also completed
        // concurrently but whose continuations are not yet parked.
        executor.resolveCompleted(completedChildren)

        // CHILD_WORKFLOW_COMPLETED history is written by the step-2 loop — see _activate.

        // ── Event/timer checkpoint (before resuming, for durability) ──────────
        if let eventName = claimed.wakeEvent,
            let seqNum = executor.seqNum(forEventName: eventName),
            activation.cachedCheckpoint(for: seqNum) == nil
        {
            if let payload = claimed.eventPayloadBuffer {
                try await Queries.batchSetCheckpoints(
                    on: exec.postgres,
                    namespaceID: exec.namespace,
                    taskID: claimed.taskID,
                    runID: claimed.runID,
                    checkpoints: [(seqNum: seqNum, name: "waitForEvent:\(eventName)", state: payload)],
                    extendClaimBySeconds: claimTimeoutSecs,
                    logger: exec.logger
                )
                activation.cacheCheckpoint(seqNum: seqNum, buffer: payload)
            }
        }

        // ── Resume parked continuations ───────────────────────────────────────
        // Clear commands from the previous activation before re-draining.
        executor.clearPendingCommands()

        for (seqNum, result, failureReason, state, kind, name, _, _, _) in completedChildren {
            switch state {
            case .completed:
                if let result { executor.resumeActivity(seqNum: seqNum, result: result) }
            case .failed, .cancelled:
                // Detect timeout: ClaimTimeoutError appears in the failure reason
                // when the 2x claim-window threshold is exceeded.
                // ClaimTimeoutError.failureName is derived from the type name, not
                // a bare string literal — rename-safe.
                let isTimeout: Bool =
                    failureReason.flatMap {
                        ActivityFailure.decode(from: $0)
                    }.map { $0.name == ClaimTimeoutError.failureName } ?? false
                let retryState: ActivityRetryState =
                    state == .cancelled ? .cancelled : isTimeout ? .timedOut : .maximumAttemptsReached
                let err: Error
                if kind == .workflow {
                    err = WorkflowError(workflowName: name, state: state)
                } else {
                    // Use _ActivityFailureSignal so runActivity<A> can decode A.Failure.
                    err = _ActivityFailureSignal(
                        failureReason: failureReason,
                        retryState: retryState,
                        activityName: name,
                        state: state
                    )
                }
                executor.resumeActivityFailure(seqNum: seqNum, error: err)
            default:
                break
            }
        }

        if let eventName = claimed.wakeEvent,
            let seqNum = executor.seqNum(forEventName: eventName)
        {
            if let payload = claimed.eventPayloadBuffer {
                // Resume the parked waitForEvent continuation. The slow-path code
                // in WorkflowContext.waitForEvent emits .eventReceived after the
                // continuation returns, which applyScheduleCommands (step-2 loop)
                // records in workflow_history. Writing it here as well would produce
                // a duplicate EVENT_RECEIVED entry in the audit log.
                executor.resumeEvent(seqNum: seqNum, payload: payload)
            } else {
                executor.resumeEventWithTimeout(seqNum: seqNum, eventName: eventName)
            }
        }

        // If woken without an event name a sleep timer (or condition deadline) fired.
        if claimed.wakeEvent == nil { executor.resumeAllTimers() }

        // ── Drain + conditions ────────────────────────────────────────────────
        executor.drain()
        while executor.resumeExpiredConditions() { executor.drain() }
        while executor.evaluateAndResumeFirstSatisfiedCondition() { executor.drain() }

        // ── Local activity execution loop ─────────────────────────────────────
        try await runLocalActivities(
            exec: exec,
            claimed: claimed,
            executor: executor,
            activation: activation,
            handlerResult: handlerResult,
            claimTimeoutSecs: claimTimeoutSecs,
            expireConditions: true
        )

        // ── Apply commands, handle result, suspend or complete ─────────────────
        return try await applyScheduleCommands(
            commands: executor.pendingCommands,
            executor: executor,
            claimed: claimed,
            exec: exec,
            activation: activation,
            cache: cache,
            handlerResult: handlerResult,
            handlerTask: handlerTask,
            stateBox: stateBox,
            historySeq: &historySeq,
            claimTimeoutSecs: claimTimeoutSecs
        )
    }

    // MARK: - Shared activation helpers

    /// Loads all pending signals, routes update signals through `handleUpdate`,
    /// applies regular signals through `handleSignal`, emits update results as
    /// named events, appends `SIGNAL_RECEIVED` history events, persists the updated
    /// state, and deletes the processed signal rows. No-op when no signals are pending.
    private func applyAndPersistSignals(
        to state: inout W,
        exec: _WorkerExec,
        claimed: ClaimedTask,
        historySeq: inout Int
    ) async throws {
        let signals = try await WorkflowStateQueries.loadPendingSignals(
            on: exec.postgres,
            taskID: claimed.taskID,
            namespaceID: exec.namespace,
            logger: exec.logger
        )
        guard !signals.isEmpty else { return }

        var updateResults: [(correlationID: String, result: ByteBuffer)] = []
        var updateErrors: [(correlationID: String, error: String)] = []

        for signal in signals {
            if let correlationID = signal.updateCorrelationID {
                do {
                    if let result = try state.handleUpdate(
                        name: signal.name,
                        correlationID: correlationID,
                        payload: signal.payload
                    ) {
                        updateResults.append((correlationID, result))
                    } else {
                        updateErrors.append((correlationID, "Unknown update: \(signal.name)"))
                    }
                } catch {
                    updateErrors.append((correlationID, strandErrorMessage(error)))
                }
            } else {
                try state.handleSignal(name: signal.name, payload: signal.payload)
            }
        }

        // Write update results to strand.workflow_updates (not strand.events)
        for (correlationID, result) in updateResults {
            try await WorkflowStateQueries.writeUpdateResult(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                correlationID: correlationID,
                result: result,
                error: nil,
                logger: exec.logger
            )
        }
        for (correlationID, errorMsg) in updateErrors {
            try await WorkflowStateQueries.writeUpdateResult(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                correlationID: correlationID,
                result: nil,
                error: errorMsg,
                logger: exec.logger
            )
        }

        // Write history — updates get UPDATE_APPLIED, signals get SIGNAL_RECEIVED.
        // signal.name is always the clean handler name for both kinds.
        var historyBatch: [(seq: Int, eventType: WorkflowStateQueries.HistoryEventType, eventData: ByteBuffer?)] = []
        for signal in signals {
            let eventType: WorkflowStateQueries.HistoryEventType =
                signal.updateCorrelationID != nil ? .updateApplied : .signalReceived
            let sigData = try? JSON.encode(WorkflowStateQueries.SignalReceivedData(name: signal.name))
            let seq = historySeq
            historySeq += 1
            historyBatch.append((seq: seq, eventType: eventType, eventData: sigData))
        }
        // Write all signal history events in one batch — one round-trip regardless of N signals.
        if !historyBatch.isEmpty {
            try await WorkflowStateQueries.batchAppendHistory(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                events: historyBatch,
                logger: exec.logger
            )
        }
        let stateBuf = try JSON.encode(state)
        try await WorkflowStateQueries.saveState(
            on: exec.postgres,
            taskID: claimed.taskID,
            namespaceID: exec.namespace,
            stateBuffer: stateBuf,
            logger: exec.logger
        )
        try await WorkflowStateQueries.deleteSignals(
            on: exec.postgres,
            ids: signals.map { $0.id },
            logger: exec.logger
        )
    }

    /// Runs all queued local activities to completion, draining the executor after each
    /// batch. Broken early if the handler finishes during a batch.
    ///
    /// - Parameter expireConditions: when `true` (cached/resume path), expired condition
    ///   deadlines are processed after each drain — matching the behaviour of
    ///   `resumeActivation`. Pass `false` on the fresh path (`_activate`).
    private func runLocalActivities(
        exec: _WorkerExec,
        claimed: ClaimedTask,
        executor: StrandWorkflowExecutor,
        activation: _WorkflowActivation<W>,
        handlerResult: ArcBox<Result<W.Output, Error>?>,
        claimTimeoutSecs: Int,
        expireConditions: Bool
    ) async throws {
        localActivityLoop: while !executor.localActivityEntries.isEmpty {
            let entries = executor.localActivityEntries
            for (id, entry) in entries {
                guard let runner = exec.localActivityLookup[entry.name] else {
                    executor.failLocalActivity(id: id, error: StrandError.unknownTask(name: entry.name))
                    continue
                }
                do {
                    // Heartbeat: extend the claim every max(claimTimeoutSecs/2, 1)
                    // seconds DURING local activity execution so that long-running
                    // local activities never hit the lease-expiry deadline before
                    // setCheckpointState's own extendClaim fires post-completion.
                    //
                    // Keeps the Postgres lease alive during local activity execution so
                    // the expiry sweep never re-queues the run while it is still running.
                    //
                    // try? on Task.sleep — CancellationError from defer { heartbeat.cancel() }
                    // is expected and should not propagate.  try? on extendClaim — best-effort;
                    // the run will eventually be swept by leaseExpiryLoop if the lease truly
                    // lapses.  Concurrent calls to extendClaim from this heartbeat and from
                    // setCheckpointState below are idempotent (both write NOW() + interval).
                    let heartbeat = Task<Void, Never> {
                        let halfInterval = max(claimTimeoutSecs / 2, 1)
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(halfInterval))
                            guard !Task.isCancelled else { break }
                            try? await Queries.extendClaim(
                                on: exec.postgres,
                                namespaceID: exec.namespace,
                                runID: claimed.runID,
                                extendBySeconds: claimTimeoutSecs,
                                logger: exec.logger
                            )
                        }
                    }
                    defer { heartbeat.cancel() }
                    let result: ByteBuffer
                    if let timeout = entry.options.timeout {
                        // Race the runner against a per-attempt timeout from LocalActivityOptions.
                        result = try await withThrowingTaskGroup(of: ByteBuffer.self) { tg in
                            tg.addTask { try await runner(entry.input, exec, claimed.taskID) }
                            tg.addTask {
                                try await Task.sleep(for: timeout)
                                throw StrandError.timeout(message: "Local activity '\(entry.name)' exceeded per-attempt timeout")
                            }
                            let r = try await tg.next()!
                            tg.cancelAll()
                            return r
                        }
                    } else {
                        result = try await runner(entry.input, exec, claimed.taskID)
                    }
                    try await Queries.setCheckpointState(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        seqNum: entry.seqNum,
                        name: entry.name,
                        stateBuffer: result,
                        runID: claimed.runID,
                        extendClaimBySeconds: claimTimeoutSecs,
                        logger: exec.logger
                    )
                    activation.cacheCheckpoint(seqNum: entry.seqNum, buffer: result)
                    executor.resolveLocalActivity(id: id, result: result)
                } catch {
                    executor.failLocalActivity(id: id, error: error)
                }
            }
            executor.drain()
            if expireConditions {
                while executor.resumeExpiredConditions() { executor.drain() }
            }
            while executor.evaluateAndResumeFirstSatisfiedCondition() { executor.drain() }
            if handlerResult.value != nil { break localActivityLoop }
        }
    }

}
