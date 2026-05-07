public import Logging  // Logger appears in the public init signature
public import Metrics
import NIOCore
public import PostgresNIO  // PostgresClient appears in the public init signature
public import ServiceLifecycle  // Service conformance is part of the public API
import Synchronization
import Tracing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - _WorkerExec

/// Internal execution context passed from the worker to registered handlers.
///
/// Bundles all resources the handler needs to interact with Postgres and
/// resolve per-run configuration. Created once per `StrandWorker` and captured
/// by every registration closure, so a single allocation serves all runs on
/// that worker.
package struct _WorkerExec: Sendable {
    let postgres: PostgresClient
    let queue: String
    let namespace: String
    let logger: Logger
    let options: WorkerOptions
    /// Runners for local activities registered on this worker.
    /// Keyed by activity name; each closure executes the activity in-process.
    let localActivityLookup: [String: @Sendable (ByteBuffer, _WorkerExec, UUID?) async throws -> ByteBuffer]
}

// MARK: - WorkerOptions

/// Configuration for a ``StrandWorker`` instance.
///
/// All properties have sensible defaults; only override what you need:
///
/// ```swift
/// WorkerOptions(
///     queue: "orders",
///     workflowConcurrency: 8,
///     activityConcurrency: 16,
///     pollInterval: .milliseconds(100),
///     claimTimeout: .seconds(60)
/// )
/// ```
public struct WorkerOptions: Sendable {
    /// Queue this worker polls for tasks. Default: `"default"`.
    public var queue: String

    /// Namespace this worker operates in. Must match the namespace used by the
    /// clients that enqueue tasks. Default: `"default"`.
    public var namespace: String

    /// Stable identifier for this worker process. Defaults to `hostname:pid`.
    public var workerID: String?

    /// Maximum number of workflow runs executing concurrently on this worker.
    /// Default: `4`.
    public var workflowConcurrency: Int

    /// Maximum number of activity executions running concurrently on this worker.
    /// Default: `8`.
    public var activityConcurrency: Int

    /// How long the worker sleeps between poll cycles when the queue is empty.
    /// Default: `.milliseconds(250)`.
    public var pollInterval: Duration

    /// Maximum time a claimed task may run per attempt before the in-process
    /// deadline poller cancels it and the lease expiry sweep re-queues it.
    ///
    /// Must be at least 10 seconds to avoid races between the claim poll and
    /// the lease expiry sweep. Tasks that need shorter deadlines should set
    /// `ActivityOptions.timeout` directly.
    ///
    /// Default: `.seconds(120)`.
    public var claimTimeout: Duration

    /// Override the claim batch size. `nil` uses `workflowConcurrency + activityConcurrency`.
    public var batchSize: Int?

    /// No-op. Previously controlled whether the worker called `exit(1)` at
    /// 2 × claimTimeout. Timeout enforcement is now handled by a racing child
    /// task inside `withThrowingTaskGroup` in `runTask` — no `exit(1)` is ever
    /// called. Kept for API source-compatibility.
    public var fatalOnLeaseTimeout: Bool

    /// How long the worker waits for in-flight tasks to finish after receiving a
    /// graceful-shutdown signal. Default: `.seconds(10)`.
    public var gracefulShutdownTimeout: Duration

    /// Interval between expired-lease sweep passes. Default: `.seconds(5)`.
    public var leaseExpiryInterval: Duration

    /// Called on every poll error. When `nil`, errors are logged at `.error` level.
    public var onError: (@Sendable (any Error) async -> Void)?

