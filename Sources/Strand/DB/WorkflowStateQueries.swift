package import Logging
package import NIOCore
package import PostgresNIO

#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

// MARK: - PendingSignal

/// A decoded signal row returned by ``WorkflowStateQueries/loadPendingSignals``.
package struct PendingSignal: Sendable {
    /// Primary key of the `strand.workflow_signals` row.
    let id: UUID
    /// The signal or update name. For updates this is the clean handler name
    /// (e.g. `"setPriority"`); for signals it is the signal name (e.g. `"pause"`).
    let name: String
    /// Caller-supplied payload bytes, or `nil` when the signal carries no data.
    let payload: ByteBuffer?
    /// Non-nil when this row is an `@WorkflowUpdate` request.
    /// Nil for regular `@WorkflowSignal` deliveries.
    let updateCorrelationID: String?
}

// MARK: - WorkflowStateQueries

/// DB queries that manage per-workflow state persistence and the signal inbox.
///
/// All functions are `package` — callers are the worker's execution engine and
/// `StrandClient`/`WorkflowHandle`. Nothing in this file is public API.
package enum WorkflowStateQueries {

    // MARK: - loadState

    /// Load the serialised workflow state for the given task.
    ///
    /// Returns `nil` when no state has been persisted yet, i.e. this is the
    /// workflow's **first activation**. The caller is responsible for
    /// constructing a default instance in that case.
    package static func loadState(
        on postgres: PostgresClient,
        taskID: UUID,
        namespaceID: String,
        logger: Logger
    ) async throws -> ByteBuffer? {
        let stream = try await postgres.query(
            """
            SELECT state
            FROM   strand.workflow_state
            WHERE  task_id      = \(taskID)
              AND  namespace_id = \(namespaceID)
            """,
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else {
            return nil
        }
        var col = row.makeIterator()
        // state is BYTEA NOT NULL, but we return ByteBuffer so callers get a
        // meaningful value rather than forcing an unwrap at call sites.
        return try col.next()!.decode(ByteBuffer.self, context: .default)
    }

    // MARK: - saveState

    /// Persist (upsert) the serialised workflow state.
    ///
    /// On conflict `state_seq` is incremented atomically so callers can detect
    /// stale writes (e.g. if two activations somehow race — which the lease
    /// mechanism prevents, but this is a defence-in-depth measure).
    package static func saveState(
        on postgres: PostgresClient,
        taskID: UUID,
        namespaceID: String,
        stateBuffer: ByteBuffer,
        logger: Logger
    ) async throws {
        try await postgres.query(
            """
            INSERT INTO strand.workflow_state
                        (namespace_id, task_id, state, state_seq, updated_at)
            VALUES      (\(namespaceID), \(taskID), \(stateBuffer), 0, NOW())
            ON CONFLICT (task_id) DO UPDATE
                SET state     = EXCLUDED.state,
                    state_seq = strand.workflow_state.state_seq + 1,
                    updated_at = NOW()
            """,
            logger: logger
        )
    }

    // MARK: - loadPendingSignals

    /// Returns all pending signals for the workflow in causal order (oldest first).
    ///
    /// Ordered by `seq` — a `BIGSERIAL` allocated at INSERT time — rather than
    /// `created_at`, which is non-deterministic for signals sent within the same
    /// millisecond from different processes.
    ///
    /// The caller is expected to:
    /// 1. Apply each signal to the workflow struct.
    /// 2. Call ``deleteSignals(on:ids:logger:)`` with the returned IDs to
    ///    acknowledge delivery.
    ///
    /// Signals are never deleted here — that separation lets the caller apply
    /// them atomically inside the same activation before acking.
    package static func loadPendingSignals(
        on postgres: PostgresClient,
        taskID: UUID,
        namespaceID: String,
        logger: Logger
    ) async throws -> [PendingSignal] {
        let stream = try await postgres.query(
            """
            SELECT id, signal_name, payload, update_correlation_id
            FROM   strand.workflow_signals
            WHERE  task_id      = \(taskID)
              AND  namespace_id = \(namespaceID)
            ORDER  BY seq ASC
            """,
            logger: logger
        )
        var signals: [PendingSignal] = []
        for try await row in stream {
            var col = row.makeIterator()
            signals.append(
                PendingSignal(
                    id: try col.next()!.decode(UUID.self, context: .default),
                    name: try col.next()!.decode(String.self, context: .default),
                    payload: try col.next()!.decode(ByteBuffer?.self, context: .default),
                    updateCorrelationID: try col.next()!.decode(String?.self, context: .default)
                )
            )
        }
        return signals
    }

    // MARK: - deleteSignals

    /// Delete the given signal rows (by ID) after they have been applied to
    /// workflow state.
    ///
    /// Safe to call with an empty `ids` slice — returns immediately without
    /// hitting the database.
    package static func deleteSignals(
        on postgres: PostgresClient,
        ids: [UUID],
        logger: Logger
    ) async throws {
        guard !ids.isEmpty else { return }
        try await postgres.query(
            "DELETE FROM strand.workflow_signals WHERE id = ANY(\(ids))",
            logger: logger
        )
    }

    // MARK: - writeUpdateResult / findUpdateResult

    /// Writes a workflow update result (or error) to `strand.workflow_updates`.
    ///
    /// Called by the worker after `handleUpdate` returns. ON CONFLICT DO NOTHING
    /// ensures idempotency on re-activation.
    package static func writeUpdateResult(
        on postgres: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        correlationID: String,
        result: ByteBuffer?,
        error: String?,
        logger: Logger
    ) async throws {
        try await postgres.query(
            """
            INSERT INTO strand.workflow_updates
                (namespace_id, task_id, correlation_id, result, error)
            VALUES (\(namespaceID), \(taskID), \(correlationID), \(result), \(error))
            ON CONFLICT (namespace_id, correlation_id) DO NOTHING
            """,
            logger: logger
        )
    }

    /// Polls `strand.workflow_updates` for a result row matching `correlationID`.
    /// Returns `nil` when no row exists yet (caller should retry).
    package static func findUpdateResult(
        on postgres: PostgresClient,
        namespaceID: String,
        correlationID: String,
        logger: Logger
    ) async throws -> (result: ByteBuffer?, error: String?)? {
        let stream = try await postgres.query(
            """
            SELECT result, error
            FROM   strand.workflow_updates
            WHERE  namespace_id   = \(namespaceID)
              AND  correlation_id = \(correlationID)
            """,
            logger: logger
        )
        for try await row in stream {
            var col = row.makeIterator()
            let result = try col.next()!.decode(ByteBuffer?.self, context: .default)
            let error = try col.next()!.decode(String?.self, context: .default)
            return (result: result, error: error)
        }
        return nil
    }

    // MARK: - insertSignal

    /// Insert a signal into the inbox for a workflow task.
    ///
    /// Called by `StrandClient.signal(...)` / `WorkflowHandle.signal(...)`.
    package static func insertSignal(
        on postgres: PostgresClient,
        taskID: UUID,
        namespaceID: String,
        signalName: String,
        payloadBuffer: ByteBuffer?,
        logger: Logger
    ) async throws {
        try await postgres.query(
            """
            INSERT INTO strand.workflow_signals
                        (namespace_id, task_id, signal_name, payload)
            VALUES      (\(namespaceID), \(taskID), \(signalName), \(payloadBuffer))
            """,
            logger: logger
        )
    }

    // MARK: - loadCompletedChildActivities

    /// Returns terminal child tasks (COMPLETED, FAILED, or CANCELLED) spawned by `parentTaskID`.
    ///
    /// Used by `WorkflowRegistration.activate()` to pre-populate the executor's
    /// result cache before running the handler. Both successful and failed results
    /// are included so that `runActivity`/`runChildWorkflow` can return or throw on
    /// the fast path — avoiding the slow path that registers an event_wait after the
    /// signal already fired.
    ///
    /// The idempotency_key format is `"\(parentTaskID):\(seqNum)"` where seqNum is a
    /// decimal integer string. The prefix is stripped and parsed to recover the integer
    /// key used by the executor's `preloadedResults` / `preloadedNonCompletions` maps.
    package static func loadCompletedChildActivities(
        on postgres: PostgresClient,
        parentTaskID: UUID,
        logger: Logger
    ) async throws -> [(
        seqNum: Int, result: ByteBuffer?, failureReason: ByteBuffer?,
        state: TaskState, kind: TaskKind, name: String,
        startedAt: Date?, runAttempt: Int, workerID: String?
    )] {
        let prefix = "\(parentTaskID):"
        let prefixPattern = prefix + "%"
        let stream = try await postgres.query(
            """
            SELECT t.idempotency_key, tc.result, tc.state,
                   r.failure_reason, t.kind, t.name,
                   r.started_at, r.attempt, r.worker_id
            FROM strand.task_completions tc
            JOIN strand.tasks t ON t.id = tc.task_id
            LEFT JOIN LATERAL (
                SELECT failure_reason, started_at, attempt, worker_id
                FROM strand.runs
                WHERE task_id = t.id
                ORDER BY attempt DESC LIMIT 1
            ) r ON true
            WHERE t.parent_task_id = \(parentTaskID)
              AND tc.state IN ('COMPLETED', 'FAILED', 'CANCELLED')
              AND t.idempotency_key LIKE \(prefixPattern)
            ORDER BY tc.completed_at ASC
            """,
            logger: logger
        )
        var completions:
            [(
                seqNum: Int, result: ByteBuffer?, failureReason: ByteBuffer?,
                state: TaskState, kind: TaskKind, name: String,
                startedAt: Date?, runAttempt: Int, workerID: String?
            )] = []
        for try await row in stream {
            var col = row.makeIterator()
            let idempotencyKey = try col.next()!.decode(String.self, context: .default)
            let result = try col.next()!.decode(ByteBuffer?.self, context: .default)
            let stateRaw = try col.next()!.decode(String.self, context: .default)
            let failureReason = try col.next()!.decode(ByteBuffer?.self, context: .default)
            let kindRaw = try col.next()!.decode(String.self, context: .default)
            let taskName = try col.next()!.decode(String.self, context: .default)
            let startedAt = try col.next()!.decode(Date?.self, context: .default)
            let runAttemptOpt = try col.next()!.decode(Int?.self, context: .default)
            let workerID = try col.next()!.decode(String?.self, context: .default)
            guard idempotencyKey.hasPrefix(prefix),
                let seqNum = Int(String(idempotencyKey.dropFirst(prefix.count))),
                let state = TaskState(rawValue: stateRaw),
                let kind = TaskKind(rawValue: kindRaw)
            else { continue }
            completions.append(
                (
                    seqNum: seqNum, result: result, failureReason: failureReason,
                    state: state, kind: kind, name: taskName,
                    startedAt: startedAt, runAttempt: runAttemptOpt ?? 1, workerID: workerID
                )
            )
        }
        return completions
    }

    // MARK: - nextHistorySeq

    /// Returns the next available sequence number for this workflow's history.
    /// Call once at activation start; increment the returned value for each event.
    package static func nextHistorySeq(
        on postgres: PostgresClient,
        taskID: UUID,
        logger: Logger
    ) async throws -> Int {
        let stream = try await postgres.query(
            "SELECT COALESCE(MAX(seq), 0) FROM strand.workflow_history WHERE task_id = \(taskID)",
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else { return 1 }
        var col = row.makeIterator()
        let max = try col.next()!.decode(Int.self, context: .default)
        return max + 1
    }

    // MARK: - appendHistory

    /// All event types that can be appended to `strand.workflow_history`.
    ///
    /// Using an enum instead of a bare `String` means misspellings are caught at
    /// compile time, the exhaustive list is documented in one place, and the
    /// dashboard's history view can switch on known values without stringly-typed guards.
    package enum HistoryEventType: String, Sendable {
        case workflowStarted = "WORKFLOW_STARTED"
        case workflowCompleted = "WORKFLOW_COMPLETED"
        case workflowFailed = "WORKFLOW_FAILED"
        case signalReceived = "SIGNAL_RECEIVED"
        case updateApplied = "UPDATE_APPLIED"
        case activityScheduled = "ACTIVITY_SCHEDULED"
        case activityCompleted = "ACTIVITY_COMPLETED"
        case activityFailed = "ACTIVITY_FAILED"
        case activityStarted = "ACTIVITY_STARTED"
        case timerStarted = "TIMER_STARTED"
        case timerFired = "TIMER_FIRED"
        case conditionWaiting = "CONDITION_WAITING"
        case eventWaitStarted = "EVENT_WAIT_STARTED"
        case eventReceived = "EVENT_RECEIVED"
        case eventWaitTimedOut = "EVENT_WAIT_TIMED_OUT"
        case conditionMet = "CONDITION_MET"
        case conditionTimedOut = "CONDITION_TIMED_OUT"
        case childWorkflowStarted = "CHILD_WORKFLOW_STARTED"
        case childWorkflowCompleted = "CHILD_WORKFLOW_COMPLETED"
        case eventEmitted = "EVENT_EMITTED"  // ctx.emitEvent(...)
    }

    // MARK: - History event data payloads

    /// Payload for `ACTIVITY_SCHEDULED`.
    ///
    /// JSON shape: `{"activity":"MyActivity","seq_num":"5"}`.
    /// `seq_num` is written as a string to match the existing wire format that the
    /// Loom dashboard reads (it accepts both `string` and `number` but the current
    /// writer always emits a string).
    package struct ActivityScheduledData: Encodable {
        package let activity: String
        package let seqNum: Int

        private enum CodingKeys: String, CodingKey {
            case activity
            case seqNum = "seq_num"
        }

        package func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(activity, forKey: .activity)
            try c.encode(String(seqNum), forKey: .seqNum)
        }
    }

    /// Payload for `ACTIVITY_STARTED`.
    ///
    /// JSON shape: `{"activity":"ChargeCardActivity","seq_num":4,"attempt":2,"worker_id":"host:1234"}`.
    /// `seq_num` correlates with the matching `ACTIVITY_SCHEDULED` event.
    package struct ActivityStartedData: Encodable {
        package let activity: String
        /// `nil` when the event_wait was already deleted (activity cancelled before starting).
        package let seqNum: Int?
        package let attempt: Int
        package let workerID: String
        package let startedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case activity
            case seqNum = "seq_num"
            case attempt
            case workerID = "worker_id"
            case startedAt = "started_at"
        }
    }

    /// Payload for `CHILD_WORKFLOW_STARTED` and `CHILD_WORKFLOW_COMPLETED`.
    ///
    /// JSON shape: `{"workflow":"OrderWorkflow","seq_num":"3"}`.
    package struct ChildWorkflowData: Encodable {
        package let workflow: String
        package let seqNum: Int

        private enum CodingKeys: String, CodingKey {
            case workflow
            case seqNum = "seq_num"
        }

        package func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(workflow, forKey: .workflow)
            try c.encode(String(seqNum), forKey: .seqNum)
        }
    }

    /// Payload for `EVENT_WAIT_STARTED`.
    ///
    /// Written when `context.waitForEvent(_:)` registers a new wait. Contains the
    /// activation step counter so `deriveHistorySpans` can pair this event with the
    /// matching `EVENT_RECEIVED` or `EVENT_WAIT_TIMED_OUT` when concurrent event
    /// waits exist (e.g. two `waitForEvent` calls inside a `withThrowingTaskGroup`).
    package struct EventWaitStartedData: Codable {
        package let eventName: String
        package let timeoutAt: Date?
        /// Activation step counter — always present.
        package let seqNum: Int

        private enum CodingKeys: String, CodingKey {
            case eventName = "event_name"
            case timeoutAt = "timeout_at"
            case seqNum = "seq_num"
        }
    }

    /// Payload for `EVENT_RECEIVED`, `EVENT_WAIT_TIMED_OUT`, and `EVENT_EMITTED`.
    package struct NamedEventData: Codable {
        package let eventName: String

        private enum CodingKeys: String, CodingKey {
            case eventName = "event_name"
        }
    }

    /// Payload for `TIMER_STARTED`.
    ///
    /// JSON shape: `{"duration_ms":5000,"seq_num":3}`. The `seq_num` is the activation
    /// step counter; it pairs with the matching `TIMER_FIRED` row so `deriveHistorySpans`
    /// can reconstruct SLEEP spans when concurrent timers are active.
    package struct TimerStartedData: Codable {
        package let durationMs: Int
        /// Activation step counter — always present.
        package let seqNum: Int

        private enum CodingKeys: String, CodingKey {
            case durationMs = "duration_ms"
            case seqNum = "seq_num"
        }
    }

    /// Payload for `TIMER_FIRED`.
    ///
    /// JSON shape: `{"seq_num":3}`. Matches `TimerStartedData.seqNum` to close the
    /// corresponding SLEEP span in `deriveHistorySpans`.
    package struct TimerFiredData: Codable {
        /// Activation step counter matching `TimerStartedData.seqNum`.
        package let seqNum: Int

        private enum CodingKeys: String, CodingKey {
            case seqNum = "seq_num"
        }
    }

    /// Payload for `SIGNAL_RECEIVED`.
    ///
    /// JSON shape: `{"name":"pause"}`.
    package struct SignalReceivedData: Codable {
        package let name: String
    }

    /// Payload for `WORKFLOW_FAILED`.
    ///
    /// JSON shape: `{"error":"..."}`.
    package struct WorkflowFailedData: Encodable {
        package let error: String
    }

    /// Appends a single event to this workflow's history log.
    /// Connection overload — SQL lives here.
    package static func appendHistory(
        on conn: PostgresConnection,
        namespaceID: String,
        taskID: UUID,
        seq: Int,
        eventType: HistoryEventType,
        eventData: ByteBuffer?,
        logger: Logger
    ) async throws {
        let rawType = eventType.rawValue
        try await conn.query(
            """
            INSERT INTO strand.workflow_history (namespace_id, task_id, seq, event_type, event_data)
            VALUES (\(namespaceID), \(taskID), \(seq), \(rawType), \(eventData))
            ON CONFLICT (task_id, seq) DO NOTHING
            """,
            logger: logger
        )
    }

    /// Client overload — one-liner that delegates.
    package static func appendHistory(
        on postgres: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        seq: Int,
        eventType: HistoryEventType,
        eventData: ByteBuffer?,
        logger: Logger
    ) async throws {
        try await postgres.withConnection { conn in
            try await appendHistory(
                on: conn,
                namespaceID: namespaceID,
                taskID: taskID,
                seq: seq,
                eventType: eventType,
                eventData: eventData,
                logger: logger
            )
        }
    }

    // MARK: - listHistory

    /// A single decoded row from `strand.workflow_history`.
    /// Unknown `event_type` values (e.g. from future schema additions) are
    /// silently skipped during decoding — see `listHistory`.
    package struct HistoryEventRow: Sendable {
        package let seq: Int
        package let eventType: HistoryEventType
        package let eventData: ByteBuffer?
        package let createdAt: Date
    }

    /// Returns all history events for the given workflow task in ascending sequence order.
    package static func listHistory(
        on postgres: PostgresClient,
        taskID: UUID,
        logger: Logger
    ) async throws -> [HistoryEventRow] {
        let stream = try await postgres.query(
            """
            SELECT seq, event_type, event_data, created_at
            FROM   strand.workflow_history
            WHERE  task_id = \(taskID)
            ORDER  BY seq ASC
            """,
            logger: logger
        )
        var events: [HistoryEventRow] = []
        for try await row in stream {
            var col = row.makeIterator()
            let seq = try col.next()!.decode(Int.self, context: .default)
            let rawType = try col.next()!.decode(String.self, context: .default)
            let eventData = try col.next()!.decode(ByteBuffer?.self, context: .default)
            let createdAt = try col.next()!.decode(Date.self, context: .default)
            // Skip rows whose event_type is not in the enum (future schema additions, etc.)
            guard let eventType = HistoryEventType(rawValue: rawType) else { continue }
            events.append(
                HistoryEventRow(
                    seq: seq,
                    eventType: eventType,
                    eventData: eventData,
                    createdAt: createdAt
                )
            )
        }
        return events
    }

    // MARK: - batchAppendHistory

    /// Appends multiple history events in a single round-trip.
    ///
    /// When there is only one event the call delegates to ``appendHistory`` to avoid
    /// the overhead of opening a transaction. For two or more events a transaction is
    /// used so all inserts are atomic and the DB round-trips are minimised.
    ///
    /// `ON CONFLICT (task_id, seq) DO NOTHING` makes every insert idempotent, which
    /// is safe because a replayed activation will attempt to write the same seq values.
    package static func batchAppendHistory(
        on postgres: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        events: [(seq: Int, eventType: HistoryEventType, eventData: ByteBuffer?)],
        logger: Logger
    ) async throws {
        guard !events.isEmpty else { return }
        if events.count == 1 {
            let e = events[0]
            try await appendHistory(
                on: postgres,
                namespaceID: namespaceID,
                taskID: taskID,
                seq: e.seq,
                eventType: e.eventType,
                eventData: e.eventData,
                logger: logger
            )
            return
        }
        // Multi-row VALUES INSERT — one round-trip regardless of N events.
        var interp = PostgresQuery.StringInterpolation(
            literalCapacity: 140 + events.count * 80,
            interpolationCount: events.count * 5 + 2
        )
        interp.appendLiteral(
            "INSERT INTO strand.workflow_history "
                + "(namespace_id, task_id, seq, event_type, event_data) VALUES "
        )
        for (i, e) in events.enumerated() {
            if i > 0 { interp.appendLiteral(", ") }
            interp.appendLiteral("(")
            interp.appendInterpolation(namespaceID)
            interp.appendLiteral(", ")
            interp.appendInterpolation(taskID)
            interp.appendLiteral(", ")
            interp.appendInterpolation(e.seq)
            interp.appendLiteral(", ")
            try interp.appendInterpolation(e.eventType)
            interp.appendLiteral(", ")
            interp.appendInterpolation(e.eventData)
            interp.appendLiteral(")")
        }
        interp.appendLiteral(" ON CONFLICT (task_id, seq) DO NOTHING")
        try await postgres.query(PostgresQuery(stringInterpolation: interp), logger: logger)
    }

    /// Connection variant of ``batchAppendHistory`` for use inside an existing transaction.
    /// Called from `flushWrites()` alongside `batchSetCheckpointsOnConn` so checkpoints
    /// and history commit atomically.
    package static func batchAppendHistory(
        on conn: PostgresConnection,
        namespaceID: String,
        taskID: UUID,
        events: [(seq: Int, eventType: HistoryEventType, eventData: ByteBuffer?)],
        logger: Logger
    ) async throws {
        guard !events.isEmpty else { return }
        if events.count == 1 {
            let e = events[0]
            try await appendHistory(
                on: conn,
                namespaceID: namespaceID,
                taskID: taskID,
                seq: e.seq,
                eventType: e.eventType,
                eventData: e.eventData,
                logger: logger
            )
            return
        }
        var interp = PostgresQuery.StringInterpolation(
            literalCapacity: 140 + events.count * 80,
            interpolationCount: events.count * 5 + 2
        )
        interp.appendLiteral(
            "INSERT INTO strand.workflow_history "
                + "(namespace_id, task_id, seq, event_type, event_data) VALUES "
        )
        for (i, e) in events.enumerated() {
            if i > 0 { interp.appendLiteral(", ") }
            interp.appendLiteral("(")
            interp.appendInterpolation(namespaceID)
            interp.appendLiteral(", ")
            interp.appendInterpolation(taskID)
            interp.appendLiteral(", ")
            interp.appendInterpolation(e.seq)
            interp.appendLiteral(", ")
            try interp.appendInterpolation(e.eventType)
            interp.appendLiteral(", ")
            interp.appendInterpolation(e.eventData)
            interp.appendLiteral(")")
        }
        interp.appendLiteral(" ON CONFLICT (task_id, seq) DO NOTHING")
        try await conn.query(PostgresQuery(stringInterpolation: interp), logger: logger)
    }

    /// Load history events for multiple workflow tasks in one round-trip.
    ///
    /// Used by the `/trace` route to batch-load history for all WORKFLOW spans
    /// in a trace tree instead of issuing K separate `listHistory` calls.
    /// The existing PRIMARY KEY `(task_id, seq)` on `strand.workflow_history`
    /// covers `WHERE task_id = ANY(...)` via per-value range scans — no new index needed.
    package static func batchListHistory(
        on postgres: PostgresClient,
        taskIDs: [UUID],
        logger: Logger
    ) async throws -> [UUID: [HistoryEventRow]] {
        guard !taskIDs.isEmpty else { return [:] }
        let stream = try await postgres.query(
            """
            SELECT task_id, seq, event_type, event_data, created_at
            FROM   strand.workflow_history
            WHERE  task_id = ANY(\(taskIDs))
            ORDER  BY task_id, seq ASC
            """,
            logger: logger
        )
        var result: [UUID: [HistoryEventRow]] = [:]
        for try await row in stream {
            var col = row.makeIterator()
            let taskID = try col.next()!.decode(UUID.self, context: .default)
            let seq = try col.next()!.decode(Int.self, context: .default)
            let rawType = try col.next()!.decode(String.self, context: .default)
            let eventData = try col.next()!.decode(ByteBuffer?.self, context: .default)
            let createdAt = try col.next()!.decode(Date.self, context: .default)
            guard let eventType = HistoryEventType(rawValue: rawType) else { continue }
            result[taskID, default: []].append(
                HistoryEventRow(seq: seq, eventType: eventType, eventData: eventData, createdAt: createdAt)
            )
        }
        return result
    }
}

