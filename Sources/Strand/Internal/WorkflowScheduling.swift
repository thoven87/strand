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

        // Local helper — captures the five fixed appendHistory parameters so each
        // call site only specifies the two that vary (eventType, eventData).
        // A nested `func` (not a stored closure) is used because it can capture
        // the `inout historySeq` parameter directly.
        func record(_ type: WorkflowStateQueries.HistoryEventType, _ data: ByteBuffer?) async throws {
            try await WorkflowStateQueries.appendHistory(
                on: exec.postgres,
                namespaceID: exec.namespace,
                taskID: claimed.taskID,
                seq: historySeq,
                eventType: type,
                eventData: data,
                logger: exec.logger
            )
            historySeq += 1
        }

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
                try await record(.timerFired, nil)
            case .eventReceived(let eventName):
                try await record(.eventReceived, try? JSON.encode(WorkflowStateQueries.NamedEventData(eventName: eventName)))
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
            try await record(.workflowCompleted, nil)
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
                teardownHandler(cache: cache, taskID: claimed.taskID, handlerTask: handlerTask, executor: executor)
                throw signal
            }
            teardownHandler(cache: cache, taskID: claimed.taskID, handlerTask: handlerTask, executor: executor)
            let errData = try? JSON.encode(WorkflowStateQueries.WorkflowFailedData(error: String(describing: error)))
            try await record(.workflowFailed, errData)
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
                            deadlineAt: options.maxDuration.map {
                                Date.now.addingTimeInterval(
                                    Double($0.components.seconds)
                                        + Double($0.components.attoseconds)
                                        / 1_000_000_000_000_000_000
                                )
                            },
                            fairnessKey: options.fairnessKey,
                            fairnessWeight: options.fairnessWeight,
                            kind: .activity
                        )
                    )
                    childHistoryItems.append(
                        (
                            eventType: .activityScheduled,
                            eventData: try? JSON.encode(
                                WorkflowStateQueries.ActivityScheduledData(activity: name, seqNum: seqNum)
                            )
                        )
                    )

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
                    let timerData = try? JSON.encode(
                        WorkflowStateQueries.TimerStartedData(durationMs: Int(wakeAt.timeIntervalSinceNow * 1000))
                    )
                    try await record(.timerStarted, timerData)

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
                            try await conn.notifyWorkers(namespace: exec.namespace, queue: queueName, logger: exec.logger)
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
                    let eventWaitData = try? JSON.encode(WorkflowStateQueries.NamedEventData(eventName: eventName))
                    try await record(.eventWaitStarted, eventWaitData)

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
                    let childScheduledAt
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
                            deadlineAt: nil,
                            fairnessKey: childFairnessKey,
                            fairnessWeight: childFairnessWeight,
                            kind: .workflow
                        )
                    )
                    childHistoryItems.append(
                        (
                            eventType: .childWorkflowStarted,
                            eventData: try? JSON.encode(
                                WorkflowStateQueries.ChildWorkflowData(workflow: name, seqNum: seqNum)
                            )
                        )
                    )

                case .writeCheckpoint, .timerFired, .eventReceived:
                    break  // already handled above
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
                // Append workflow history for all children (preserves submission order).
                for historyItem in childHistoryItems {
                    try await WorkflowStateQueries.appendHistory(
                        on: exec.postgres,
                        namespaceID: exec.namespace,
                        taskID: claimed.taskID,
                        seq: historySeq,
                        eventType: historyItem.eventType,
                        eventData: historyItem.eventData,
                        logger: exec.logger
                    )
                    historySeq += 1
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
            try await exec.postgres.notifyWorkers(namespace: exec.namespace, queue: exec.queue, logger: exec.logger)

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
                try await exec.postgres.notifyWorkers(namespace: exec.namespace, queue: exec.queue, logger: exec.logger)
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