    public init(
        queue: String = "default",
        namespace: String = "default",
        workerID: String? = nil,
        workflowConcurrency: Int = 4,
        activityConcurrency: Int = 8,
        pollInterval: Duration = .milliseconds(250),
        claimTimeout: Duration = .seconds(120),
        batchSize: Int? = nil,
        fatalOnLeaseTimeout: Bool = true,
        gracefulShutdownTimeout: Duration = .seconds(10),
        leaseExpiryInterval: Duration = .seconds(5),
        onError: (@Sendable (any Error) async -> Void)? = nil
    ) {
        self.queue = queue
        self.namespace = namespace
        self.workerID = workerID
        self.workflowConcurrency = workflowConcurrency
        self.activityConcurrency = activityConcurrency
        self.pollInterval = pollInterval
        self.claimTimeout = claimTimeout
        self.batchSize = batchSize
        self.fatalOnLeaseTimeout = fatalOnLeaseTimeout
        self.gracefulShutdownTimeout = gracefulShutdownTimeout
        self.leaseExpiryInterval = leaseExpiryInterval
        self.onError = onError
    }
}

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

        // ── 7. Apply commands to Postgres ─────────────────────────────────────────
        // Split commands by type and apply them atomically.
        let commands = executor.pendingCommands

        // Non-suspending: writeCheckpoint, timerFired, eventReceived.
        // Write these before anything else so they're durable regardless of what follows.
        let checkpointWrites = commands.compactMap {
            cmd -> (seqNum: Int, name: String?, state: ByteBuffer)? in
            if case .writeCheckpoint(let seqNum, let name, let value) = cmd {
                return (seqNum: seqNum, name: name, state: value)
            }
            return nil
        }
        if !checkpointWrites.isEmpty {
            try await Queries.batchSetCheckpoints(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                runID: claimed.runID,
                checkpoints: checkpointWrites,
                extendClaimBySeconds: claimTimeoutSecs,
                logger: exec.logger
            )
            for (seqNum, _, value) in checkpointWrites {
                activation.cacheCheckpoint(seqNum: seqNum, buffer: value)
            }
        }

        // Replay fast-path history events (TIMER_FIRED, EVENT_RECEIVED).
        for cmd in commands {
            switch cmd {
            case .timerFired(_):
                try await WorkflowStateQueries.appendHistory(
                    on: exec.postgres,
                    namespaceID: exec.namespace,
                    taskID: claimed.taskID,
                    seq: historySeq,
                    eventType: .timerFired,
                    eventData: nil,
                    logger: exec.logger
                )
                historySeq += 1
            case .eventReceived(let eventName):
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
            default:
                break
            }
        }

        // Decide on the terminal state of this activation.
        switch handlerResult.value {

        case .success(let output):
            // Handler completed — persist state and return the encoded result.
            // The caller (runTask) will write COMPLETED to the run.
            cache.remove(claimed.taskID)
            handlerTask.cancel()
            executor.cancelPending()
            executor.drain()  // flush any residual jobs from cancelPending()
            let finalStateBuf = try JSON.encode(stateBox.value)
            try await WorkflowStateQueries.saveState(
                on: exec.postgres,
                taskID: claimed.taskID,
                namespaceID: exec.namespace,
                stateBuffer: finalStateBuf,
                logger: exec.logger
            )
            try await WorkflowStateQueries.appendHistory(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                seq: historySeq,
                eventType: .workflowCompleted,
                eventData: nil,
                logger: exec.logger
            )
            return try JSON.encode(output)

        case .failure(let error):
            // StrandError.cancelled is the internal suspension signal — not a real failure.
            if case .cancelled? = error as? StrandError { break }
            // _ContinueAsNewSignal is a lifecycle transition, not a failure.
            // Re-throw it unwrapped so runTask's typed catch matches it.
            // Without this guard, `lastCallSite` (set by the preceding
            // context.runActivity / runChildWorkflow call) would cause
            // CallSiteAnnotatedError to wrap the signal — defeating the
            // `catch let signal as _ContinueAsNewSignal` in runTask.
            if let signal = error as? _ContinueAsNewSignal {
                cache.remove(claimed.taskID)
                handlerTask.cancel()
                executor.cancelPending()
                executor.drain()  // flush jobs enqueued by cancelPending()
                throw signal
            }
            cache.remove(claimed.taskID)
            handlerTask.cancel()
            executor.cancelPending()
            executor.drain()  // flush jobs enqueued by cancelPending()
            let errData = try? JSON.encode(["error": String(describing: error)])
            try await WorkflowStateQueries.appendHistory(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                seq: historySeq,
                eventType: .workflowFailed,
                eventData: errData,
                logger: exec.logger
            )
            // Stamp the last WorkflowContext call site onto the error.
            if let site = activation.lastCallSite {
                throw CallSiteAnnotatedError(
                    underlying: error,
                    fileID: site.fileID,
                    line: site.line
                )
            }
            throw error

        case .none:  // Handler suspended — apply schedule commands.
            break
        }

        // ── Suspended: apply schedule commands ────────────────────────────────────
        let scheduleCommands = commands.filter { cmd in
            switch cmd {
            case .scheduleActivity, .startTimer, .awaitEvent, .scheduleChildWorkflow:
                return true
            case .writeCheckpoint, .timerFired, .eventReceived:
                return false
            }
        }

        if !scheduleCommands.isEmpty {
            // Enqueue activities (idempotent — safe to call even if already exists).
            var enqueued: [(seqNum: Int, taskID: UUID)] = []
            for cmd in scheduleCommands {
                switch cmd {
                case .scheduleActivity(
                    let name,
                    let actInput,
                    let options,
                    let seqNum,
                    let idKey
                ):
                    let row = try await Queries.enqueueTask(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        queue: options.queue ?? exec.queue,
                        taskName: name,
                        paramsBuffer: actInput,
                        headersBuffer: nil,
                        retryStrategyBuffer: options.retryStrategy.flatMap { try? JSON.encode($0) },
                        maxAttempts: options.maxAttempts,
                        cancellationBuffer: nil,
                        idempotencyKey: idKey,
                        priority: options.priority.rawValue,
                        scheduledAt: options.delayUntil,
                        timeoutSeconds: options.timeout.map { Int($0.components.seconds) },
                        deadlineAt: options.maxDuration.map {
                            Date.now.addingTimeInterval(
                                Double($0.components.seconds)
                                    + Double($0.components.attoseconds)
                                    / 1_000_000_000_000_000_000
                            )
                        },
                        fairnessKey: options.fairnessKey,
                        fairnessWeight: options.fairnessWeight,
                        kind: .activity,
                        parentTaskID: claimed.taskID,
                        logger: exec.logger
                    )
                    enqueued.append((seqNum: seqNum, taskID: row.taskID))
                    let actData = try? JSON.encode(["activity": name, "seq_num": String(seqNum)])
                    try await WorkflowStateQueries.appendHistory(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        seq: historySeq,
                        eventType: .activityScheduled,
                        eventData: actData,
                        logger: exec.logger
                    )
                    historySeq += 1

                case .startTimer(let wakeAt, _):
                    // Transition run to SLEEPING. Both UPDATEs are one SQL statement
                    // (data-modifying CTE) so PostgreSQL commits them atomically —
                    // no explicit BEGIN/COMMIT wrapper needed.
                    try await exec.postgres.query(
                        """
                        WITH r AS (
                            UPDATE strand.runs
                            SET state = \(TaskState.sleeping), available_at = \(wakeAt),
                                worker_id = NULL, lease_expires_at = NULL
                            WHERE id = \(claimed.runID)
                            RETURNING id
                        )
                        UPDATE strand.tasks SET state = \(TaskState.sleeping)
                        WHERE id = \(claimed.taskID)
                        """,
                        logger: exec.logger
                    )
                    let timerData = try? JSON.encode([
                        "duration_ms": Int(wakeAt.timeIntervalSinceNow * 1000)
                    ])
                    try await WorkflowStateQueries.appendHistory(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        seq: historySeq,
                        eventType: .timerStarted,
                        eventData: timerData,
                        logger: exec.logger
                    )
                    historySeq += 1

                case .awaitEvent(let eventName, let seqNum, let timeoutAt):
                    // Atomic check-or-wait: prevents the lost-wakeup race where the
                    // event fires between drain() returning and this transaction committing.
                    //
                    // Without this check:
                    //   1. drain() returns — handler suspended, .awaitEvent command emitted
                    //   2. client.emitEvent fires — finds no event_wait yet — run not woken
                    //   3. worker inserts event_wait — run goes WAITING and stalls forever
                    //
                    // Both operations live in the same transaction: insert the event_wait
                    // and check strand.events. If the event is already there, go PENDING
                    // immediately so the next activation fast-paths through waitForEvent.
                    let taskID = claimed.taskID
                    let runID = claimed.runID
                    let queueName = exec.queue

                    try await exec.postgres.withTransaction(logger: exec.logger) { conn in
                        // Always register the event_wait so emitEvent can find this run later.
                        try await conn.query(
                            """
                            INSERT INTO strand.event_waits
                                (task_id, run_id, queue, seq_num, event_name, timeout_at)
                            VALUES (\(taskID), \(runID), \(queueName), \(seqNum), \(eventName), \(timeoutAt))
                            ON CONFLICT (run_id, seq_num) DO UPDATE
                                SET event_name = EXCLUDED.event_name, timeout_at = EXCLUDED.timeout_at
                            """,
                            logger: exec.logger
                        )

                        // Check if the event was already emitted (race window detection).
                        let evtStream = try await conn.query(
                            """
                            SELECT payload FROM strand.events
                            WHERE namespace_id = \(exec.namespace)
                              AND queue = \(queueName)
                              AND name  = \(eventName)
                              AND payload IS NOT NULL
                            """,
                            logger: exec.logger
                        )

                        if let evtRow = try await evtStream.first(where: { _ in true }) {
                            // Event already in strand.events — wake the run immediately.
                            var col = evtRow.makeIterator()
                            let existingPayload = try col.next()!.decode(
                                ByteBuffer?.self,
                                context: .default
                            )

                            // Transition to PENDING with the event payload so the next
                            // activation's waitForEvent fast-path (wakeEvent == name) fires.
                            try await conn.query(
                                """
                                WITH r AS (
                                    UPDATE strand.runs
                                    SET state        = \(TaskState.pending),
                                        available_at  = NOW(),
                                        wake_event    = \(eventName),
                                        event_payload = \(existingPayload),
                                        worker_id     = NULL,
                                        lease_expires_at = NULL
                                    WHERE id = \(runID)
                                )
                                UPDATE strand.tasks SET state = \(TaskState.pending)
                                WHERE id = \(taskID)
                                """,
                                logger: exec.logger
                            )
                        } else {
                            // Event not yet emitted — set run to WAITING (or SLEEPING for timed waits).
                            let availableAt =
                                timeoutAt ?? Date(timeIntervalSince1970: 32_503_680_000)
                            let runState: TaskState = timeoutAt != nil ? .sleeping : .waiting
                            try await conn.query(
                                """
                                WITH r AS (
                                    UPDATE strand.runs
                                    SET state        = \(runState),
                                        available_at  = \(availableAt),
                                        wake_event    = \(eventName),
                                        event_payload = NULL,
                                        worker_id     = NULL,
                                        lease_expires_at = NULL
                                    WHERE id = \(runID)
                                )
                                UPDATE strand.tasks SET state = \(runState)
                                WHERE id = \(taskID)
                                """,
                                logger: exec.logger
                            )
                        }
                    }
                    let eventWaitData = try? JSON.encode(["event_name": eventName])
                    try await WorkflowStateQueries.appendHistory(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        seq: historySeq,
                        eventType: .eventWaitStarted,
                        eventData: eventWaitData,
                        logger: exec.logger
                    )
                    historySeq += 1

                case .scheduleChildWorkflow(
                    let name,
                    let childQueue,
                    let wfInput,
                    let seqNum,
                    let idKey
                ):
                    let targetQueue = childQueue ?? exec.queue  // use child's queue or inherit
                    let row = try await Queries.enqueueTask(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        queue: targetQueue,
                        taskName: name,
                        paramsBuffer: wfInput,
                        headersBuffer: nil,
                        retryStrategyBuffer: nil,
                        maxAttempts: nil,
                        cancellationBuffer: nil,
                        idempotencyKey: idKey,
                        priority: TaskPriority.normal.rawValue,
                        scheduledAt: nil,
                        fairnessKey: nil,
                        fairnessWeight: 1.0,
                        kind: .workflow,
                        parentTaskID: claimed.taskID,
                        logger: exec.logger
                    )
                    enqueued.append((seqNum: seqNum, taskID: row.taskID))
                    let childData = try? JSON.encode([
                        "workflow": name, "seq_num": String(seqNum),
                    ])
                    try await WorkflowStateQueries.appendHistory(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        seq: historySeq,
                        eventType: .childWorkflowStarted,
                        eventData: childData,
                        logger: exec.logger
                    )
                    historySeq += 1

                case .writeCheckpoint, .timerFired, .eventReceived:
                    break  // already handled above
                }
            }

            // Register event_waits for all enqueued activities / child workflows,
            // then transition the run to WAITING (event-driven, no timer).
            //
            // Atomic check-or-wait: prevents the lost-wakeup race where a child
            // task completes between enqueueTask() committing and this transaction
            // committing.
            //
            // Without this check:
            //   1. enqueueTask() commits — child task visible to activity workers
            //   2. Activity worker claims, runs, and completes it immediately
            //   3. emitTaskCompletionSignal finds no event_wait — parent not woken
            //   4. This transaction commits — run goes WAITING and stalls forever
            //
            // Both the event_wait inserts and a task_completions count live in the
            // same transaction. If all children are already done, go PENDING immediately;
            // the next poll re-activates the workflow. Remaining event_waits fire normally.
            if !enqueued.isEmpty {
                try await exec.postgres.withTransaction(logger: exec.logger) { conn in
                    // TODO: optimize this path
                    for item in enqueued {
                        try await conn.query(
                            """
                            INSERT INTO strand.event_waits
                                (task_id, run_id, queue, seq_num, child_task_id, timeout_at)
                            VALUES (\(claimed.taskID), \(claimed.runID), \(exec.queue),
                                    \(item.seqNum), \(item.taskID), NULL)
                            ON CONFLICT (run_id, seq_num) DO UPDATE
                                SET child_task_id = EXCLUDED.child_task_id,
                                    timeout_at    = NULL
                            """,
                            logger: exec.logger
                        )
                    }

                    // Atomically check whether any child tasks already completed
                    // (i.e. are present in task_completions) before we park the run.
                    let childTaskIDs = enqueued.map { $0.taskID }
                    let completedStream = try await conn.query(
                        """
                        SELECT COUNT(*) FROM strand.task_completions
                        WHERE task_id = ANY(\(childTaskIDs))
                        """,
                        logger: exec.logger
                    )
                    var completedCount = 0
                    for try await row in completedStream {
                        var col = row.makeIterator()
                        completedCount = try col.next()!.decode(Int.self, context: .default)
                    }

                    if completedCount == enqueued.count {
                        // All children already finished — go PENDING so the next poll
                        // re-activates immediately rather than waiting for events that
                        // already fired and were missed.
                        try await conn.query(
                            """
                            WITH r AS (
                                UPDATE strand.runs
                                SET state = \(TaskState.pending), available_at = NOW(),
                                    worker_id = NULL, lease_expires_at = NULL
                                WHERE id = \(claimed.runID)
                                RETURNING id
                            )
                            UPDATE strand.tasks SET state = \(TaskState.pending)
                            WHERE id = \(claimed.taskID)
                            """,
                            logger: exec.logger
                        )
                    } else {
                        try await conn.query(
                            """
                            WITH r AS (
                                UPDATE strand.runs
                                SET state = \(TaskState.waiting), worker_id = NULL, lease_expires_at = NULL
                                WHERE id = \(claimed.runID)
                                RETURNING id
                            )
                            UPDATE strand.tasks SET state = \(TaskState.waiting)
                            WHERE id = \(claimed.taskID)
                            """,
                            logger: exec.logger
                        )
                    }
                }
            }
        }

        // ── Unsatisfied conditions ──────────────────────────────────────────────────
        // Any conditions that were not satisfied post-drain need a DB state transition
        // so the worker releases this run until a signal or timer wakes it.
        //
        // • condition(_:)          → WAITING (no timer; woken only by a signal)
        // • condition(_:timeout:)  → SLEEPING with available_at = deadline
        //   (woken by timer expiry OR by a signal that transitions SLEEPING → PENDING)
        if executor.hasUnsatisfiedConditions && scheduleCommands.isEmpty {
            let condTaskID = claimed.taskID
            let condRunID = claimed.runID
            if let wakeAt = executor.conditionMinWakeAt {
                // At least one condition has a deadline — sleep until the earliest one.
                try await exec.postgres.query(
                    """
                    WITH r AS (
                        UPDATE strand.runs
                        SET state = \(TaskState.sleeping), available_at = \(wakeAt),
                            worker_id = NULL, lease_expires_at = NULL
                        WHERE id = \(condRunID)
                    )
                    UPDATE strand.tasks SET state = \(TaskState.sleeping) WHERE id = \(condTaskID)
                    """,
                    logger: exec.logger
                )
            } else {
                // All conditions are indefinite — wait for a signal.
                try await exec.postgres.query(
                    """
                    WITH r AS (
                        UPDATE strand.runs
                        SET state = \(TaskState.waiting), worker_id = NULL, lease_expires_at = NULL
                        WHERE id = \(condRunID)
                    )
                    UPDATE strand.tasks SET state = \(TaskState.waiting) WHERE id = \(condTaskID)
                    """,
                    logger: exec.logger
                )
            }
            try await WorkflowStateQueries.appendHistory(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                seq: historySeq,
                eventType: .conditionWaiting,
                eventData: nil,
                logger: exec.logger
            )
            historySeq += 1
        }
        // No else branch: if scheduleCommands is empty and no conditions remain,
        // suspension came from sleep/waitForEvent which already wrote their own DB updates.

        // ── 8. Cache the live Task for the next activation ────────────────────────────
        // The handler is parked on a continuation — do NOT call cancelPending().
        // On the next activation, resumeActivation() will deliver real results
        // directly to those continuations and call drain() to continue execution.
        cache.set(
            claimed.taskID,
            _WorkflowTaskCache<W>.CachedState(
                executor: executor,
                task: handlerTask,
                handlerResult: handlerResult,
                stateBox: stateBox,
                activation: activation
            )
        )

        return nil
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

        // ── Apply new commands to Postgres ────────────────────────────────────
        let commands = executor.pendingCommands

        let checkpointWrites = commands.compactMap {
            cmd -> (seqNum: Int, name: String?, state: ByteBuffer)? in
            if case .writeCheckpoint(let seqNum, let name, let value) = cmd {
                return (seqNum: seqNum, name: name, state: value)
            }
            return nil
        }
        if !checkpointWrites.isEmpty {
            try await Queries.batchSetCheckpoints(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                runID: claimed.runID,
                checkpoints: checkpointWrites,
                extendClaimBySeconds: claimTimeoutSecs,
                logger: exec.logger
            )
            for (seqNum, _, value) in checkpointWrites {
                activation.cacheCheckpoint(seqNum: seqNum, buffer: value)
            }
        }

        for cmd in commands {
            switch cmd {
            case .timerFired:
                try await WorkflowStateQueries.appendHistory(
                    on: exec.postgres,
                    namespaceID: exec.namespace,
                    taskID: claimed.taskID,
                    seq: historySeq,
                    eventType: .timerFired,
                    eventData: nil,
                    logger: exec.logger
                )
                historySeq += 1
            case .eventReceived(let evtName):
                try await WorkflowStateQueries.appendHistory(
                    on: exec.postgres,
                    namespaceID: exec.namespace,
                    taskID: claimed.taskID,
                    seq: historySeq,
                    eventType: .eventReceived,
                    eventData: try? JSON.encode(["event_name": evtName]),
                    logger: exec.logger
                )
                historySeq += 1
            default:
                break
            }
        }

        // ── Result handling ───────────────────────────────────────────────────
        switch handlerResult.value {

        case .success(let output):
            cache.remove(claimed.taskID)
            handlerTask.cancel()
            executor.cancelPending()
            executor.drain()  // flush residual jobs from cancelPending()
            let finalStateBuf = try JSON.encode(stateBox.value)
            try await WorkflowStateQueries.saveState(
                on: exec.postgres,
                taskID: claimed.taskID,
                namespaceID: exec.namespace,
                stateBuffer: finalStateBuf,
                logger: exec.logger
            )
            try await WorkflowStateQueries.appendHistory(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                seq: historySeq,
                eventType: .workflowCompleted,
                eventData: nil,
                logger: exec.logger
            )
            return try JSON.encode(output)

        case .failure(let error):
            if case .cancelled? = error as? StrandError { break }
            // Same unwrap-before-wrap guard as in _activate: re-throw _ContinueAsNewSignal
            // directly so runTask's typed catch matches it (see _activate for rationale).
            if let signal = error as? _ContinueAsNewSignal {
                cache.remove(claimed.taskID)
                handlerTask.cancel()
                executor.cancelPending()
                executor.drain()  // flush residual jobs from cancelPending()
                throw signal
            }
            cache.remove(claimed.taskID)
            handlerTask.cancel()
            executor.cancelPending()
            executor.drain()  // flush residual jobs from cancelPending()
            let errData = try? JSON.encode(["error": String(describing: error)])
            try await WorkflowStateQueries.appendHistory(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                seq: historySeq,
                eventType: .workflowFailed,
                eventData: errData,
                logger: exec.logger
            )
            if let site = activation.lastCallSite {
                throw CallSiteAnnotatedError(underlying: error, fileID: site.fileID, line: site.line)
            }
            throw error

        case .none:
            break  // Handler still suspended — fall through to schedule commands
        }

        // ── Suspended: schedule new activities / timers / events ─────────────
        let scheduleCommands = commands.filter { cmd in
            switch cmd {
            case .scheduleActivity, .startTimer, .awaitEvent, .scheduleChildWorkflow: return true
            case .writeCheckpoint, .timerFired, .eventReceived: return false
            }
        }

        if !scheduleCommands.isEmpty {
            var enqueued: [(seqNum: Int, taskID: UUID)] = []
            for cmd in scheduleCommands {
                switch cmd {
                case .scheduleActivity(let name, let actInput, let options, let seqNum, let idKey):
                    let row = try await Queries.enqueueTask(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        queue: options.queue ?? exec.queue,
                        taskName: name,
                        paramsBuffer: actInput,
                        headersBuffer: nil,
                        retryStrategyBuffer: options.retryStrategy.flatMap { try? JSON.encode($0) },
                        maxAttempts: options.maxAttempts,
                        cancellationBuffer: nil,
                        idempotencyKey: idKey,
                        priority: options.priority.rawValue,
                        scheduledAt: options.delayUntil,
                        timeoutSeconds: options.timeout.map { Int($0.components.seconds) },
                        deadlineAt: options.maxDuration.map {
                            Date.now.addingTimeInterval(
                                Double($0.components.seconds)
                                    + Double($0.components.attoseconds) / 1_000_000_000_000_000_000
                            )
                        },
                        fairnessKey: options.fairnessKey,
                        fairnessWeight: options.fairnessWeight,
                        kind: .activity,
                        parentTaskID: claimed.taskID,
                        logger: exec.logger
                    )
                    enqueued.append((seqNum: seqNum, taskID: row.taskID))
                    try await WorkflowStateQueries.appendHistory(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        seq: historySeq,
                        eventType: .activityScheduled,
                        eventData: try? JSON.encode(["activity": name, "seq_num": String(seqNum)]),
                        logger: exec.logger
                    )
                    historySeq += 1

                case .startTimer(let wakeAt, _):
                    try await exec.postgres.query(
                        """
                        WITH r AS (
                            UPDATE strand.runs
                            SET state = \(TaskState.sleeping), available_at = \(wakeAt),
                                worker_id = NULL, lease_expires_at = NULL
                            WHERE id = \(claimed.runID)
                            RETURNING id
                        )
                        UPDATE strand.tasks SET state = \(TaskState.sleeping)
                        WHERE id = \(claimed.taskID)
                        """,
                        logger: exec.logger
                    )
                    try await WorkflowStateQueries.appendHistory(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        seq: historySeq,
                        eventType: .timerStarted,
                        eventData: try? JSON.encode(["duration_ms": Int(wakeAt.timeIntervalSinceNow * 1000)]),
                        logger: exec.logger
                    )
                    historySeq += 1

                case .awaitEvent(let evtName, let seqNum, let timeoutAt):
                    let taskID = claimed.taskID
                    let runID = claimed.runID
                    let queueName = exec.queue
                    try await exec.postgres.withTransaction(logger: exec.logger) { conn in
                        try await conn.query(
                            """
                            INSERT INTO strand.event_waits
                                (task_id, run_id, queue, seq_num, event_name, timeout_at)
                            VALUES (\(taskID), \(runID), \(queueName), \(seqNum), \(evtName), \(timeoutAt))
                            ON CONFLICT (run_id, seq_num) DO UPDATE
                                SET event_name = EXCLUDED.event_name, timeout_at = EXCLUDED.timeout_at
                            """,
                            logger: exec.logger
                        )
                        let evtStream = try await conn.query(
                            """
                            SELECT payload FROM strand.events
                            WHERE namespace_id = \(exec.namespace)
                              AND queue        = \(queueName)
                              AND name         = \(evtName)
                              AND payload IS NOT NULL
                            """,
                            logger: exec.logger
                        )
                        if let evtRow = try await evtStream.first(where: { _ in true }) {
                            var col = evtRow.makeIterator()
                            let existing = try col.next()!.decode(ByteBuffer?.self, context: .default)
                            try await conn.query(
                                """
                                WITH r AS (
                                    UPDATE strand.runs
                                    SET state = \(TaskState.pending), available_at = NOW(),
                                        wake_event = \(evtName), event_payload = \(existing),
                                        worker_id = NULL, lease_expires_at = NULL
                                    WHERE id = \(runID)
                                )
                                UPDATE strand.tasks SET state = \(TaskState.pending)
                                WHERE id = \(taskID)
                                """,
                                logger: exec.logger
                            )
                        } else {
                            let availableAt = timeoutAt ?? Date(timeIntervalSince1970: 32_503_680_000)
                            let runState: TaskState = timeoutAt != nil ? .sleeping : .waiting
                            try await conn.query(
                                """
                                WITH r AS (
                                    UPDATE strand.runs
                                    SET state = \(runState), available_at = \(availableAt),
                                        wake_event = \(evtName), event_payload = NULL,
                                        worker_id = NULL, lease_expires_at = NULL
                                    WHERE id = \(runID)
                                )
                                UPDATE strand.tasks SET state = \(runState)
                                WHERE id = \(taskID)
                                """,
                                logger: exec.logger
                            )
                        }
                    }
                    try await WorkflowStateQueries.appendHistory(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        seq: historySeq,
                        eventType: .eventWaitStarted,
                        eventData: try? JSON.encode(["event_name": evtName]),
                        logger: exec.logger
                    )
                    historySeq += 1

                case .scheduleChildWorkflow(let name, let childQueue, let wfInput, let seqNum, let idKey):
                    let row = try await Queries.enqueueTask(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        queue: childQueue ?? exec.queue,
                        taskName: name,
                        paramsBuffer: wfInput,
                        headersBuffer: nil,
                        retryStrategyBuffer: nil,
                        maxAttempts: nil,
                        cancellationBuffer: nil,
                        idempotencyKey: idKey,
                        priority: TaskPriority.normal.rawValue,
                        scheduledAt: nil,
                        fairnessKey: nil,
                        fairnessWeight: 1.0,
                        kind: .workflow,
                        parentTaskID: claimed.taskID,
                        logger: exec.logger
                    )
                    enqueued.append((seqNum: seqNum, taskID: row.taskID))
                    try await WorkflowStateQueries.appendHistory(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        seq: historySeq,
                        eventType: .childWorkflowStarted,
                        eventData: try? JSON.encode(["workflow": name, "seq_num": String(seqNum)]),
                        logger: exec.logger
                    )
                    historySeq += 1

                case .writeCheckpoint, .timerFired, .eventReceived:
                    break
                }
            }

            if !enqueued.isEmpty {
                try await exec.postgres.withTransaction(logger: exec.logger) { conn in
                    for item in enqueued {
                        try await conn.query(
                            """
                            INSERT INTO strand.event_waits
                                (task_id, run_id, queue, seq_num, child_task_id, timeout_at)
                            VALUES (\(claimed.taskID), \(claimed.runID), \(exec.queue),
                                    \(item.seqNum), \(item.taskID), NULL)
                            ON CONFLICT (run_id, seq_num) DO UPDATE
                                SET child_task_id = EXCLUDED.child_task_id,
                                    timeout_at    = NULL
                            """,
                            logger: exec.logger
                        )
                    }
                    let childTaskIDs = enqueued.map { $0.taskID }
                    let completedStream = try await conn.query(
                        "SELECT COUNT(*) FROM strand.task_completions WHERE task_id = ANY(\(childTaskIDs))",
                        logger: exec.logger
                    )
                    var completedCount = 0
                    for try await row in completedStream {
                        var col = row.makeIterator()
                        completedCount = try col.next()!.decode(Int.self, context: .default)
                    }
                    if completedCount == enqueued.count {
                        try await conn.query(
                            """
                            WITH r AS (
                                UPDATE strand.runs
                                SET state = \(TaskState.pending), available_at = NOW(),
                                    worker_id = NULL, lease_expires_at = NULL
                                WHERE id = \(claimed.runID) RETURNING id
                            )
                            UPDATE strand.tasks SET state = \(TaskState.pending) WHERE id = \(claimed.taskID)
                            """,
                            logger: exec.logger
                        )
                    } else {
                        try await conn.query(
                            """
                            WITH r AS (
                                UPDATE strand.runs
                                SET state = \(TaskState.waiting), worker_id = NULL, lease_expires_at = NULL
                                WHERE id = \(claimed.runID) RETURNING id
                            )
                            UPDATE strand.tasks SET state = \(TaskState.waiting) WHERE id = \(claimed.taskID)
                            """,
                            logger: exec.logger
                        )
                    }
                }
            }
        }

        if executor.hasUnsatisfiedConditions && scheduleCommands.isEmpty {
            if let wakeAt = executor.conditionMinWakeAt {
                try await exec.postgres.query(
                    """
                    WITH r AS (
                        UPDATE strand.runs
                        SET state = \(TaskState.sleeping), available_at = \(wakeAt),
                            worker_id = NULL, lease_expires_at = NULL
                        WHERE id = \(claimed.runID)
                    )
                    UPDATE strand.tasks SET state = \(TaskState.sleeping) WHERE id = \(claimed.taskID)
                    """,
                    logger: exec.logger
                )
            } else {
                try await exec.postgres.query(
                    """
                    WITH r AS (
                        UPDATE strand.runs
                        SET state = \(TaskState.waiting), worker_id = NULL, lease_expires_at = NULL
                        WHERE id = \(claimed.runID)
                    )
                    UPDATE strand.tasks SET state = \(TaskState.waiting) WHERE id = \(claimed.taskID)
                    """,
                    logger: exec.logger
                )
            }
            try await WorkflowStateQueries.appendHistory(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                seq: historySeq,
                eventType: .conditionWaiting,
                eventData: nil,
                logger: exec.logger
            )
        }

        // ── Partial-completion re-wait ──────────────────────────────────────────────────
        // The handler resumed some (but not all) children in a `withThrowingTaskGroup`
        // batch and is parked waiting for the rest. No new schedule commands were
        // emitted. Transition to WAITING so the next child completion can wake this
        // run through the `event_waits` registered during the original dispatch.
        if executor.hasPendingContinuations
            && scheduleCommands.isEmpty
            && !executor.hasUnsatisfiedConditions
        {
            // Single CTE: transition the run to WAITING (so the next child
            // completion can wake it), but check atomically whether any
            // event_waits for this run ALREADY have a matching task_completion
            // (meaning the child completed while we were RUNNING and its
            // event_wait survived because the wake was a no-op). If so, go
            // straight to PENDING — no need to wait for another signal.
            try await exec.postgres.query(
                """
                WITH
                missed AS (
                    -- event_waits whose children have already completed but whose
                    -- wake signal was silently dropped (parent was RUNNING at the time).
                    -- child_task_id is a typed UUID FK — direct join, no string parsing.
                    SELECT COUNT(*) AS cnt
                    FROM strand.event_waits ew
                    JOIN strand.task_completions tc ON tc.task_id = ew.child_task_id
                    WHERE ew.run_id        = \(claimed.runID)
                      AND ew.child_task_id IS NOT NULL
                ),
                run_upd AS (
                    UPDATE strand.runs
                    SET state            = CASE WHEN (SELECT cnt FROM missed) > 0
                                               THEN \(TaskState.pending)
                                               ELSE \(TaskState.waiting) END,
                        available_at     = CASE WHEN (SELECT cnt FROM missed) > 0
                                               THEN NOW()
                                               ELSE available_at END,
                        worker_id        = NULL,
                        lease_expires_at = NULL
                    WHERE id = \(claimed.runID)
                    RETURNING state
                )
                UPDATE strand.tasks
                SET state = (SELECT state FROM run_upd)
                WHERE id = \(claimed.taskID)
                  AND namespace_id = \(exec.namespace)
                """,
                logger: exec.logger
            )
        }

        // Still suspended — keep the cached Task alive.
        return nil
    }
}

