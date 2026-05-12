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
    /// The registered signal name (matches `@WorkflowSignal.name`).
    let name: String
    /// Caller-supplied payload bytes, or `nil` when the signal carries no data.
    let payload: ByteBuffer?
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
            SELECT id, signal_name, payload
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
                    payload: try col.next()!.decode(ByteBuffer?.self, context: .default)
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
        state: TaskState, kind: TaskKind, name: String
    )] {
        let prefix = "\(parentTaskID):"
        let prefixPattern = prefix + "%"
        let stream = try await postgres.query(
            """
            SELECT t.idempotency_key, tc.result, tc.state,
                   r.failure_reason, t.kind, t.name
            FROM strand.task_completions tc
            JOIN strand.tasks t ON t.id = tc.task_id
            LEFT JOIN LATERAL (
                SELECT failure_reason FROM strand.runs
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
                state: TaskState, kind: TaskKind, name: String
            )] = []
        for try await row in stream {
            var col = row.makeIterator()
            let idempotencyKey = try col.next()!.decode(String.self, context: .default)
            let result = try col.next()!.decode(ByteBuffer?.self, context: .default)
            let stateRaw = try col.next()!.decode(String.self, context: .default)
            let failureReason = try col.next()!.decode(ByteBuffer?.self, context: .default)
            let kindRaw = try col.next()!.decode(String.self, context: .default)
            let taskName = try col.next()!.decode(String.self, context: .default)
            guard idempotencyKey.hasPrefix(prefix),
                let seqNum = Int(String(idempotencyKey.dropFirst(prefix.count))),
                let state = TaskState(rawValue: stateRaw),
                let kind = TaskKind(rawValue: kindRaw)
            else { continue }
            completions.append(
                (
                    seqNum: seqNum, result: result, failureReason: failureReason,
                    state: state, kind: kind, name: taskName
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
        case activityScheduled = "ACTIVITY_SCHEDULED"
        case timerStarted = "TIMER_STARTED"
        case timerFired = "TIMER_FIRED"
        case conditionWaiting = "CONDITION_WAITING"
        case eventWaitStarted = "EVENT_WAIT_STARTED"
        case eventReceived = "EVENT_RECEIVED"
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

    /// Payload for `EVENT_WAIT_STARTED` and `EVENT_RECEIVED`.
    ///
    /// JSON shape: `{"event_name":"order.approved"}`.
    package struct NamedEventData: Codable {
        package let eventName: String

        private enum CodingKeys: String, CodingKey {
            case eventName = "event_name"
        }
    }

    /// Payload for `TIMER_STARTED`.
    ///
    /// JSON shape: `{"duration_ms":5000}` — stored as a JSON number so the
    /// dashboard can display it without parsing.
    package struct TimerStartedData: Codable {
        package let durationMs: Int

        private enum CodingKeys: String, CodingKey {
            case durationMs = "duration_ms"
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
    package static func appendHistory(
        on postgres: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        seq: Int,
        eventType: HistoryEventType,
        eventData: ByteBuffer?,
        logger: Logger
    ) async throws {
        let rawType = eventType.rawValue
        try await postgres.query(
            """
            INSERT INTO strand.workflow_history (namespace_id, task_id, seq, event_type, event_data)
            VALUES (\(namespaceID), \(taskID), \(seq), \(rawType), \(eventData))
            ON CONFLICT (task_id, seq) DO NOTHING
            """,
            logger: logger
        )
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
        try await postgres.withTransaction(logger: logger) { conn in
            for e in events {
                let rawType = e.eventType.rawValue
                try await conn.query(
                    """
                    INSERT INTO strand.workflow_history (namespace_id, task_id, seq, event_type, event_data)
                    VALUES (\(namespaceID), \(taskID), \(e.seq), \(rawType), \(e.eventData))
                    ON CONFLICT (task_id, seq) DO NOTHING
                    """,
                    logger: logger
                )
            }
        }
    }

}