// MARK: - Version markers

extension WorkflowStateQueries {

    /// Upserts a version marker for a workflow task.
    /// Called from applyScheduleCommands (.recordVersionMarker) and StrandClient.markVersion.
    package static func writeVersionMarker(
        on postgres: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        changeID: String,
        value: Bool,
        logger: Logger
    ) async throws {
        try await postgres.query(
            """
            INSERT INTO strand.workflow_version_markers
                (namespace_id, task_id, change_id, value, marked_at)
            VALUES (\(namespaceID), \(taskID), \(changeID), \(value), NOW())
            ON CONFLICT (task_id, change_id)
            DO UPDATE SET value = EXCLUDED.value, marked_at = NOW()
            """,
            logger: logger
        )
    }

    /// Writes multiple version markers in a single round-trip.
    /// Falls back to `writeVersionMarker` for the single-marker case to avoid
    /// the StringInterpolation overhead when N = 1.
    package static func batchWriteVersionMarkers(
        on postgres: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        markers: [(changeID: String, value: Bool)],
        logger: Logger
    ) async throws {
        guard !markers.isEmpty else { return }
        if markers.count == 1 {
            let m = markers[0]
            try await writeVersionMarker(
                on: postgres,
                namespaceID: namespaceID,
                taskID: taskID,
                changeID: m.changeID,
                value: m.value,
                logger: logger
            )
            return
        }
        var interp = PostgresQuery.StringInterpolation(
            literalCapacity: 120 + markers.count * 60,
            interpolationCount: markers.count * 3 + 2
        )
        interp.appendLiteral(
            "INSERT INTO strand.workflow_version_markers "
                + "(namespace_id, task_id, change_id, value, marked_at) VALUES "
        )
        for (i, m) in markers.enumerated() {
            if i > 0 { interp.appendLiteral(", ") }
            interp.appendLiteral("(")
            interp.appendInterpolation(namespaceID)
            interp.appendLiteral(", ")
            interp.appendInterpolation(taskID)
            interp.appendLiteral(", ")
            interp.appendInterpolation(m.changeID)
            interp.appendLiteral(", ")
            interp.appendInterpolation(m.value)
            interp.appendLiteral(", NOW())")
        }
        interp.appendLiteral(
            " ON CONFLICT (task_id, change_id) "
                + "DO UPDATE SET value = EXCLUDED.value, marked_at = NOW()"
        )
        try await postgres.query(PostgresQuery(stringInterpolation: interp), logger: logger)
    }