// MARK: - AnyRegistration

/// Type-erased handler entry stored in ``Registry``.
///
/// Returns a non-nil `ByteBuffer` when the run completed and produced a result,
/// or `nil` when a workflow activation suspended cleanly (DB already updated).
///
/// `fatalDeadline` is the per-task 2×-claimTimeout deadline created in `runTask`.
/// Activities forward it into their heartbeat closure so that a heartbeating
/// activity keeps the deadline alive as long as it is making progress.
/// Workflow activations ignore it (they are short-lived replays).
///
/// `_WorkerExec` is NOT in the signature — all closures capture the shared exec
/// from `StrandWorker.init` which carries `localActivityLookup`. Passing it as
/// a parameter would allocate a new `_WorkerExec` (including an empty Dictionary)
/// on every task claim even though every caller ignores the parameter.
struct AnyRegistration: Sendable {
    let name: String
    let queueName: String
    let run: @Sendable (ClaimedTask, TaskDeadline) async throws -> ByteBuffer?
}

// MARK: - StrandWorker

/// A `Service`-conformant worker that drives the poll-claim-execute loop for one Postgres queue.
///
/// Register workflows by metatype and activities as instances or via containers:
///
/// ```swift
/// let worker = StrandWorker(
///     postgres: postgres,
///     options: .init(queue: "orders", workflowConcurrency: 4, activityConcurrency: 8),
///     workflows: [OrderWorkflow.self, FulfillmentWorkflow.self],
///     activityContainers: [PaymentActivities(stripe: stripe)],
///     activities: [NotificationActivity()]
/// )
///
/// let group = ServiceGroup(
///     configuration: .init(
///         services: [.init(service: postgres), .init(service: worker)],
///         gracefulShutdownSignals: [.sigterm, .sigint],
///         logger: logger
///     )
/// )
/// try await group.run()
/// ```
/// Wraps `any MetricsFactory` so it can be stored as a `let` on `StrandWorker`.
/// `MetricsFactory` inherits `Sendable` via `_SwiftMetricsSendableProtocol`, so
/// `any MetricsFactory` is `Sendable` and the compiler synthesises conformance
/// for this struct automatically — no `@unchecked` needed.
private struct _MetricsFactoryBox: Sendable {
    let value: any MetricsFactory
}

