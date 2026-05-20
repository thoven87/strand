import NIOCore
import PostgresNIO
import Tracing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - applyScheduleCommands

extension WorkflowRegistration {

    /// Shared post-drain logic called by both `_activate` (fresh path) and
    /// `resumeActivation` (cached path) after their unique setup steps.
    ///
    /// Covers in order:
    ///   1. Checkpoint persistence (`writeCheckpoint` commands)
    ///   2. Replay history events (`timerFired`, `eventReceived`)
    ///   3. Terminal result switch (.success → encode+return, .failure → throw)
    ///   4. Suspended path: schedule-commands loop (activity / timer / event / child)
    ///   5. Event_wait registration + atomic completion check
    ///   6. Unsatisfied-condition DB transitions (SLEEPING / WAITING)
    ///   7. Partial-completion re-wait (safe no-op on the fresh path)
    ///   8. Cache set + return nil
    ///
    /// - Returns: encoded `ByteBuffer` on successful completion, `nil` when suspended.
    /// - Throws: on handler failure or re-thrown lifecycle signal.
    func applyScheduleCommands(
        commands: [WorkflowCommand],
        executor: StrandWorkflowExecutor,
        claimed: ClaimedTask,
        exec: _WorkerExec,
        activation: _WorkflowActivation<W>,
        cache: _WorkflowTaskCache<W>,
        handlerResult: ArcBox<Result<W.Output, Error>?>,
        handlerTask: Task<Void, Never>,
        stateBox: ArcBox<W>,
        historySeq: inout Int,
        claimTimeoutSecs: Int
    ) async throws -> ByteBuffer? {

        // ── 1. Persist checkpoints ────────────────────────────────────────────────────

        // Local helper — captures the five fixed appendHistory parameters so each
        // call site only specifies the two that vary (eventType, eventData).
        // A nested `func` (not a stored closure) is used because it can capture
        // the `inout historySeq` parameter directly.
        // History accumulator — populated synchronously by record(), flushed in one
        // batchAppendHistory call at each exit point. record() has zero DB I/O;
        // all history events are committed in a single round-trip at activation exit.
        var pendingHistory: [(seq: Int, eventType: WorkflowStateQueries.HistoryEventType, eventData: ByteBuffer?)] = []
        var pendingCheckpoints: [(seqNum: Int, name: String?, state: ByteBuffer)] = []

        // record() is now a pure synchronous accumulator — no DB I/O, no try await.
        func record(_ type: WorkflowStateQueries.HistoryEventType, _ data: ByteBuffer?) {
            pendingHistory.append((seq: historySeq, eventType: type, eventData: data))
            historySeq += 1
        }

        // Flush: write activity-result checkpoints and history events in one transaction.
        //
        // Atomicity guarantee: if the transaction fails the next fresh-path activation
        // replays fully — fast-path-1 does not trigger because no checkpoint exists —
        // and both are written correctly on the retry.
        //
        // Clears pendingCheckpoints and pendingHistory after a successful commit so that
        // flushWrites() can be called multiple times (once combined with a state transition
        // in step 7, once at step 8 for any remaining items) without double-writing.
        func flushWrites() async throws {
            guard !pendingCheckpoints.isEmpty || !pendingHistory.isEmpty else { return }
            try await exec.postgres.withTransaction(logger: exec.logger) { conn in
                if !pendingCheckpoints.isEmpty {
                    try await Queries.batchSetCheckpointsOnConn(
                        on: conn,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        runID: claimed.runID,
                        checkpoints: pendingCheckpoints,
                        logger: exec.logger
                    )
                    // Extend the claim if the run is still RUNNING. For SLEEPING/WAITING
                    // runs (workflow suspended via sleep/waitForEvent/condition) extendClaim
                    // returns no rows and throws InternalError.cancelled — the run has already
                    // transitioned out of RUNNING and sweepExpiredLeases only targets RUNNING
                    // runs, so no extension is needed. Catch the error so the transaction
                    // still commits with the checkpoint and history writes intact.
                    do {
                        try await Queries.extendClaim(
                            on: conn,
                            namespaceID: exec.namespace,
                            runID: claimed.runID,
                            extendBySeconds: claimTimeoutSecs,
                            logger: exec.logger
                        )
                    } catch InternalError.cancelled {
                        // Run already transitioned to SLEEPING/WAITING/PENDING — no lease
                        // extension needed; checkpoints and history still commit.
                    }
                }
                if !pendingHistory.isEmpty {
                    try await WorkflowStateQueries.batchAppendHistory(
                        on: conn,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        events: pendingHistory,
                        logger: exec.logger
                    )
                }
            }
            // Clear after successful commit so double-calling is safe (no duplicate writes).
            pendingCheckpoints.removeAll()
            pendingHistory.removeAll()
        }

        // Non-suspending writes first — accumulated into pendingCheckpoints and written
        // atomically with history in flushWrites(). The in-memory cache is populated
        // immediately so fast-path-1 works within the same activation chain.
        let checkpointWrites = commands.compactMap {
            cmd -> (seqNum: Int, name: String?, state: ByteBuffer)? in
            if case .writeCheckpoint(let seqNum, let name, let value) = cmd {
                return (seqNum: seqNum, name: name, state: value)
            }
            return nil
        }
        for (seqNum, name, value) in checkpointWrites {
            pendingCheckpoints.append((seqNum: seqNum, name: name, state: value))
            activation.cacheCheckpoint(seqNum: seqNum, name: name, buffer: value)
        }

        // ── 1b. Version marker writes (queryable projection of version checkpoints) ─
        let versionMarkerWrites = commands.compactMap { cmd -> (changeID: String, value: Bool)? in
            if case .recordVersionMarker(let changeID, let value) = cmd { return (changeID, value) }
            return nil
        }
        if !versionMarkerWrites.isEmpty {
            try await WorkflowStateQueries.batchWriteVersionMarkers(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                markers: versionMarkerWrites,
                logger: exec.logger
            )
        }

        // ── 2. Replay fast-path history events (TIMER_FIRED, EVENT_RECEIVED) ─────────
        for cmd in commands {
            switch cmd {
            case .timerFired(let timerSeqNum):
                record(.timerFired, try! JSON.encode(WorkflowStateQueries.TimerFiredData(seqNum: timerSeqNum)))
            case .eventReceived(let eventName):
                record(.eventReceived, try! JSON.encode(WorkflowStateQueries.NamedEventData(eventName: eventName)))
            case .eventWaitTimedOut(let eventName, let seqNum):
                try await Queries.writeEventWaitTimedOut(
                    on: exec.postgres,
                    namespaceID: exec.namespace,
                    taskID: claimed.taskID,
                    runID: claimed.runID,
                    seqNum: seqNum,
                    historySeq: historySeq,
                    eventName: eventName,
                    logger: exec.logger
                )
                historySeq += 1
            case .conditionMet(let seqNum):
                if let seqNum = seqNum {
                    // Timeout variant — write sentinel + history atomically.
                    try await Queries.writeConditionResult(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        runID: claimed.runID,
                        seqNum: seqNum,
                        historySeq: historySeq,
                        met: true,
                        logger: exec.logger
                    )
                    historySeq += 1
                } else {
                    // No-timeout variant — no checkpoint guard, just write history.
                    record(.conditionMet, nil)
                }
            case .conditionTimedOut(let seqNum):
                try await Queries.writeConditionResult(
                    on: exec.postgres,
                    namespaceID: exec.namespace,
                    taskID: claimed.taskID,
                    runID: claimed.runID,
                    seqNum: seqNum,
                    historySeq: historySeq,
                    met: false,
                    logger: exec.logger
                )
                historySeq += 1
            case .activityCompleted(let name, let seqNum, let failed):
                // Write ACTIVITY_STARTED before ACTIVITY_COMPLETED so the history tab shows
                // the actual queue wait time. Data comes from strand.runs via resolveCompleted —
                // no extra DB round-trip, no separate connection, no advisory locks.
                if let startInfo = executor.preloadedStartInfo(for: seqNum) {
                    record(
                        .activityStarted,
                        try! JSON.encode(
                            WorkflowStateQueries.ActivityStartedData(
                                activity: name,
                                seqNum: seqNum,
                                attempt: startInfo.attempt,
                                workerID: startInfo.workerID ?? "",
                                startedAt: startInfo.startedAt
                            )
                        )
                    )
                }
                // Record activity completion or failure. runActivity emits this command
                // exactly once; for successes the accompanying .writeCheckpoint ensures
                // replays return from fast-path-1 without re-emitting; for failures an
                // ActivityFailedSentinel checkpoint guards the same invariant.
                record(
                    failed ? .activityFailed : .activityCompleted,
                    try! JSON.encode(WorkflowStateQueries.ActivityScheduledData(activity: name, seqNum: seqNum))
                )
            case .childWorkflowCompleted(let name, let seqNum):
                // Record child workflow completion. runChildWorkflow emits this command
                // exactly once; the accompanying checkpoint ensures replays return from
                // fast-path-1 without re-emitting.
                record(
                    .childWorkflowCompleted,
                    try! JSON.encode(WorkflowStateQueries.ChildWorkflowData(workflow: name, seqNum: seqNum))
                )
            case .emitEvent(let eventName, let payload):
                // Non-suspending: write to strand.events directly here.
                // Processed in this step-2 loop (before the terminal-result check in step 3)
                // so the DB write happens whether the handler completed or suspended —
                // a workflow that calls emitEvent and then returns in the same activation
                // would never reach the step-4 scheduleCommands loop.
                // Append-only: replay inserts a second row, but duplicate emits find no
                // active waiters (already woken by the first), so wakeups are exactly-once.
                try await Queries.emitEvent(
                    on: exec.postgres,
                    namespaceID: exec.namespace,
                    queue: exec.queue,
                    eventName: eventName,
                    payloadBuffer: payload,
                    logger: exec.logger
                )
                // Record the emission in workflow history so it appears in the trace view.
                let emitData = try! JSON.encode(WorkflowStateQueries.NamedEventData(eventName: eventName))
                record(.eventEmitted, emitData)
            default:
                break
            }
        }

        // ── 3. Terminal result handling ──────────────────────────────────────────────
        switch handlerResult.value {

        case .success(let output):
            // Handler completed — persist final state and return the encoded result.
            // The caller (runTask) writes COMPLETED to the run.
            teardownHandler(cache: cache, taskID: claimed.taskID, handlerTask: handlerTask, executor: executor)
            let finalStateBuf = try JSON.encode(stateBox.value)
            try await WorkflowStateQueries.saveState(
                on: exec.postgres,
                taskID: claimed.taskID,
                namespaceID: exec.namespace,
                stateBuffer: finalStateBuf,
                logger: exec.logger
            )
            record(.workflowCompleted, nil)
            try await flushWrites()
            return try JSON.encode(output)

        case .failure(let error):
            // InternalError.cancelled is the internal suspension signal — not a real failure.
            // cancelPending() resumes all continuations with this error so the handler
            // Task parks cleanly between activations.
            if case InternalError.cancelled? = error as? InternalError { break }
            // _ContinueAsNewSignal is a lifecycle transition, not a failure.
            // Re-throw it unwrapped so runTask's typed catch matches it.
            // Without this guard, `lastCallSite` (set by the preceding
            // context.runActivity / runChildWorkflow call) would cause
            // CallSiteAnnotatedError to wrap the signal — defeating the
            // `catch let signal as _ContinueAsNewSignal` in runTask.
            if let signal = error as? _ContinueAsNewSignal {
                teardownHandler(cache: cache, taskID: claimed.taskID, handlerTask: handlerTask, executor: executor)
                throw signal
            }
            // CancellationError means the workflow received a cooperative cancel request
            // (parentClosePolicy = .requestCancel from a closing parent). The handler
            // Task was cancelled via handlerTask.cancel(); the first new suspension point
            // threw CancellationError. Transition to CANCELLED — not FAILED — and
            // unblock any awaitTaskResult callers.
            //
            // Distinct from worker-shutdown CancellationError (which propagates from
            // applyScheduleCommands' own await points, never reaching this branch).
            if error is CancellationError {
                teardownHandler(cache: cache, taskID: claimed.taskID, handlerTask: handlerTask, executor: executor)
                record(.workflowCancelled, nil)
                try await flushWrites()
                // Transition run + task to CANCELLED and wake awaitTaskResult callers.
                try await exec.postgres.withTransaction(logger: exec.logger) { conn in
                    try await conn.query(
                        """
                        WITH r AS (
                            UPDATE strand.runs
                            SET state = \(TaskState.cancelled), finished_at = NOW()
                            WHERE id          = \(claimed.runID)
                              AND state       = \(TaskState.running)
                        )
                        UPDATE strand.tasks
                        SET state        = \(TaskState.cancelled),
                            cancelled_at = NOW()
                        WHERE id          = \(claimed.taskID)
                          AND state NOT IN (
                              \(TaskState.completed), \(TaskState.failed), \(TaskState.cancelled)
                          )
                        """,
                        logger: exec.logger
                    )
                    try await Queries.emitTaskCompletionSignal(
                        conn: conn,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        state: .cancelled,
                        resultBuffer: nil,
                        logger: exec.logger
                    )
                }
                return nil
            }
            teardownHandler(cache: cache, taskID: claimed.taskID, handlerTask: handlerTask, executor: executor)
            let errData = try! JSON.encode(WorkflowStateQueries.WorkflowFailedData(error: String(describing: error)))
            record(.workflowFailed, errData)
            try await flushWrites()
            // Stamp the last WorkflowContext call site onto the error.
            if let site = activation.lastCallSite {
                throw CallSiteAnnotatedError(
                    underlying: error,
                    fileID: site.fileID,
                    line: site.line
                )
            }
            throw error

        case .none:  // Handler suspended — apply schedule commands below.
            break
        }

        // ── 4. Suspended: apply schedule commands ──────────────────────────────────
        // Declare the deferred-notify flag here (before the scheduleCommands loop) so
        // startTimer and awaitEvent can set it when the pending_sigs check transitions
        // the run directly to PENDING instead of SLEEPING/WAITING.
        var needsNotifyAfterFlush = false

        let scheduleCommands = commands.filter { cmd in
            switch cmd {
            case .scheduleActivity, .startTimer, .awaitEvent, .scheduleChildWorkflow:
                return true
            case .writeCheckpoint, .recordVersionMarker, .timerFired, .eventReceived, .eventWaitTimedOut,
                .conditionMet, .conditionTimedOut, .emitEvent, .activityCompleted, .childWorkflowCompleted:
                return false
            }
        }

        if !scheduleCommands.isEmpty {
            // Build a headers buffer carrying the current workflow activation span so
            // every activity and child workflow this activation spawns appears as a
            // child span in Jaeger / OTLP collectors rather than a disconnected trace.
            //
            // `ServiceContext.current` is the span opened by Worker.runTask's
            // `withSpan(claimed.taskName, ...)` — active for the entire duration of
            // drain() and applyScheduleCommands.  Injecting it here is the standard
            // W3C trace-context propagation pattern used by all async messaging systems
            // (Kafka, SQS, AMQP, etc.).  OTel parent-child relationships are causal,
            // not temporal — the child span may legitimately start after the parent ends.
            var _spanHeaders: [String: String] = [:]
            InstrumentationSystem.tracer.inject(
                ServiceContext.current ?? .topLevel,
                into: &_spanHeaders,
                using: DictionaryInjector()
            )
            let childHeadersBuf: ByteBuffer? =
                _spanHeaders.isEmpty ? nil : try? JSON.encode(_spanHeaders)

            // Collect child specs — activities and child workflows enqueued in one batch
            // transaction after the loop.  Timer and named-event commands continue to write
            // to the DB inline; their state transitions are independent of the child batch.
            var pendingChildren: [Queries.ChildEnqueueSpec] = []
            var childHistoryItems: [(eventType: WorkflowStateQueries.HistoryEventType, eventData: ByteBuffer?)] = []
            for cmd in scheduleCommands {
                switch cmd {
                case .scheduleActivity(
                    let name,
                    let actInput,
                    let options,
                    let seqNum,
                    let idKey
                ):
                    let rlParams = options.rateLimit.map { $0.slotParams(for: name) }
                    pendingChildren.append(
                        Queries.ChildEnqueueSpec(
                            seqNum: seqNum,
                            taskID: UUID.v7(),
                            runID: UUID.v7(),
                            queue: options.queue ?? exec.queue,
                            taskName: name,
                            paramsBuffer: actInput,
                            headersBuffer: childHeadersBuf,
                            retryStrategyBuffer: options.retryStrategy.flatMap { try? JSON.encode($0) },
                            maxAttempts: options.maxAttempts,
                            idempotencyKey: idKey,
                            priority: options.priority,
                            scheduledAt: options.delayUntil,
                            timeoutSeconds: options.timeout.map { Int($0.components.seconds) },
                            heartbeatTimeoutSeconds: options.heartbeatTimeout.map { Int($0.components.seconds) },
                            scheduleToStartTimeoutSeconds: options.scheduleToStartTimeout.map { Int($0.components.seconds) },
                            parentClosePolicy: options.cancellationType == .abandon
                                ? .abandon : options.cancellationType == .waitCancellationCompleted ? .waitCancellationCompleted : nil,
                            deadlineAt: options.maxDuration.map { activation.activationTime.addingDuration($0) },
                            fairnessKey: options.fairnessKey,
                            fairnessWeight: options.fairnessWeight,
                            kind: .activity,
                            rateLimitIntervalMs: rlParams?.intervalMs,
                            rateLimitKey: rlParams?.slotKey
                        )
                    )
                    childHistoryItems.append(
                        (
                            eventType: .activityScheduled,
                            eventData: try! JSON.encode(
                                WorkflowStateQueries.ActivityScheduledData(activity: name, seqNum: seqNum)
                            )
                        )
                    )

                case .startTimer(let wakeAt, let timerSeqNum):
                    // Flush accumulated checkpoints + history BEFORE the state transition
                    // so history is durable before the run leaves RUNNING state.
                    // For SLEEPING (normal case), available_at is in the future so there
                    // is no immediate race, but flushing first is still correct and cheap.
                    // For PENDING (pending_sigs case), this prevents a polling worker from
                    // claiming the run before history is committed.
                    try await flushWrites()
                    // Execute the transition and capture the resulting state so we know
                    // whether to send a notification (required when pending_sigs causes
                    // the run to go PENDING instead of SLEEPING).
                    let timerStateStream = try await exec.postgres.query(
                        """
                        WITH
                        pending_sigs AS (
                            SELECT COUNT(*) AS cnt FROM strand.workflow_signals
                            WHERE task_id     = \(claimed.taskID)
                              AND namespace_id = \(exec.namespace)
                        ),
                        r AS (
                            UPDATE strand.runs
                            SET state        = CASE WHEN (SELECT cnt FROM pending_sigs) > 0
                                                   THEN \(TaskState.pending)
                                                   ELSE \(TaskState.sleeping) END,
                                available_at = CASE WHEN (SELECT cnt FROM pending_sigs) > 0
                                                   THEN NOW()
                                                   ELSE \(wakeAt) END,
                                lease_expires_at = NULL
                            WHERE id = \(claimed.runID)
                            RETURNING state
                        )
                        UPDATE strand.tasks
                        SET state = (SELECT state FROM r)
                        WHERE id = \(claimed.taskID)
                        RETURNING (SELECT state FROM r)
                        """,
                        logger: exec.logger
                    )
                    // The UPDATE targets a single run_id so at most one row is returned.
                    if let timerRow = try await timerStateStream.first(where: { _ in true }) {
                        var col = timerRow.makeIterator()
                        let timerRunState = try col.next()!.decode(TaskState.self, context: .default)
                        if timerRunState == .pending { needsNotifyAfterFlush = true }
                    }
                    let timerData = try! JSON.encode(
                        WorkflowStateQueries.TimerStartedData(durationMs: Int(wakeAt.timeIntervalSinceNow * 1000), seqNum: timerSeqNum)
                    )
                    record(.timerStarted, timerData)

                case .emitEvent(let eventName, let payload):
                    // Append-only insert; duplicate emits find no active waiters so wakeups
                    // are still exactly-once. .emitEvent is excluded from scheduleCommands
                    // by the filter above — this case is unreachable at runtime but required
                    // for switch exhaustiveness.
                    try await Queries.emitEvent(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        queue: exec.queue,
                        eventName: eventName,
                        payloadBuffer: payload,
                        logger: exec.logger
                    )

                case .awaitEvent(let eventName, let seqNum, let timeoutAt, let predicate):
                    // Flush accumulated checkpoints + history BEFORE the withTransaction
                    // so history is durable before the run leaves RUNNING state.
                    // The withTransaction atomically registers the event_wait and checks
                    // whether the event already exists — this prevents the lost-wakeup
                    // race described below.  Flushing first ensures that if the event is
                    // already present (run goes PENDING inside the transaction) no worker
                    // can claim the run before the current activation’s history is committed.
                    try await flushWrites()

                    // Atomic check-or-wait: prevents the lost-wakeup race where the
                    // event fires between drain() returning and this transaction committing.
                    let taskID = claimed.taskID
                    let runID = claimed.runID
                    let queueName = exec.queue
                    let predicateRaw = RawJSONB(predicate ?? ByteBuffer(string: "{}"))

                    try await exec.postgres.withTransaction(logger: exec.logger) { conn in
                        // Always register the event_wait so emitEvent can find this run later.
                        // namespace_id is required for tenant isolation — never rely on the
                        // column DEFAULT ('default') for non-default namespaces.
                        try await conn.query(
                            """
                            INSERT INTO strand.event_waits
                                (namespace_id, task_id, run_id, queue, seq_num, event_name, timeout_at, predicate)
                            VALUES (\(exec.namespace), \(taskID), \(runID), \(queueName), \(seqNum), \(eventName), \(timeoutAt), \(predicateRaw))
                            ON CONFLICT (run_id, seq_num) DO UPDATE
                                SET event_name = EXCLUDED.event_name,
                                    timeout_at  = EXCLUDED.timeout_at,
                                    predicate   = EXCLUDED.predicate
                            """,
                            logger: exec.logger
                        )
                        // Check if the event was already emitted (race window detection).
                        // SELECT id so we can write an event_triggers row for the fast-path
                        // case, giving the task detail page a "Woken by event" link even when
                        // the event arrived before the waitForEvent was registered.
                        let evtStream = try await conn.query(
                            """
                            SELECT id, payload FROM strand.events
                            WHERE namespace_id = \(exec.namespace)
                              AND queue = \(queueName)
                              AND name  = \(eventName)
                              AND payload @> \(predicateRaw)
                            ORDER BY created_at DESC
                            LIMIT 1
                            """,
                            logger: exec.logger
                        )
                        if let evtRow = try await evtStream.first(where: { _ in true }) {
                            // Event already in strand.events — wake the run immediately.
                            var col = evtRow.makeIterator()
                            let emissionID = try col.next()!.decode(UUID.self, context: .default)
                            let existingPayload = try col.next()!.decode(
                                RawJSONB?.self,
                                context: .default
                            ).map(\.buffer)
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
                                        lease_expires_at = NULL
                                    WHERE id = \(runID)
                                )
                                UPDATE strand.tasks SET state = \(TaskState.pending)
                                WHERE id = \(taskID)
                                """,
                                logger: exec.logger
                            )
                            // Record the event_triggers linkage for the fast-path case so
                            // the dashboard can link the task back to the specific emission.
                            try await conn.query(
                                """
                                INSERT INTO strand.event_triggers
                                    (id, namespace_id, queue, event_name, emission_id, task_id, run_id)
                                VALUES (\(UUID.v7()), \(exec.namespace), \(queueName), \(eventName), \(emissionID), \(taskID), \(runID))
                                ON CONFLICT (emission_id, task_id) WHERE emission_id IS NOT NULL DO NOTHING
                                """,
                                logger: exec.logger
                            )
                            // Notify deferred: flushWrites() ran before this transaction,
                            // so the notify fires after history is already committed.
                            // Use the transactional pg_notify here (fires on commit)
                            // rather than deferring to needsNotifyAfterFlush — the event
                            // details (queue name) are only available inside the closure.
                            try await conn.notifyWorkers(namespace: exec.namespace, queue: queueName, logger: exec.logger)
                        } else {
                            // Event not yet emitted — set run to WAITING (or SLEEPING for timed waits).
                            // If signals are already pending (e.g. a REQUEST_CANCEL arrived while
                            // this activation was running), go PENDING instead so the signal is
                            // delivered promptly rather than waiting for the event or timer.
                            let availableAt =
                                timeoutAt ?? Date(timeIntervalSince1970: 32_503_680_000)
                            let runState: TaskState = timeoutAt != nil ? .sleeping : .waiting
                            let waitStateStream = try await conn.query(
                                """
                                WITH
                                pending_sigs AS (
                                    SELECT COUNT(*) AS cnt FROM strand.workflow_signals
                                    WHERE task_id     = \(taskID)
                                      AND namespace_id = \(exec.namespace)
                                ),
                                r AS (
                                    UPDATE strand.runs
                                    SET state        = CASE WHEN (SELECT cnt FROM pending_sigs) > 0
                                                           THEN \(TaskState.pending)
                                                           ELSE \(runState) END,
                                        available_at  = CASE WHEN (SELECT cnt FROM pending_sigs) > 0
                                                           THEN NOW()
                                                           ELSE \(availableAt) END,
                                        wake_event    = CASE WHEN (SELECT cnt FROM pending_sigs) > 0
                                                           THEN NULL
                                                           ELSE \(eventName) END,
                                        event_payload = NULL,
                                        lease_expires_at = NULL
                                    WHERE id = \(runID)
                                    RETURNING state
                                )
                                UPDATE strand.tasks
                                SET state = (SELECT state FROM r)
                                WHERE id = \(taskID)
                                RETURNING (SELECT state FROM r)
                                """,
                                logger: exec.logger
                            )
                            // If pending_sigs caused the run to go PENDING, notify workers.
                            // The UPDATE targets a single run_id so at most one row is returned.
                            if let waitRow = try await waitStateStream.first(where: { _ in true }) {
                                var col = waitRow.makeIterator()
                                let ws = try col.next()!.decode(TaskState.self, context: .default)
                                if ws == .pending {
                                    try await conn.notifyWorkers(
                                        namespace: exec.namespace,
                                        queue: queueName,
                                        logger: exec.logger
                                    )
                                }
                            }
                        }
                    }
                    let eventWaitData = try! JSON.encode(
                        WorkflowStateQueries.EventWaitStartedData(eventName: eventName, timeoutAt: timeoutAt, seqNum: seqNum)
                    )
                    record(.eventWaitStarted, eventWaitData)

                case .scheduleChildWorkflow(
                    let name,
                    let childQueue,
                    let wfInput,
                    let seqNum,
                    let idKey,
                    let childPriority,
                    let childMaxAttempts,
                    let childFairnessKey,
                    let childFairnessWeight,
                    let childRetryStrategy,
                    let childScheduledAt,
                    let childDeadlineAt,
                    let childParentClosePolicy
                ):
                    let targetQueue = childQueue ?? exec.queue
                    pendingChildren.append(
                        Queries.ChildEnqueueSpec(
                            seqNum: seqNum,
                            taskID: UUID.v7(),
                            runID: UUID.v7(),
                            queue: targetQueue,
                            taskName: name,
                            paramsBuffer: wfInput,
                            headersBuffer: childHeadersBuf,
                            retryStrategyBuffer: childRetryStrategy.flatMap { try? JSON.encode($0) },
                            maxAttempts: childMaxAttempts,
                            idempotencyKey: idKey,
                            priority: childPriority,
                            scheduledAt: childScheduledAt,
                            timeoutSeconds: nil,
                            heartbeatTimeoutSeconds: nil,
                            scheduleToStartTimeoutSeconds: nil,
                            parentClosePolicy: childParentClosePolicy,
                            deadlineAt: childDeadlineAt,
                            fairnessKey: childFairnessKey,
                            fairnessWeight: childFairnessWeight,
                            kind: .workflow,
                            rateLimitIntervalMs: nil,
                            rateLimitKey: nil
                        )
                    )
                    childHistoryItems.append(
                        (
                            eventType: .childWorkflowStarted,
                            eventData: try! JSON.encode(
                                WorkflowStateQueries.ChildWorkflowData(workflow: name, seqNum: seqNum)
                            )
                        )
                    )

                case .writeCheckpoint, .recordVersionMarker, .timerFired, .eventReceived, .eventWaitTimedOut,
                    .conditionMet, .conditionTimedOut, .activityCompleted, .childWorkflowCompleted:
                    break  // processed in step-2 (non-suspending, not enqueued as child tasks)
                }
            }

            // ── 5. Batch-enqueue all children + event_waits + run-state transition ──────────
            // One Postgres transaction for N children using true batch SQL:
            //   • multi-row VALUES INSERT for tasks (one round-trip)
            //   • multi-row VALUES INSERT for runs (one round-trip)
            //   • unnest-based INSERT for event_waits (one round-trip)
            //   • pg_notify per distinct child queue (new tasks only)
            //   • atomic task_completions count → PENDING or WAITING
            if !pendingChildren.isEmpty {
                try await Queries.enqueueChildTasksBatch(
                    on: exec.postgres,
                    namespaceID: exec.namespace,
                    parentTaskID: claimed.taskID,
                    parentRunID: claimed.runID,
                    parentQueue: exec.queue,
                    children: pendingChildren,
                    logger: exec.logger
                )
                // Accumulate child history events — flushed with the activation batch.
                for item in childHistoryItems {
                    record(item.eventType, item.eventData)
                }
            }
        }

        // ── 6–7. State transition + history atomicity invariant ──────────────────────
        // The run MUST stay RUNNING in Postgres until both checkpoints and history
        // are durable.  Steps 6 and 7 therefore merge their state-transition SQL
        // inside the same withTransaction as the checkpoint/history writes, so no
        // other worker can claim the run before the current activation's writes commit.
        // needsNotifyAfterFlush is declared before step 4 so startTimer / awaitEvent
        // can also set it when the pending_sigs guard transitions the run to PENDING.

        // ── 6. Unsatisfied conditions ────────────────────────────────────────────────────
        // Any conditions not satisfied post-drain need a DB state transition so
        // the worker releases this run until a signal or timer wakes it.
        //
        // • condition(_:)          → WAITING (no timer; woken only by a signal)
        // • condition(_:timeout:)  → SLEEPING with available_at = deadline
        //   (woken by timer expiry OR by a signal that transitions SLEEPING → PENDING)
        if executor.hasUnsatisfiedConditions && scheduleCommands.isEmpty {
            let condTaskID = claimed.taskID
            let condRunID = claimed.runID

            // Run the state transition INSIDE the same transaction as checkpoints+history
            // (see the step 6–7 comment above for why this is necessary).
            var conditionState: TaskState = .waiting
            try await exec.postgres.withTransaction(logger: exec.logger) { conn in
                // Write checkpoints + history accumulated so far.
                if !pendingCheckpoints.isEmpty {
                    try await Queries.batchSetCheckpointsOnConn(
                        on: conn,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        runID: claimed.runID,
                        checkpoints: pendingCheckpoints,
                        logger: exec.logger
                    )
                    do {
                        try await Queries.extendClaim(
                            on: conn,
                            namespaceID: exec.namespace,
                            runID: claimed.runID,
                            extendBySeconds: claimTimeoutSecs,
                            logger: exec.logger
                        )
                    } catch InternalError.cancelled {}
                }
                if !pendingHistory.isEmpty {
                    try await WorkflowStateQueries.batchAppendHistory(
                        on: conn,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        events: pendingHistory,
                        logger: exec.logger
                    )
                }
                // Condition state transition — runs AFTER history is written in the same txn.
                //
                // `pending_check` CTE merges two "go PENDING" signals into one read:
                //
                //   cancel_requested  — set by `cancelDescendants` when the parent closes
                //                       with parentClosePolicy = .requestCancel.  Because
                //                       `request_cancel_wake` only wakes SLEEPING/WAITING
                //                       runs, a child whose first activation was still
                //                       RUNNING when the parent was cancelled would park
                //                       in WAITING forever without this check.
                //
                //   workflow_signals   — a @WorkflowSignal arrived while RUNNING; signals
                //                       can't flip a RUNNING run to PENDING directly.
                //
                // `FOR UPDATE` on strand.tasks is the concurrency key:
                //   • In READ COMMITTED, FOR UPDATE reads the LATEST COMMITTED version of
                //     the row, not the statement snapshot.  This closes the window where
                //     `cancelDescendants` commits cancel_requested = TRUE after our
                //     statement snapshot was taken (Sequence B).
                //   • The exclusive lock serialises with `cancelDescendants`:
                //     – If cancelDescendants is in flight: we block, then read TRUE → PENDING.
                //     – If cancelDescendants hasn’t started yet: we take the lock first;
                //       cancelDescendants blocks on it; after we commit (WAITING) it runs
                //       request_cancel_wake and wakes the now-WAITING run (Sequence E).
                let condSQL: PostgresRowSequence
                if let wakeAt = executor.conditionMinWakeAt {
                    condSQL = try await conn.query(
                        """
                        WITH
                        pending_check AS (
                            SELECT (
                                t.cancel_requested
                                OR EXISTS (
                                    SELECT 1 FROM strand.workflow_signals
                                    WHERE task_id = \(condTaskID)
                                      AND namespace_id = \(exec.namespace)
                                )
                            ) AS wake
                            FROM strand.tasks t
                            WHERE t.id = \(condTaskID) AND t.namespace_id = \(exec.namespace)
                            FOR UPDATE
                        ),
                        run_upd AS (
                            UPDATE strand.runs
                            SET state        = CASE WHEN (SELECT wake FROM pending_check)
                                                   THEN \(TaskState.pending)
                                                   ELSE \(TaskState.sleeping) END,
                                available_at = CASE WHEN (SELECT wake FROM pending_check)
                                                   THEN NOW()
                                                   ELSE \(wakeAt) END,
                                lease_expires_at = NULL
                            WHERE id = \(condRunID)
                            RETURNING state
                        )
                        UPDATE strand.tasks
                        SET state = (SELECT state FROM run_upd)
                        WHERE id = \(condTaskID)
                        RETURNING state
                        """,
                        logger: exec.logger
                    )
                } else {
                    condSQL = try await conn.query(
                        """
                        WITH
                        pending_check AS (
                            SELECT (
                                t.cancel_requested
                                OR EXISTS (
                                    SELECT 1 FROM strand.workflow_signals
                                    WHERE task_id = \(condTaskID)
                                      AND namespace_id = \(exec.namespace)
                                )
                            ) AS wake
                            FROM strand.tasks t
                            WHERE t.id = \(condTaskID) AND t.namespace_id = \(exec.namespace)
                            FOR UPDATE
                        ),
                        run_upd AS (
                            UPDATE strand.runs
                            SET state        = CASE WHEN (SELECT wake FROM pending_check)
                                                   THEN \(TaskState.pending)
                                                   ELSE \(TaskState.waiting) END,
                                available_at = CASE WHEN (SELECT wake FROM pending_check)
                                                   THEN NOW()
                                                   ELSE available_at END,
                                lease_expires_at = NULL
                            WHERE id = \(condRunID)
                            RETURNING state
                        )
                        UPDATE strand.tasks
                        SET state = (SELECT state FROM run_upd)
                        WHERE id = \(condTaskID)
                        RETURNING state
                        """,
                        logger: exec.logger
                    )
                }
                for try await row in condSQL {
                    var col = row.makeIterator()
                    conditionState = try col.next()!.decode(TaskState.self, context: .default)
                }
            }
            pendingCheckpoints.removeAll()
            pendingHistory.removeAll()

            if conditionState == .pending { needsNotifyAfterFlush = true }
            // Only record CONDITION_WAITING when the run actually parked.
            if conditionState != .pending { record(.conditionWaiting, nil) }
        }
        // No else branch: if scheduleCommands is empty and no conditions remain,
        // suspension came from sleep/waitForEvent which already wrote its own DB update.

        // ── 7. Partial-completion re-wait ───────────────────────────────────────────────
        // The handler resumed some (but not all) children in a `withThrowingTaskGroup`
        // batch and is parked waiting for the rest. No new schedule commands were emitted.
        // Transition to WAITING so the next child completion can wake this run through the
        // `event_waits` registered during the original dispatch.
        //
        // The atomic CTE also checks for already-completed children (missed wakeups) and
        // goes directly to PENDING in that case.
        //
        // This check is safe on the fresh path: `hasPendingContinuations &&
        // scheduleCommands.isEmpty` cannot both be true there — any parked continuation
        // on the fresh path must have emitted a .scheduleActivity / .awaitEvent command.
        if executor.hasPendingContinuations
            && scheduleCommands.isEmpty
            && !executor.hasUnsatisfiedConditions
        {
            // Steps 7+7B are merged with checkpoints+history into one transaction so
            // the run stays RUNNING in Postgres until all writes are durable.
            // In Postgres READ COMMITTED, each statement in a transaction gets a fresh
            // snapshot, so step 7B below can see concurrent task_completions commits that
            // step 7 missed — same correctness guarantee as the old two-statement approach.
            try await exec.postgres.withTransaction(logger: exec.logger) { conn in
                // ── flushWrites content ───────────────────────────────────────────────
                if !pendingCheckpoints.isEmpty {
                    try await Queries.batchSetCheckpointsOnConn(
                        on: conn,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        runID: claimed.runID,
                        checkpoints: pendingCheckpoints,
                        logger: exec.logger
                    )
                    do {
                        try await Queries.extendClaim(
                            on: conn,
                            namespaceID: exec.namespace,
                            runID: claimed.runID,
                            extendBySeconds: claimTimeoutSecs,
                            logger: exec.logger
                        )
                    } catch InternalError.cancelled {}
                }
                if !pendingHistory.isEmpty {
                    try await WorkflowStateQueries.batchAppendHistory(
                        on: conn,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        events: pendingHistory,
                        logger: exec.logger
                    )
                }
                // ── Step 7: partial-completion re-wait ────────────────────────────────
                try await conn.query(
                    """
                    WITH
                    missed AS (
                        SELECT ew.child_task_id
                        FROM strand.event_waits ew
                        JOIN strand.task_completions tc ON tc.task_id = ew.child_task_id
                        WHERE ew.run_id        = \(claimed.runID)
                          AND ew.child_task_id IS NOT NULL
                    ),
                    del_orphans AS (
                        DELETE FROM strand.event_waits ew
                        USING missed m
                        WHERE ew.run_id        = \(claimed.runID)
                          AND ew.child_task_id = m.child_task_id
                    ),
                    run_upd AS (
                        UPDATE strand.runs
                        SET state            = CASE WHEN (SELECT COUNT(*) FROM missed) > 0 OR has_buffered_completion
                                                   THEN \(TaskState.pending)
                                                   ELSE \(TaskState.waiting) END,
                            available_at     = CASE WHEN (SELECT COUNT(*) FROM missed) > 0 OR has_buffered_completion
                                                   THEN NOW()
                                                   ELSE available_at END,
                            has_buffered_completion = FALSE,
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
                // ── Step 7B: snapshot-isolation recovery ────────────────────────────
                // Each statement in a READ COMMITTED transaction gets a fresh snapshot,
                // so this sees task_completions rows committed concurrently with step 7.
                let recoveryStream = try await conn.query(
                    """
                    WITH
                    missed AS (
                        SELECT ew.child_task_id
                        FROM strand.event_waits ew
                        JOIN strand.task_completions tc ON tc.task_id = ew.child_task_id
                        WHERE ew.run_id        = \(claimed.runID)
                          AND ew.child_task_id IS NOT NULL
                    ),
                    del_orphans AS (
                        DELETE FROM strand.event_waits ew
                        USING missed m
                        WHERE ew.run_id        = \(claimed.runID)
                          AND ew.child_task_id = m.child_task_id
                    ),
                    run_upd AS (
                        UPDATE strand.runs
                        SET state        = \(TaskState.pending),
                            available_at = NOW(),
                            lease_expires_at = NULL
                        WHERE id    = \(claimed.runID)
                          AND state = \(TaskState.waiting)
                          AND (SELECT COUNT(*) FROM missed) > 0
                        RETURNING id
                    )
                    UPDATE strand.tasks
                    SET state = \(TaskState.pending)
                    FROM run_upd
                    WHERE strand.tasks.id           = \(claimed.taskID)
                      AND strand.tasks.namespace_id = \(exec.namespace)
                    RETURNING strand.tasks.id
                    """,
                    logger: exec.logger
                )
                if try await recoveryStream.first(where: { _ in true }) != nil {
                    exec.logger.debug(
                        "partial-completion recovery: snapshot-isolation race detected — run set to PENDING",
                        metadata: [
                            "strand.task_id": .stringConvertible(claimed.taskID),
                            "strand.run_id": .stringConvertible(claimed.runID),
                        ]
                    )
                }
            }
            pendingCheckpoints.removeAll()
            pendingHistory.removeAll()
            needsNotifyAfterFlush = true  // speculative: fires even if run went WAITING
        }

        // ── 8. Cache the live Task for the next activation ───────────────────────────
        // ── 8. Flush writes, then cache, then notify ─────────────────────────────────────────
        // ORDER MATTERS:
        //   1. flushWrites() commits checkpoints + history atomically.
        //   2. cache.set() stores the live handler Task.
        //   3. notifyWorkers() fires LAST — only after history is durable.
        //
        // Sending pg_notify before flushWrites would let another worker claim
        // the PENDING run, read the same nextHistorySeq(), and commit first.
        // This activation's batchAppendHistory would then hit ON CONFLICT DO NOTHING,
        // silently dropping history while the checkpoint UPSERT still succeeded —
        // producing the checkpoint-without-history inconsistency.
        try await flushWrites()
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

        // Fire deferred notifications now that history is committed.
        // This is the last operation — another worker can safely claim
        // the run and call nextHistorySeq() without racing this activation.
        if needsNotifyAfterFlush {
            try await exec.postgres.notifyWorkers(
                namespace: exec.namespace,
                queue: exec.queue,
                logger: exec.logger
            )
        }

        return nil
    }

    /// Tears down the cached handler Task when a workflow reaches a terminal result
    /// (completed, failed, or continuing-as-new).
    ///
    /// Order matters: remove from cache first so no other activation can race with
    /// the `cancelPending` + `drain` that follows.
    private func teardownHandler(
        cache: _WorkflowTaskCache<W>,
        taskID: UUID,
        handlerTask: Task<Void, Never>,
        executor: StrandWorkflowExecutor
    ) {
        cache.remove(taskID)
        handlerTask.cancel()
        executor.cancelPending()
        executor.drain()
    }
}
