package import Logging
package import NIOCore
package import PostgresNIO

#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

// MARK: - TraceSpanQueries

/// Write-through helpers for `strand.trace_spans`.
///
/// The engine calls these inside its existing transactions so the OLAP table
/// is always consistent with the transactional tables. Dashboard routes read
/// exclusively from `trace_spans` — no joins, no recursive CTEs.
///
/// ## Span ID conventions
/// - Task spans (WORKFLOW, ACTIVITY): `id = taskID.uuidString`
/// - History spans (SIGNAL, SLEEP, WAIT …): `id = "\(taskID.uuidString):\(seqNum)"`
/// - `parentID` for child tasks: `parentTaskID.uuidString`
/// - `parentID` for history spans: `taskID.uuidString` (the owning workflow)
///
/// ## root_task_id propagation
/// The COALESCE subquery in every INSERT resolves `root_task_id` from the
/// parent span row (which is always inserted before its children) and falls
/// back to `taskID` for root tasks (no parent). This keeps the entire tree
/// addressable with a single `WHERE root_task_id = $1` scan.
package enum TraceSpanQueries {

    // MARK: - Write helpers

    /// Insert or update a WORKFLOW / ACTIVITY task-level span.
    ///
    /// ON CONFLICT preserves existing values for fields the caller passes nil:
    /// worker_id, started_at, finished_at, error are coalesced so lifecycle
    /// updates (claim→complete) never accidentally clear earlier data.
    package static func upsertTaskSpan(
        on conn: PostgresConnection,
        id: String,
        namespaceID: String,
        taskID: UUID,
        parentID: String?,
        kind: WorkflowSpanKind,
        name: String,
        state: WorkflowSpanState,
        maxAttempts: Int? = nil,
        attempt: Int? = nil,
        workerID: String? = nil,
        queuedAt: Date? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        error: String? = nil,
        eventType: WorkflowStateQueries.HistoryEventType? = nil,
        eventData: ByteBuffer? = nil,
        seqNum: Int? = nil,
        logger: Logger
    ) async throws {
        let effectiveQueuedAt = queuedAt ?? Date()
        let parentLookup = parentID ?? id
        try await conn.query(
            """
            INSERT INTO strand.trace_spans
                (id, namespace_id, root_task_id, task_id, parent_id,
                 kind, name, state, attempt, worker_id, max_attempts,
                 queued_at, started_at, finished_at, error,
                 event_type, event_data, seq_num)
            SELECT \(id), \(namespaceID),
                   COALESCE(
                       (SELECT root_task_id FROM strand.trace_spans WHERE id = \(parentLookup) LIMIT 1),
                       \(taskID)
                   ),
                   \(taskID), \(parentID),
                   \(kind), \(name), \(state),
                   COALESCE(\(attempt), 0),
                   \(workerID), \(maxAttempts),
                   \(effectiveQueuedAt), \(startedAt), \(finishedAt), \(error),
                   \(eventType), \(eventData), \(seqNum)
            ON CONFLICT (id) DO UPDATE
                SET state       = EXCLUDED.state,
                    attempt     = GREATEST(EXCLUDED.attempt, strand.trace_spans.attempt),
                    worker_id   = COALESCE(EXCLUDED.worker_id,   strand.trace_spans.worker_id),
                    started_at  = COALESCE(EXCLUDED.started_at,  strand.trace_spans.started_at),
                    finished_at = COALESCE(EXCLUDED.finished_at, strand.trace_spans.finished_at),
                    error       = COALESCE(EXCLUDED.error,       strand.trace_spans.error),
                    event_type  = COALESCE(EXCLUDED.event_type,  strand.trace_spans.event_type),
                    event_data  = COALESCE(EXCLUDED.event_data,  strand.trace_spans.event_data)
            """,
            logger: logger
        )
    }

    /// Insert a zero-duration span for instant events: SIGNAL, UPDATE, EMIT.
    package static func insertInstantSpan(
        on postgres: PostgresClient,
        id: String,
        namespaceID: String,
        taskID: UUID,
        parentID: String?,
        kind: WorkflowSpanKind,
        name: String,
        at: Date,
        eventType: WorkflowStateQueries.HistoryEventType? = nil,
        seqNum: Int? = nil,
        logger: Logger
    ) async throws {
        let parentLookup = parentID ?? id
        let completed = WorkflowSpanState.completed
        try await postgres.query(
            """
            INSERT INTO strand.trace_spans
                (id, namespace_id, root_task_id, task_id, parent_id,
                 kind, name, state, queued_at, started_at, finished_at,
                 event_type, seq_num)
            SELECT \(id), \(namespaceID),
                   COALESCE(
                       (SELECT root_task_id FROM strand.trace_spans WHERE id = \(parentLookup) LIMIT 1),
                       \(taskID)
                   ),
                   \(taskID), \(parentID),
                   \(kind), \(name), \(completed), \(at), \(at), \(at),
                   \(eventType), \(seqNum)
            ON CONFLICT (id) DO NOTHING
            """,
            logger: logger
        )
    }

    /// Insert an open-ended duration span: SLEEP, WAIT, CONDITION.
    package static func openDurationSpan(
        on postgres: PostgresClient,
        id: String,
        namespaceID: String,
        taskID: UUID,
        parentID: String?,
        kind: WorkflowSpanKind,
        name: String,
        startedAt: Date,
        eventType: WorkflowStateQueries.HistoryEventType? = nil,
        seqNum: Int? = nil,
        logger: Logger
    ) async throws {
        let parentLookup = parentID ?? id
        let running = WorkflowSpanState.running
        try await postgres.query(
            """
            INSERT INTO strand.trace_spans
                (id, namespace_id, root_task_id, task_id, parent_id,
                 kind, name, state, queued_at, started_at,
                 event_type, seq_num)
            SELECT \(id), \(namespaceID),
                   COALESCE(
                       (SELECT root_task_id FROM strand.trace_spans WHERE id = \(parentLookup) LIMIT 1),
                       \(taskID)
                   ),
                   \(taskID), \(parentID),
                   \(kind), \(name), \(running), \(startedAt), \(startedAt),
                   \(eventType), \(seqNum)
            ON CONFLICT (id) DO NOTHING
            """,
            logger: logger
        )
    }

    /// Close a duration span by stamping `finished_at` and the terminal `event_type`.
    package static func closeDurationSpan(
        on postgres: PostgresClient,
        id: String,
        state: WorkflowSpanState,
        finishedAt: Date,
        endEventType: WorkflowStateQueries.HistoryEventType? = nil,
        logger: Logger
    ) async throws {
        try await postgres.query(
            """
            UPDATE strand.trace_spans
            SET state       = \(state),
                finished_at = \(finishedAt),
                event_type  = COALESCE(\(endEventType), event_type)
            WHERE id = \(id)
            """,
            logger: logger
        )
    }

    // MARK: - Read helpers (dashboard routes)

    /// Decoded span row from `strand.trace_spans`.
    package struct SpanRow: Sendable {
        package let id: String
        package let rootTaskID: UUID
        package let taskID: UUID
        package let parentID: String?
        package let kind: String
        package let name: String
        package let state: String
        package let attempt: Int
        package let workerID: String?
        package let maxAttempts: Int?
        package let queuedAt: Date
        package let startedAt: Date?
        package let finishedAt: Date?
        package let error: String?
        package let eventType: String?
        package let eventData: ByteBuffer?
        package let seqNum: Int?
    }

    private static func decodeRow(_ row: PostgresRow) throws -> SpanRow {
        var col = row.makeIterator()
        return SpanRow(
            id: try col.next()!.decode(String.self, context: .default),
            rootTaskID: try col.next()!.decode(UUID.self, context: .default),
            taskID: try col.next()!.decode(UUID.self, context: .default),
            parentID: try col.next()!.decode(String?.self, context: .default),
            kind: try col.next()!.decode(String.self, context: .default),
            name: try col.next()!.decode(String.self, context: .default),
            state: try col.next()!.decode(String.self, context: .default),
            attempt: try col.next()!.decode(Int.self, context: .default),
            workerID: try col.next()!.decode(String?.self, context: .default),
            maxAttempts: try col.next()!.decode(Int?.self, context: .default),
            queuedAt: try col.next()!.decode(Date.self, context: .default),
            startedAt: try col.next()!.decode(Date?.self, context: .default),
            finishedAt: try col.next()!.decode(Date?.self, context: .default),
            error: try col.next()!.decode(String?.self, context: .default),
            eventType: try col.next()!.decode(String?.self, context: .default),
            eventData: try col.next()!.decode(ByteBuffer?.self, context: .default),
            seqNum: try col.next()!.decode(Int?.self, context: .default)
        )
    }

    /// Returns all spans for a trace tree ordered by `queued_at`.
    /// Replaces `traceTask` + `executionHistorySpansForTrace` — one index scan.
    package static func getTraceSpans(
        on postgres: PostgresClient,
        namespaceID: String,
        rootTaskID: UUID,
        logger: Logger
    ) async throws -> [SpanRow] {
        let stream = try await postgres.query(
            """
            SELECT id, root_task_id, task_id, parent_id,
                   kind, name, state, attempt, worker_id, max_attempts,
                   queued_at, started_at, finished_at, error,
                   event_type, event_data, seq_num
            FROM   strand.trace_spans
            WHERE  namespace_id = \(namespaceID)
              AND  root_task_id = \(rootTaskID)
            ORDER  BY queued_at ASC
            """,
            logger: logger
        )
        var rows: [SpanRow] = []
        for try await row in stream { rows.append(try decodeRow(row)) }
        return rows
    }

    /// Returns history events for a single task ordered by `seq_num`.
    /// Replaces `WorkflowStateQueries.listHistory` — one index scan.
    package static func getHistoryFromSpans(
        on postgres: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        logger: Logger
    ) async throws -> [SpanRow] {
        let stream = try await postgres.query(
            """
            SELECT id, root_task_id, task_id, parent_id,
                   kind, name, state, attempt, worker_id, max_attempts,
                   queued_at, started_at, finished_at, error,
                   event_type, event_data, seq_num
            FROM   strand.trace_spans
            WHERE  namespace_id = \(namespaceID)
              AND  task_id      = \(taskID)
              AND  event_type   IS NOT NULL
            ORDER  BY seq_num ASC NULLS LAST, queued_at ASC
            """,
            logger: logger
        )
        var rows: [SpanRow] = []
        for try await row in stream { rows.append(try decodeRow(row)) }
        return rows
    }
}