public struct StrandWorker: Service {
    private let postgres: PostgresClient
    private let options: WorkerOptions
    /// The namespace this worker operates in (mirrors `namespace`).
    /// Stored as a top-level field to avoid `namespace` at every call site.
    private let namespace: String
    /// Metrics backend. Defaults to the globally bootstrapped `MetricsSystem.factory`.
    /// Pass a test factory in tests to capture metrics without touching the global system.
    private let _metrics: _MetricsFactoryBox
    /// Logger for this worker instance.
    private let logger: Logger
    /// `Sendable` handler registry — a class reference whose `let` store is
    /// data-race free by construction (written once in `init`, never mutated).
    private let _registry: Registry

    /// Creates a worker with typed registration arrays.
    ///
    /// ```swift
    /// let worker = StrandWorker(
    ///     postgres: postgres,
    ///     options: WorkerOptions(queue: "orders", workflowConcurrency: 100),
    ///     workflows: [OrderWorkflow.self, FulfillmentWorkflow.self],
    ///     activityContainers: [PaymentActivities(stripe: stripe)],
    ///     activities: [NotificationActivity()]
    /// )
    /// ```
    public init(
        postgres: PostgresClient,
        options: WorkerOptions = .init(),
        workflows: [any WorkflowRegistrable.Type] = [],
        activityContainers: [any ActivityContainerProtocol] = [],
        activities: [any ActivityBox] = [],
        logger: Logger = Logger(label: "dev.strand.worker"),
        metricsFactory: (any MetricsFactory)? = nil
    ) {
        self.postgres = postgres
        self.options = options
        self.namespace = options.namespace
        self.logger = logger
        self._metrics = _MetricsFactoryBox(value: metricsFactory ?? MetricsSystem.factory)

        // Build local-activity lookup FIRST so it can be embedded in exec.
        // The lookup maps activity name → in-process runner closure (no DB row).
        let allActivities = activityContainers.flatMap { $0.activities } + activities
        var localLookup: [String: @Sendable (ByteBuffer, _WorkerExec, UUID?) async throws -> ByteBuffer] = [:]
        for box in allActivities {
            let token = box._makeToken()
            localLookup[token.name] = token.runLocal
        }

        let exec = _WorkerExec(
            postgres: postgres,
            queue: options.queue,
            namespace: namespace,
            logger: logger,
            options: options,
            localActivityLookup: localLookup
        )

        // Collect all registrations into a flat array so Registry can store them
        // as a `let` constant — no Mutex or nonisolated(unsafe) required.
        var registrations: [AnyRegistration] = []
        registrations.reserveCapacity(workflows.count + allActivities.count)

        for wfType in workflows {
            let token = wfType._makeToken()
            let queue = token.preferredQueue ?? options.queue
            registrations.append(
                AnyRegistration(
                    name: token.name,
                    queueName: queue,
                    run: { [token, exec] claimed, _ in try await token.activate(claimed, exec) }
                )
            )
        }

        for box in allActivities {
            let token = box._makeToken()
            let queue = token.preferredQueue ?? options.queue
            registrations.append(
                AnyRegistration(
                    name: token.name,
                    queueName: queue,
                    run: { [token, exec] claimed, deadline in
                        try await token.run(claimed, exec, deadline)
                    }
                )
            )
        }

        self._registry = Registry(registrations)
    }

