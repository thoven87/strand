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

    /// Cancel every cached Task — called from a cancellation handler so that
    /// worker shutdown also cleans up Tasks that are parked mid-activation.
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
        // Wrap the whole activation so that worker shutdown (Task cancellation)
        // also tears down any cached handler Task for this workflow instance.
        try await withTaskCancellationHandler {
            try await _activate(claimed: claimed, exec: exec, cache: cache)
        } onCancel: {
            cache.cancelAll()
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
            runID: claimed.runID,
            logger: exec.logger
        )
        var checkpointCache: [Int: ByteBuffer] = [:]
        for row in checkpointRows { checkpointCache[row.seqNum] = row.stateBuffer }

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
        let signals = try await WorkflowStateQueries.loadPendingSignals(
            on: exec.postgres,
            taskID: claimed.taskID,
            namespaceID: exec.namespace,
            logger: exec.logger
        )
        for signal in signals {
            try workflowState.handleSignal(name: signal.name, payload: signal.payload)
        }
        if !signals.isEmpty {
            for signal in signals {
                let sigData = try? JSON.encode(["name": signal.name])
                try await WorkflowStateQueries.appendHistory(
                    on: exec.postgres,
                    namespaceID: exec.namespace,
                    taskID: claimed.taskID,
                    seq: historySeq,
                    eventType: .signalReceived,
                    eventData: sigData,
                    logger: exec.logger
                )
                historySeq += 1
            }
            let postSignalBuf = try JSON.encode(workflowState)
            try await WorkflowStateQueries.saveState(
                on: exec.postgres,
                taskID: claimed.taskID,
                namespaceID: exec.namespace,
                stateBuffer: postSignalBuf,
                logger: exec.logger
            )
            try await WorkflowStateQueries.deleteSignals(
                on: exec.postgres,
                ids: signals.map { $0.id },
                logger: exec.logger
            )
        }

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
        for (seqNum, _, _, state, kind, name) in completedChildren
        where kind == .workflow && state == .completed {
            try await WorkflowStateQueries.appendHistory(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                seq: historySeq,
                eventType: .childWorkflowCompleted,
                // seq_num is a String for consistency with CHILD_WORKFLOW_STARTED
                eventData: try? JSON.encode(["workflow": name, "seq_num": String(seqNum)]),
                logger: exec.logger
            )
            historySeq += 1
        }

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
            namespace: exec.namespace,
            activationTime: activationTime
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
        // Local activities run in-process with no DB task row or queue dispatch.
        // After each batch the executor flushes buffered commands and re-evaluates
        // any pending conditions; break early if the handler has already finished.
        localActivityLoop: while !executor.localActivityEntries.isEmpty {
            let entries = executor.localActivityEntries  // snapshot
            for (id, entry) in entries {
                guard let runner = exec.localActivityLookup[entry.name] else {
                    executor.failLocalActivity(
                        id: id,
                        error: StrandError.unknownTask(name: entry.name)
                    )
                    continue
                }
                do {
                    let result = try await runner(entry.input, exec, claimed.taskID)
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
            while executor.evaluateAndResumeFirstSatisfiedCondition() { executor.drain() }
            if handlerResult.value != nil { break localActivityLoop }
        }

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
                runID: claimed.runID,
                logger: exec.logger
            )
            for row in freshCheckpoints where activation.cachedCheckpoint(for: row.seqNum) == nil {
                activation.cacheCheckpoint(seqNum: row.seqNum, buffer: row.stateBuffer)
            }
        }

        // ── Signals ──────────────────────────────────────────────────────────
        // Apply directly to the live stateBox — no need to reload from DB.
        let signals = try await WorkflowStateQueries.loadPendingSignals(
            on: exec.postgres,
            taskID: claimed.taskID,
            namespaceID: exec.namespace,
            logger: exec.logger
        )
        for signal in signals {
            try stateBox.value.handleSignal(name: signal.name, payload: signal.payload)
        }
        if !signals.isEmpty {
            for signal in signals {
                let sigData = try? JSON.encode(["name": signal.name])
                try await WorkflowStateQueries.appendHistory(
                    on: exec.postgres,
                    namespaceID: exec.namespace,
                    taskID: claimed.taskID,
                    seq: historySeq,
                    eventType: .signalReceived,
                    eventData: sigData,
                    logger: exec.logger
                )
                historySeq += 1
            }
            let postSignalBuf = try JSON.encode(stateBox.value)
            try await WorkflowStateQueries.saveState(
                on: exec.postgres,
                taskID: claimed.taskID,
                namespaceID: exec.namespace,
                stateBuffer: postSignalBuf,
                logger: exec.logger
            )
            try await WorkflowStateQueries.deleteSignals(
                on: exec.postgres,
                ids: signals.map { $0.id },
                logger: exec.logger
            )

        }

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
        // activations processing many simultaneous completions don’t expire.
        if !completedChildren.isEmpty {
            try await Queries.extendClaim(
                on: exec.postgres,
                namespaceID: exec.namespace,
                runID: claimed.runID,
                extendBySeconds: claimTimeoutSecs,
                logger: exec.logger
            )
        }

        for (seqNum, _, _, state, kind, name) in completedChildren
        where kind == .workflow && state == .completed {
            try await WorkflowStateQueries.appendHistory(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                seq: historySeq,
                eventType: .childWorkflowCompleted,
                eventData: try? JSON.encode(["workflow": name, "seq_num": String(seqNum)]),
                logger: exec.logger
            )
            historySeq += 1
        }

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
            } else {
                let sentinel = try JSON.encode(TimeoutSentinel())
                try await Queries.batchSetCheckpoints(
                    on: exec.postgres,
                    namespaceID: exec.namespace,
                    taskID: claimed.taskID,
                    runID: claimed.runID,
                    checkpoints: [(seqNum: seqNum, name: "waitForEvent:\(eventName):timeout", state: sentinel)],
                    extendClaimBySeconds: claimTimeoutSecs,
                    logger: exec.logger
                )
                activation.cacheCheckpoint(seqNum: seqNum, buffer: sentinel)
            }
        }

        // ── Resume parked continuations ───────────────────────────────────────
        // Clear commands from the previous activation before re-draining.
        executor.clearPendingCommands()

        for (seqNum, result, failureReason, state, kind, name) in completedChildren {
            switch state {
            case .completed:
                if let result { executor.resumeActivity(seqNum: seqNum, result: result) }
            case .failed, .cancelled:
                let retryState: ActivityRetryState =
                    state == .cancelled ? .cancelled : .maximumAttemptsReached
                let err: Error
                if kind == .workflow {
                    err = StrandError.childWorkflowFailed(name: name, state: state.rawValue)
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
                executor.resumeEvent(seqNum: seqNum, payload: payload)
                try await WorkflowStateQueries.appendHistory(
                    on: exec.postgres,
                    namespaceID: exec.namespace,
                    taskID: claimed.taskID,
                    seq: historySeq,
                    eventType: .eventReceived,
                    eventData: try? JSON.encode(["event_name": eventName]),
                    logger: exec.logger
                )
                historySeq += 1
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
        localActivityLoop: while !executor.localActivityEntries.isEmpty {
            let entries = executor.localActivityEntries
            for (id, entry) in entries {
                guard let runner = exec.localActivityLookup[entry.name] else {
                    executor.failLocalActivity(id: id, error: StrandError.unknownTask(name: entry.name))
                    continue
                }
                do {
                    let result = try await runner(entry.input, exec, claimed.taskID)
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
            while executor.resumeExpiredConditions() { executor.drain() }
            while executor.evaluateAndResumeFirstSatisfiedCondition() { executor.drain() }
            if handlerResult.value != nil { break localActivityLoop }
        }

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

}