    package struct VersionMarkerRow: Sendable {
        package let changeID: String
        package let value: Bool
        package let markedAt: Date
    }

    /// Returns all version markers for a workflow task, ordered by marked_at DESC.
    package static func listVersionMarkers(
        on postgres: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        logger: Logger
    ) async throws -> [VersionMarkerRow] {
        let stream = try await postgres.query(
            """
            SELECT change_id, value, marked_at
            FROM strand.workflow_version_markers
            WHERE namespace_id = \(namespaceID)
              AND task_id = \(taskID)
            ORDER BY marked_at DESC
            """,
            logger: logger
        )
        var rows: [VersionMarkerRow] = []
        for try await row in stream {
            var col = row.makeIterator()
            let changeID = try col.next()!.decode(String.self, context: .default)
            let value = try col.next()!.decode(Bool.self, context: .default)
            let markedAt = try col.next()!.decode(Date.self, context: .default)
            rows.append(VersionMarkerRow(changeID: changeID, value: value, markedAt: markedAt))
        }
        return rows
    }

    /// Returns the migration status for a version gate across all workflows in a namespace.
    /// Used by ``StrandClient/migrationStatus(changeID:)`` to tell operators when it is
    /// safe to remove the old code path guarded by ``WorkflowContext/version(changeID:)``.
    /// `isSafeToRemove` is `true` when every in-flight workflow has passed the gate
    /// on the new path (no rows with `value = false` remain).
    package static func versionMigrationStatus(
        on postgres: PostgresClient,
        namespaceID: String,
        changeID: String,
        logger: Logger
    ) async throws -> MigrationStatus {
        let stream = try await postgres.query(
            """
            SELECT
              COALESCE(SUM(CASE WHEN value = false THEN 1 ELSE 0 END), 0)::integer AS pending,
              COALESCE(SUM(CASE WHEN value = true  THEN 1 ELSE 0 END), 0)::integer AS completed
            FROM strand.workflow_version_markers
            WHERE namespace_id = \(namespaceID)
              AND change_id    = \(changeID)
            """,
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else {
            return MigrationStatus(changeID: changeID, pendingCount: 0, completedCount: 0)
        }
        var col = row.makeIterator()
        let pending = try col.next()!.decode(Int.self, context: .default)
        let completed = try col.next()!.decode(Int.self, context: .default)
        return MigrationStatus(changeID: changeID, pendingCount: pending, completedCount: completed)
    }
}

// MARK: - WorkflowStateQueries.HistoryEventType: PostgresCodable

extension WorkflowStateQueries.HistoryEventType: PostgresCodable {
    package static var psqlType: PostgresDataType { .text }
    package static var psqlFormat: PostgresFormat { .binary }

    package func encode<E: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<E>
    ) throws {
        rawValue.encode(into: &byteBuffer, context: context)
    }

    package init<D: PostgresJSONDecoder>(
        from byteBuffer: inout ByteBuffer,
        type: PostgresDataType,
        format: PostgresFormat,
        context: PostgresDecodingContext<D>
    ) throws {
        let raw = try String(from: &byteBuffer, type: type, format: format, context: context)
        guard let evt = WorkflowStateQueries.HistoryEventType(rawValue: raw) else {
            throw PostgresDecodingError.Code.typeMismatch
        }
        self = evt
    }
}