    // MARK: - Service

    public func run() async throws {
        let workerID =
            options.workerID
            ?? "\(ProcessInfo.processInfo.hostName):\(ProcessInfo.processInfo.processIdentifier)"
        let scopedLogger = logger.withWorkerContext(
            queue: options.queue,
            namespace: namespace,
            workerID: workerID
        )
        scopedLogger.info(
            "worker starting",
            metadata: [
                "strand.concurrency.workflow": .stringConvertible(options.workflowConcurrency),
                "strand.concurrency.activity": .stringConvertible(options.activityConcurrency),
            ]
        )
        defer { scopedLogger.info("worker stopped") }

        // One-time: ensure the namespace and queue rows exist before polling.
        // registerNamespace is idempotent (ON CONFLICT DO NOTHING) so the
        // "default" namespace is never duplicated, and any custom namespace
        // declared by an application is auto-created without manual SQL.
        try await Queries.registerNamespace(
            on: postgres,
            namespaceID: namespace,
            logger: logger
        )
        try await Queries.createQueue(
            on: postgres,
            namespaceID: namespace,
            name: options.queue,
            logger: logger
        )

        let (stream, cont) = AsyncStream.makeStream(of: Void.self)

        try await withTaskCancellationOrGracefulShutdownHandler {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.pollLoop(workerID: workerID) }
                    group.addTask { try await self.leaseExpiryLoop() }
                    group.addTask {
                        // Wait for shutdown signal.
                        await stream.first { _ in true }

                        // Immediately expire all in-flight runs for this worker so
                        // the next worker's leaseExpiryLoop picks them up on its
                        // first sweep rather than waiting up to claimTimeout.
                        // Runs in structured context — guaranteed to finish or be
                        // cancelled with everything else. No fire-and-forget Task needed.
                        let _ = try? await self.postgres.query(
                            """
                            UPDATE strand.runs
                            SET lease_expires_at = NOW()
                            WHERE worker_id     = \(workerID)
                              AND namespace_id  = \(self.namespace)
                              AND state         = \(TaskState.running)
                            """,
                            logger: self.logger
                        )

                        try Task.checkCancellation()
                        try await Task.sleep(for: self.options.gracefulShutdownTimeout)
                    }
                    try await group.next()
                    group.cancelAll()
                }
            } catch is CancellationError {}
        } onCancelOrGracefulShutdown: {
            cont.finish()  // unblocks the shutdown task in the group above
        }
    }

    // MARK: - Poll loop

    /// Continuously claims and executes tasks using a slot-aware dispatch loop.
    ///
    /// The loop runs as the body of a `withThrowingDiscardingTaskGroup`. On each
    /// iteration it claims up to `free = maxConcurrency - running` tasks and starts
    /// each as an independent group child. When a child finishes it decrements the
    /// counter and signals `_SlotSignal`, waking the loop to claim the next batch
    /// without waiting for other in-flight tasks to complete.
    ///
    /// When all slots are occupied the loop parks on `_SlotSignal` — a
    /// `Mutex`-backed async wakeup that resumes as soon as any slot is freed.
    private func pollLoop(workerID: String) async throws {
        let queueName = options.queue
        let maxConcurrency =
            options.batchSize ?? (options.workflowConcurrency + options.activityConcurrency)
        let claimSecs = Int(options.claimTimeout.components.seconds)

        // Slot counter shared between the dispatch body and execution tasks.
        // `_RunningCounter` is `Sendable`; concurrent increment/decrement are
        // data-race free via its internal `Mutex`.
        let running = _RunningCounter()
        let slotFreeSignal = _SlotSignal()

        // Dispatch body: claims work when slots are available, parks when full.
        // Execution tasks are added as independent children of the same group
        // so cancellation propagates cleanly on graceful shutdown.
        try await withThrowingDiscardingTaskGroup { group in
            while true {
                try Task.checkCancellation()

                let free = maxConcurrency - running.value

                // ── All slots occupied: wait for a completion ──────────────────
                if free <= 0 {
                    try await slotFreeSignal.wait()
                    continue
                }

                // ── Claim up to `free` tasks ───────────────────────────────────
                let claimed: [ClaimedTask]
                do {
                    claimed = try await Queries.claimTasks(
                        on: postgres,
                        namespaceID: namespace,
                        queue: queueName,
                        workerID: workerID,
                        claimTimeoutSeconds: claimSecs,
                        qty: free,
                        logger: logger
                    )
                } catch {
                    if let handler = options.onError {
                        await handler(error)
                    } else {
                        logger.error(
                            "poll error",
                            metadata: .forError(error) + ["strand.queue": .string(queueName)]
                        )
                    }
                    try Task.checkCancellation()
                    try await Task.sleep(for: options.pollInterval)
                    continue
                }

                if claimed.isEmpty {
                    // No runnable tasks — sleep until next poll tick.
                    // LISTEN/NOTIFY wakeup would eliminate this sleep on the busy path.
                    try Task.checkCancellation()
                    try await Task.sleep(for: options.pollInterval)
                    continue
                }

                // If shutdown arrived while waiting for claimTasks, fast-expire
                // the claimed runs so the next worker picks them up immediately.
                try Task.checkCancellation()

                _metrics.value
                    .makeCounter(
                        label: StrandMetrics.tasksClaimed,
                        dimensions: [("queue", queueName)]
                    )
                    .increment(by: Int64(claimed.count))

                // ── Start each task as an independent group child ──────────────
                // Increment BEFORE addTask so freeSlots is correct on the next
                // loop iteration before any task has had a chance to finish.
                for claimedTask in claimed {
                    running.increment()
                    group.addTask {
                        defer {
                            running.decrement()
                            slotFreeSignal.signal()
                        }
                        await self.runTask(claimedTask)
                    }
                }
                // No explicit sleep: fall through to re-poll immediately.
                // If claimed.count < free there is still open capacity for another
                // batch. If claimed.count == free the next iteration finds free == 0
                // and blocks on slotFreeSignal until a running task finishes.
            }
        }
    }

    // MARK: - Lease expiry sweep

    private func leaseExpiryLoop() async throws {
        let queueName = options.queue

        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: options.leaseExpiryInterval)
            do {
                try await Queries.sweepExpiredLeases(
                    on: postgres,
                    namespaceID: namespace,
                    queue: queueName,
                    logger: logger
                )
            } catch {
                logger.error(
                    "lease sweep error",
                    metadata: .forError(error) + ["strand.queue": .string(queueName)]
                )
            }
        }
    }

    // MARK: - Task execution

    private func runTask(_ claimed: ClaimedTask) async {
        // Scope the logger to this specific task/run for structured log output.
        let taskLogger = logger.withTaskContext(claimed)

        // Unknown task name — defer with jittered backoff so a rolling deploy that adds
        // a new task type doesn't spin-loop on workers that haven't updated yet.
        guard let reg = _registry.lookup(claimed.taskName) else {
            let delay = unknownTaskDelay(seed: claimed.runID.uuidString)
            let wakeAt = Date.now.addingTimeInterval(Double(delay.components.seconds))
            do {
                try await Queries.scheduleRun(
                    on: postgres,
                    namespaceID: namespace,
                    runID: claimed.runID,
                    taskID: claimed.taskID,
                    wakeAt: wakeAt,
                    logger: taskLogger
                )
            } catch {
                taskLogger.error("failed to defer unknown task", metadata: .forError(error))
            }
            return
        }

        // Per-task timeout takes precedence for the fatal deadline.
        // Zero is treated as nil ("use worker default") so that a user who
        // accidentally passes 0 doesn't get an immediately-expired deadline.
        let fatalDeadlineTimeout: Duration
        if let taskTimeoutSecs = claimed.timeoutSeconds, taskTimeoutSecs > 0 {
            fatalDeadlineTimeout = .seconds(taskTimeoutSecs)
        } else {
            fatalDeadlineTimeout = options.claimTimeout + options.claimTimeout
        }
        let fatalDeadline = TaskDeadline(timeout: fatalDeadlineTimeout)

        let taskStart = ContinuousClock.now
        let taskDims: [(String, String)] = [
            ("task_name", claimed.taskName),
            ("queue", options.queue),
        ]

        // ── Race execution against 2× timeout ─────────────────────────
        // Execution and deadline enforcement run as structured children of the
        // same group — whichever finishes first cancels the other cleanly.
        do {
            let resultBuf: ByteBuffer? = try await withThrowingTaskGroup(of: ByteBuffer?.self) {
                group in

                // Task 1: actual task execution.
                group.addTask {
                    defer {
                        let elapsed = ContinuousClock.now - taskStart
                        self._metrics.value
                            .makeTimer(label: StrandMetrics.taskDuration, dimensions: taskDims)
                            .recordNanoseconds(elapsed.nanoseconds)
                    }
                    // OTel span: one span per task execution attempt.
                    // If no tracing backend is bootstrapped this is a zero-cost no-op.
                    return try await withSpan(claimed.taskName, ofKind: .internal) { span in
                        span.attributes[StrandLogKeys.taskName] = SpanAttribute.string(
                            claimed.taskName
                        )
                        span.attributes[StrandLogKeys.taskKind] = SpanAttribute.string(
                            claimed.kind.rawValue
                        )
                        span.attributes[StrandLogKeys.taskID] = SpanAttribute.string(
                            claimed.taskID.uuidString.lowercased()
                        )
                        span.attributes[StrandLogKeys.runID] = SpanAttribute.string(
                            claimed.runID.uuidString.lowercased()
                        )
                        span.attributes[StrandLogKeys.queue] = SpanAttribute.string(options.queue)
                        span.attributes[StrandLogKeys.attempt] = SpanAttribute.int(
                            Int64(claimed.attempt)
                        )
                        return try await reg.run(claimed, fatalDeadline)
                    }
                }

                // Task 2: deadline poller — two escalating thresholds:
                //   1× claimTimeout → log a warning (task is running long)
                //   2× claimTimeout → cancel execution (fatalDeadline expired)
                group.addTask {
                    var warnedSlow = false
                    do {
                        while true {
                            try Task.checkCancellation()
                            try await Task.sleep(for: .milliseconds(500))
                            let elapsed = ContinuousClock.now - taskStart
                            // 1× warning — fires once when task exceeds claimTimeout
                            if !warnedSlow, elapsed > options.claimTimeout {
                                warnedSlow = true
                                taskLogger.warning(
                                    "task \(claimed.taskName) (\(claimed.taskID)) exceeded claim timeout (\(options.claimTimeout)) — still running"
                                )
                            }
                            // 2× fatal — cancel execution
                            if fatalDeadline.isExpired {
                                taskLogger.critical(
                                    "task \(claimed.taskName) (\(claimed.taskID)) exceeded 2× claim timeout — cancelling"
                                )
                                throw ClaimTimeoutError()
                            }
                        }
                    } catch is CancellationError {
                        return nil  // Task 1 won the race — exit cleanly
                    }
                    // ClaimTimeoutError propagates out to the group
                }

                // First child to finish wins; cancel the other.
                let result = try await group.next()
                group.cancelAll()
                return result ?? nil
            }

            if let buf = resultBuf {
                // Run produced a result — mark COMPLETED with CAS on version.
                try await Queries.completeRun(
                    on: postgres,
                    namespaceID: namespace,
                    runID: claimed.runID,
                    version: claimed.version,
                    resultBuffer: buf,
                    logger: logger
                )
            }
            _metrics.value.makeCounter(label: StrandMetrics.tasksCompleted, dimensions: taskDims)
                .increment(by: 1)
            // nil → workflow suspended cleanly; DB already transitioned to SLEEPING.
        } catch is CancellationError {
            // Worker is shutting down (graceful SIGTERM or forced cancellation).
            // Leave the run in RUNNING state — the leaseExpiryLoop sweep will
            // call failRun when lease_expires_at elapses (within leaseExpiryInterval).
            // This avoids incrementing the attempt counter for a shutdown that is
            // not a task failure.
        } catch InternalError.cancelled {
            _metrics.value.makeCounter(label: StrandMetrics.tasksSuspended, dimensions: taskDims)
                .increment(by: 1)
            // Task was cancelled externally (e.g. heartbeat found state != RUNNING).
        } catch let signal as _ContinueAsNewSignal {
            _metrics.value.makeCounter(
                label: StrandMetrics.tasksContinuedAsNew,
                dimensions: taskDims
            ).increment(by: 1)
            do {
                if claimed.parentWorkflowID != nil {
                    // ── Child workflow ────────────────────────────────────────────────
                    // Reuse the same task_id so the parent's event_wait (child_task_id)
                    // keeps tracking this task. The parent stays
                    // WAITING; when the chain terminates with a real result, completeRun
                    // fires emitTaskCompletionSignal and the parent receives it.
                    try await Queries.continueChildWorkflowAsNew(
                        on: postgres,
                        namespaceID: signal.namespaceID,
                        taskID: claimed.taskID,
                        currentRunID: claimed.runID,
                        currentVersion: claimed.version,
                        newInput: signal.input,
                        newRunID: UUID.v7(),
                        logger: logger
                    )
                } else {
                    // ── Root workflow ─────────────────────────────────────────────────
                    // No parent is tracking this task_id, so a fresh task is fine.
                    _ = try await Queries.enqueueTask(
                        on: postgres,
                        namespaceID: signal.namespaceID,
                        queue: signal.queue,
                        taskName: signal.workflowName,
                        paramsBuffer: signal.input,
                        headersBuffer: nil,
                        retryStrategyBuffer: nil,
                        maxAttempts: nil,
                        cancellationBuffer: nil,
                        idempotencyKey: nil,
                        priority: TaskPriority.normal.rawValue,
                        scheduledAt: nil,
                        fairnessKey: nil,
                        fairnessWeight: 1.0,
                        kind: .workflow,
                        parentTaskID: nil,
                        logger: logger
                    )
                    try await Queries.completeRun(
                        on: postgres,
                        namespaceID: signal.namespaceID,
                        runID: claimed.runID,
                        version: claimed.version,
                        resultBuffer: nil,
                        logger: logger
                    )
                }
            } catch {
                taskLogger.error("continue-as-new failed", metadata: .forError(error))
            }
        } catch let typed as _TypedActivityFailure {
            // Pre-encoded failure reason from ActivityDefinition._run — use verbatim.
            _metrics.value.makeCounter(label: StrandMetrics.tasksFailed, dimensions: taskDims)
                .increment(by: 1)
            do {
                try await Queries.failRun(
                    on: postgres,
                    namespaceID: namespace,
                    runID: claimed.runID,
                    reasonBuffer: typed.reasonBuffer,
                    logger: logger
                )
            } catch {
                taskLogger.error(
                    "failRun DB call failed — run will be swept by leaseExpiryLoop",
                    metadata: .forError(error)
                )
            }
        } catch {
            _metrics.value.makeCounter(label: StrandMetrics.tasksFailed, dimensions: taskDims)
                .increment(by: 1)
            let reason = FailureReason(error: error)
            do {
                let buf =
                    (try? JSON.encode(reason))
                    ?? ByteBuffer(string: #"{"name":"unknown","message":"encoding failed"}"#)
                try await Queries.failRun(
                    on: postgres,
                    namespaceID: namespace,
                    runID: claimed.runID,
                    reasonBuffer: buf,
                    logger: logger
                )
            } catch {
                taskLogger.error(
                    "failRun DB call failed — run will be swept by leaseExpiryLoop",
                    metadata: .forError(error)
                )
            }
        }
    }
}

