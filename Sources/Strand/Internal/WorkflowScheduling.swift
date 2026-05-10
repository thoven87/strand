import NIOCore
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
        // Non-suspending writes first — durable regardless of what follows.
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

        // ── 2. Replay fast-path history events (TIMER_FIRED, EVENT_RECEIVED) ─────────
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

        // ── 3. Terminal result handling ──────────────────────────────────────────────
        switch handlerResult.value {

        case .success(let output):
            // Handler completed — persist final state and return the encoded result.
            // The caller (runTask) writes COMPLETED to the run.
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

        // ── 4. Suspended: apply schedule commands ────────────────────────────────
        let scheduleCommands = commands.filter { cmd in
            switch cmd {
            case .scheduleActivity, .startTimer, .awaitEvent, .scheduleChildWorkflow:
                return true
            case .writeCheckpoint, .timerFired, .eventReceived:
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

            // Enqueue activities / child workflows (idempotent — safe if row exists).
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
                        headersBuffer: childHeadersBuf,
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
                            // Run is PENDING — notify workers to claim immediately.
                            let notification = StrandChannels.Notification(namespace: exec.namespace, queue: queueName)
                            try await conn.query(
                                "SELECT pg_notify(\(StrandChannels.tasks), \(notification.payload))",
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
                        headersBuffer: childHeadersBuf,
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

            // ── 5. Register event_waits + atomic completion check ──────────────────────
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

                    // Go PENDING if ANY child has already completed, not just ALL.
                    // The `for try await r in group` loop delivers results one at a time,
                    // so even a single completion requires a re-activation to make progress.
                    //
                    // The del_orphans CTE deletes event_waits for the completed children
                    // in the same atomic operation.  Without this, the partial-completion
                    // re-wait in step 7 would find them on every subsequent activation and
                    // repeatedly go PENDING for no-op deliveries (spin loop).
                    if completedCount > 0 {
                        try await conn.query(
                            """
                            WITH
                            del_orphans AS (
                                DELETE FROM strand.event_waits ew
                                USING strand.task_completions tc
                                WHERE ew.run_id        = \(claimed.runID)
                                  AND ew.child_task_id = tc.task_id
                                  AND tc.task_id       = ANY(\(childTaskIDs))
                            ),
                            r AS (
                                UPDATE strand.runs
                                SET state        = \(TaskState.pending),
                                    available_at = NOW(),
                                    worker_id    = NULL,
                                    lease_expires_at = NULL
                                WHERE id = \(claimed.runID)
                                RETURNING id
                            )
                            UPDATE strand.tasks SET state = \(TaskState.pending)
                            WHERE id = \(claimed.taskID)
                            """,
                            logger: exec.logger
                        )
                        let notification = StrandChannels.Notification(namespace: exec.namespace, queue: exec.queue)
                        try await conn.query(
                            "SELECT pg_notify(\(StrandChannels.tasks), \(notification.payload))",
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
            try await exec.postgres.query(
                """
                WITH
                missed AS (
                    -- event_waits whose children have already completed but whose
                    -- wake signal was silently dropped (parent was RUNNING at the time).
                    -- child_task_id is a typed UUID FK — direct join, no string parsing.
                    SELECT ew.child_task_id
                    FROM strand.event_waits ew
                    JOIN strand.task_completions tc ON tc.task_id = ew.child_task_id
                    WHERE ew.run_id        = \(claimed.runID)
                      AND ew.child_task_id IS NOT NULL
                ),
                del_orphans AS (
                    -- Delete the orphaned event_waits immediately so they do not
                    -- re-trigger a PENDING transition on the NEXT re-activation
                    -- (which would cause a spin loop: re-activate → no progress →
                    -- PENDING again, ad infinitum, until the remaining children finish).
                    DELETE FROM strand.event_waits ew
                    USING missed m
                    WHERE ew.run_id        = \(claimed.runID)
                      AND ew.child_task_id = m.child_task_id
                ),
                run_upd AS (
                    UPDATE strand.runs
                    SET state            = CASE WHEN (SELECT COUNT(*) FROM missed) > 0
                                               THEN \(TaskState.pending)
                                               ELSE \(TaskState.waiting) END,
                        available_at     = CASE WHEN (SELECT COUNT(*) FROM missed) > 0
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
            // Notify speculatively: if the run went PENDING (missed > 0) workers should
            // claim it immediately. If it went WAITING the notification is a spurious
            // wakeup that costs at most one empty poll — acceptable.
            let notification = StrandChannels.Notification(namespace: exec.namespace, queue: exec.queue)
            try await exec.postgres.query(
                "SELECT pg_notify(\(StrandChannels.tasks), \(notification.payload))",
                logger: exec.logger
            )

            // ── 7B. Post-wait snapshot-isolation recovery ───────────────────────────────
            // Step 7's CTE runs under Postgres snapshot isolation: it cannot see
            // task_completions rows that committed AFTER step 7's snapshot started.
            // In the exact race window where a sibling worker commits a child
            // completion concurrently with step 7, the run goes WAITING with no
            // further signal to ever wake it — stuck forever.
            //
            // This follow-up query executes as a NEW statement (READ COMMITTED —
            // fresh snapshot) and therefore sees all concurrent commits that step 7
            // missed.  If any remaining event_wait children have now completed,
            // flip WAITING → PENDING and notify.
            //
            // del_orphans here serves the same spin-loop prevention role as in step 7.
            let recoveryStream = try await exec.postgres.query(
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
                        worker_id    = NULL,
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
                let recoveryNote = StrandChannels.Notification(namespace: exec.namespace, queue: exec.queue)
                try await exec.postgres.query(
                    "SELECT pg_notify(\(StrandChannels.tasks), \(recoveryNote.payload))",
                    logger: exec.logger
                )
            }
        }

        // ── 8. Cache the live Task for the next activation ───────────────────────────
        // The handler is parked on a continuation — do NOT call cancelPending().
        // On the next activation, resumeActivation() delivers real results directly
        // to those continuations and calls drain() to continue from where it paused.
        //
        // For the cached path: cache.set is idempotent — it simply refreshes the
        // same references already stored from the previous activation.
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
}
