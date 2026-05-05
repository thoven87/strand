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
        // Convert UUIDs to their canonical string form and let Postgres cast the
        // text array to uuid[] via `::uuid[]`. This avoids any dependency on a
        // hypothetical [UUID]: PostgresEncodable conformance in PostgresNIO.
        let idStrings = ids.map { $0.uuidString }
        try await postgres.query(
            "DELETE FROM strand.workflow_signals WHERE id = ANY(\(idStrings)::uuid[])",
            logger: logger
        )
    }

    // MARK: - insertSignal

    /// Insert a signal into the inbox for a workflow task.
    ///
    /// Called by `StrandClient.signal(...)` / `WorkflowHandle.signal(...)`.
    /// After inserting, callers should call ``wakeWorkflowRun(on:taskID:logger:)``
    /// so the workflow is re-activated promptly rather than waiting for the
    /// next polling cycle.
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
        let prefix = "\(parentTaskID.uuidString):"
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
    package struct HistoryEventRow: Sendable {
        package let seq: Int
        package let eventType: String
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
            events.append(
                HistoryEventRow(
                    seq: try col.next()!.decode(Int.self, context: .default),
                    eventType: try col.next()!.decode(String.self, context: .default),
                    eventData: try col.next()!.decode(ByteBuffer?.self, context: .default),
                    createdAt: try col.next()!.decode(Date.self, context: .default)
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

    // MARK: - wakeWorkflowRun

    /// Wake a sleeping or waiting workflow run so it can process a newly-inserted signal.
    ///
    /// Transitions the run (and its parent task) from `SLEEPING` or `WAITING` → `PENDING`,
    /// clearing the lease and wake-event metadata so the worker can re-claim
    /// the run on the next poll cycle.
    ///
    /// - `SLEEPING`: timer-based suspension (`available_at` is meaningful).
    /// - `WAITING`: event/signal-based suspension (poll loop ignores it; must be explicitly woken).
    ///
    /// This is a **best-effort** nudge: if the run is not currently `SLEEPING` or `WAITING`
    /// (e.g. it's already `PENDING`, `RUNNING`, or `COMPLETED`) the UPDATE
    /// matches zero rows and the call is a no-op. This makes it safe to call
    /// unconditionally after ``insertSignal``.
    package static func wakeWorkflowRun(
        on postgres: PostgresClient,
        taskID: UUID,
        logger: Logger
    ) async throws {
        // Transition the run row first so that a polling worker can claim it
        // as soon as available_at is reached.
        try await postgres.query(
            """
            UPDATE strand.runs
               SET state            = 'PENDING',
                   available_at     = NOW(),
                   wake_event       = NULL,
                   event_payload    = NULL,
                   worker_id        = NULL,
                   lease_expires_at = NULL
             WHERE task_id = \(taskID)
               AND state   IN ('SLEEPING', 'WAITING')
            """,
            logger: logger
        )
        // Keep strand.tasks.state consistent with the run state so that
        // management queries and the dashboard reflect the correct status.
        try await postgres.query(
            """
            UPDATE strand.tasks
               SET state = 'PENDING'
             WHERE id    = \(taskID)
               AND state IN ('SLEEPING', 'WAITING')
            """,
            logger: logger
        )
    }
}