// MARK: - Registry

/// Immutable handler registry built once at `StrandWorker.init` time.
///
/// Receives all registrations through its initialiser so the store can be
/// a `let` constant.  A `let [String: AnyRegistration]` on a `final class`
/// is `Sendable` by definition — no `Mutex`, no `nonisolated(unsafe)`,
/// no escape hatch needed.
final class Registry: Sendable {
    private let store: [String: AnyRegistration]

    init(_ registrations: [AnyRegistration]) {
        var s = [String: AnyRegistration](minimumCapacity: registrations.count)
        for r in registrations { s[r.name] = r }
        store = s
    }

    func lookup(_ name: String) -> AnyRegistration? {
        store[name]
    }
}

/// Thrown by the 2× deadline poller (Task 2 inside `runTask`) when the
/// fatal deadline expires. Propagates out of the `withThrowingTaskGroup`,
/// cancels the execution task, and is caught as a general failure.
private struct ClaimTimeoutError: Error {}

// MARK: - FailureReason

/// Structured error record stored in `strand.runs.failure_reason` (BYTEA / JSON).
///
/// Field layout: `name` is the Swift type name, `message` is the human-readable
/// `localizedDescription`, `cause` chains inner errors recursively, and
/// `source` captures the `#fileID` + `#line` of the `WorkflowContext` call that
/// first observed the failure (e.g. which `context.runActivity(...)` line threw).
// A final class (not struct) because `cause` is recursive — Swift value types
// cannot have stored properties that directly contain themselves.
private final class FailureReason: Codable, Sendable {
    let name: String
    let message: String
    let cause: FailureReason?
    let source: SourceLocation?

    struct SourceLocation: Codable, Sendable {
        let fileID: String
        let line: Int
        enum CodingKeys: String, CodingKey {
            case fileID = "file_id"
            case line
        }
    }

    init(error: any Error) {
        // Priority 1: call-site annotation stamped by WorkflowContext.runActivity etc.
        if let annotated = error as? CallSiteAnnotatedError {
            name = String(describing: Swift.type(of: annotated.underlying))
            message = strandErrorMessage(annotated.underlying)
            source = SourceLocation(fileID: annotated.fileID, line: annotated.line)
            cause = FailureReason.makeCause(from: annotated.underlying)
            // Priority 2: error carries its own throw-site via LocatableError.
        } else if let located = error as? any LocatableError {
            name = String(describing: Swift.type(of: error))
            message = strandErrorMessage(error)
            source = SourceLocation(fileID: located.sourceFileID, line: located.sourceLine)
            cause = FailureReason.makeCause(from: error)
        } else {
            name = String(describing: Swift.type(of: error))
            message = strandErrorMessage(error)
            source = nil
            cause = FailureReason.makeCause(from: error)
        }
    }

    /// Recursively extracts a cause for errors that carry an underlying error.
    /// Currently handles `StrandError.database` and `StrandError.serialization`.
    private static func makeCause(from error: any Error) -> FailureReason? {
        guard let se = error as? StrandError else { return nil }
        switch se {
        case .database(let underlying): return FailureReason(error: underlying)
        case .serialization(let underlying): return FailureReason(error: underlying)
        default: return nil
        }
    }
}

// MARK: - Poll loop helpers

/// Running-task counter shared between the dispatch body and each execution
/// task inside `pollLoop`. `Sendable`-conformant: concurrent `increment()` and
/// `decrement()` calls are data-race free via the internal `Mutex`.
///
/// Stored as a `final class` so it can be captured by multiple closures without
/// copying (Swift’s `Mutex` is `~Copyable` and cannot be captured by value).
private final class _RunningCounter: Sendable {
    private let _mutex: Mutex<Int> = Mutex(0)

    var value: Int { _mutex.withLock { $0 } }

    func increment() { _mutex.withLock { $0 += 1 } }
    func decrement() { _mutex.withLock { $0 -= 1 } }
}

/// Single-pending async wakeup signal.
///
/// The poll-loop dispatcher parks here when all concurrency slots are full.
/// Each execution task calls `signal()` from its `defer` block when it
/// finishes, immediately waking the dispatcher so it can claim more work.
///
/// Uses `withTaskCancellationHandler` + explicit `onCancel` that resumes the stored
/// continuation.  This guarantees the continuation is ALWAYS resumed — either
/// by `signal()` or by the cancellation handler — so no `_runTimer`
/// continuation can ever be orphaned.
private final class _SlotSignal: Sendable {
    private struct _State {
        var pending: Bool = false
        var continuation: CheckedContinuation<Void, Never>? = nil
    }
    private let _mutex: Mutex<_State> = Mutex(.init())

    /// Wake one waiting `wait()` call.  If nobody is waiting yet, the signal
    /// is stored and the next `wait()` returns immediately (buffer-of-1).
    func signal() {
        let cont = _mutex.withLock { s -> CheckedContinuation<Void, Never>? in
            if let c = s.continuation {
                s.continuation = nil
                return c
            }
            s.pending = true
            return nil
        }
        cont?.resume()
    }

    /// Suspend until the next `signal()`, or return immediately if one is
    /// already pending.  Throws `CancellationError` when the enclosing task
    /// is cancelled while waiting — the cancellation handler explicitly
    /// resumes the continuation so it is never leaked.
    func wait() async throws {
        // Fast path 1: task already cancelled before we reach the wait.
        try Task.checkCancellation()

        // Fast path 2: a signal arrived before any waiter was registered.
        let alreadyPending = _mutex.withLock { s -> Bool in
            guard s.pending else { return false }
            s.pending = false
            return true
        }
        if alreadyPending { return }

        // Slow path: park the continuation until signal() or cancellation.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                // Race between signal() arriving after fast-path check and now.
                let raced = _mutex.withLock { s -> Bool in
                    if s.pending {
                        s.pending = false
                        return true  // signal already here — resume immediately
                    }
                    s.continuation = cont
                    return false
                }
                if raced { cont.resume() }
            }
        } onCancel: {
            // Resume synchronously from the canceller’s thread so the
            // dispatcher unblocks and can call Task.checkCancellation().
            let cont = _mutex.withLock { s -> CheckedContinuation<Void, Never>? in
                let c = s.continuation
                s.continuation = nil
                return c
            }
            cont?.resume()
        }

        // After waking from cancellation, throw so the dispatch loop exits.
        try Task.checkCancellation()
    }
}
