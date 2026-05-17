package import Logging
package import NIOCore
package import PostgresNIO

#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

// MARK: - Cursor page

/// Generic cursor-paginated result.
/// `nextCursor` is an opaque string token — UUID for tasks/runs, Unix timestamp for events.
/// `nil` means there are no more pages.
package struct CursorPage<T: Sendable>: Sendable {
    package let items: [T]
    package let nextCursor: String?
}

// MARK: - Row types (internal — consumed by StrandServer route handlers)

/// Task summary row returned by ``ManagementQueries/listTasks``.
package struct TaskSummaryRow: Sendable {
    package let id: UUID
    package let name: String
    package let queue: String
    package let state: TaskState
    package let attempt: Int
    package let createdAt: Date
    package let firstRunAt: Date?
    package let completedAt: Date?
    /// `.workflow` or `.activity` — distinguishes root orchestrators from child leaf tasks.
    package let kind: TaskKind
    /// Non-nil for activity tasks spawned by a workflow.
    package let parentTaskId: UUID?
    /// Schedule name that triggered this task, or `nil` if not scheduled.
    package let scheduleName: String?
    /// Human-readable workflow ID set at enqueue time via ``WorkflowOptions/id``.
    /// Auto-generated as `"WorkflowName-<ms>"` when not explicitly provided.
    /// `nil` for activity tasks (spawned internally, not via `startWorkflow`).
    package let workflowId: String?
}

extension TaskSummaryRow {
    /// Column order: id, name, queue, state, attempt, created_at, first_run_at, completed_at,
    ///               kind, parent_task_id, scheduling_metadata, idempotency_key
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        id = try col.next()!.decode(UUID.self, context: .default)
        name = try col.next()!.decode(String.self, context: .default)
        queue = try col.next()!.decode(String.self, context: .default)
        state = try col.next()!.decode(TaskState.self, context: .default)
        attempt = try col.next()!.decode(Int.self, context: .default)
        createdAt = try col.next()!.decode(Date.self, context: .default)
        firstRunAt = try col.next()!.decode(Date?.self, context: .default)
        completedAt = try col.next()!.decode(Date?.self, context: .default)
        kind = try col.next()!.decode(TaskKind.self, context: .default)
        parentTaskId = try col.next()!.decode(UUID?.self, context: .default)
        scheduleName = try col.next()!.decode(SchedulingMetadata?.self, context: .default)?.scheduledBy
        workflowId = try col.next()!.decode(String?.self, context: .default)
    }
}

/// Full task detail row returned by ``ManagementQueries/getTask``.
package struct TaskDetailRow: Sendable {
    package let id: UUID
    package let name: String
    package let queue: String
    package let paramsBuffer: ByteBuffer  // raw JSON BYTEA
    package let state: TaskState
    package let attempt: Int
    package let maxAttempts: Int?
    package let createdAt: Date
    package let firstRunAt: Date?
    package let completedAt: Date?
    package let resultBuffer: ByteBuffer?  // raw JSON BYTEA
    package let cancelledAt: Date?
    package let kind: TaskKind
    package let parentTaskId: UUID?
    /// Scheduling metadata decoded from task headers, or `nil` if not scheduled.
    package let schedulingMetadata: SchedulingMetadata?
    /// Human-readable workflow ID (stored as `idempotency_key`). See ``TaskSummaryRow/workflowId``.
    package let workflowId: String?
}

extension TaskDetailRow {
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        id = try col.next()!.decode(UUID.self, context: .default)
        name = try col.next()!.decode(String.self, context: .default)
        queue = try col.next()!.decode(String.self, context: .default)
        paramsBuffer = try col.next()!.decode(ByteBuffer.self, context: .default)
        state = try col.next()!.decode(TaskState.self, context: .default)
        attempt = try col.next()!.decode(Int.self, context: .default)
        maxAttempts = try col.next()!.decode(Int?.self, context: .default)
        createdAt = try col.next()!.decode(Date.self, context: .default)
        firstRunAt = try col.next()!.decode(Date?.self, context: .default)
        completedAt = try col.next()!.decode(Date?.self, context: .default)
        resultBuffer = try col.next()!.decode(ByteBuffer?.self, context: .default)
        cancelledAt = try col.next()!.decode(Date?.self, context: .default)
        kind = try col.next()!.decode(TaskKind.self, context: .default)
        parentTaskId = try col.next()!.decode(UUID?.self, context: .default)
        schedulingMetadata = try col.next()!.decode(SchedulingMetadata?.self, context: .default)
        workflowId = try col.next()!.decode(String?.self, context: .default)
    }
}

/// Run summary row returned by ``ManagementQueries/listRuns``.
package struct RunSummaryRow: Sendable {
    package let id: UUID
    package let attempt: Int
    package let state: TaskState
    package let workerID: String?
    package let sdkVersion: String?
    package let startedAt: Date?
    package let finishedAt: Date?
    package let leaseExpiresAt: Date?
    package let createdAt: Date
    package let failureBuffer: ByteBuffer?  // raw JSON BYTEA
}

extension RunSummaryRow {
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        id = try col.next()!.decode(UUID.self, context: .default)
        attempt = try col.next()!.decode(Int.self, context: .default)
        state = try col.next()!.decode(TaskState.self, context: .default)
        workerID = try col.next()!.decode(String?.self, context: .default)
        sdkVersion = try col.next()!.decode(String?.self, context: .default)
        startedAt = try col.next()!.decode(Date?.self, context: .default)
        finishedAt = try col.next()!.decode(Date?.self, context: .default)
        leaseExpiresAt = try col.next()!.decode(Date?.self, context: .default)
        createdAt = try col.next()!.decode(Date.self, context: .default)
        failureBuffer = try col.next()!.decode(ByteBuffer?.self, context: .default)
    }
}

/// Queue stats row returned by ``ManagementQueries/listQueueStats``.
package struct QueueStatsRow: Sendable {
    package let name: String
    package let createdAt: Date
    package let pending: Int
    package let running: Int
    /// Workflows suspended on a `ctx.sleep(for:)` timer.
    package let sleeping: Int
    /// Workflows suspended waiting for an activity, child workflow, or named event.
    package let waiting: Int
    package let completed: Int
    package let failed: Int
    package let cancelled: Int
    package let isPaused: Bool
}

extension QueueStatsRow {
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        name = try col.next()!.decode(String.self, context: .default)
        createdAt = try col.next()!.decode(Date.self, context: .default)
        pending = try col.next()!.decode(Int.self, context: .default)
        running = try col.next()!.decode(Int.self, context: .default)
        sleeping = try col.next()!.decode(Int.self, context: .default)
        waiting = try col.next()!.decode(Int.self, context: .default)
        completed = try col.next()!.decode(Int.self, context: .default)
        failed = try col.next()!.decode(Int.self, context: .default)
        cancelled = try col.next()!.decode(Int.self, context: .default)
        isPaused = try col.next()!.decode(Bool.self, context: .default)
    }
}

/// One triggered-task entry returned from the event_triggers join.
package struct TriggeredTask: Codable, Sendable {
    package let taskId: UUID
    package let taskName: String
    package let taskState: String
    package let taskKind: String

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case taskName = "task_name"
        case taskState = "task_state"
        case taskKind = "task_kind"
    }
}

/// Event emission row returned by ``ManagementQueries/listEvents``.
package struct EventRow: Sendable {
    package let id: UUID  // emission ID (UUIDv7) — new in append-only log
    package let name: String
    package let payloadBuffer: ByteBuffer?
    package let createdAt: Date
    package let queue: String
    package let triggeredTasks: [TriggeredTask]
}

extension EventRow {
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        id = try col.next()!.decode(UUID.self, context: .default)
        name = try col.next()!.decode(String.self, context: .default)
        payloadBuffer = try col.next()!.decode(RawJSONB?.self, context: .default).map(\.buffer)
        createdAt = try col.next()!.decode(Date.self, context: .default)
        queue = try col.next()!.decode(String.self, context: .default)
        // triggered_tasks is a json_agg result; uniqueness enforced by the
        // (emission_id, task_id) partial index on event_triggers.
        let triggeredBuf = try col.next()!.decode(ByteBuffer.self, context: .default)
        triggeredTasks = (try? JSON.decode([TriggeredTask].self, from: triggeredBuf)) ?? []
    }
}

/// One workflow currently suspended in `ctx.waitForEvent(name)`.
/// Returned by ``listEventWaiters``.
package struct EventWaiterRow: Sendable {
    package let taskId: UUID
    package let taskName: String
    package let taskState: TaskState
    package let seqNum: Int
    package let timeoutAt: Date?
}

extension EventWaiterRow {
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        taskId = try col.next()!.decode(UUID.self, context: .default)
        taskName = try col.next()!.decode(String.self, context: .default)
        taskState = try col.next()!.decode(TaskState.self, context: .default)
        seqNum = try col.next()!.decode(Int.self, context: .default)
        timeoutAt = try col.next()!.decode(Date?.self, context: .default)
    }
}

/// The event-trigger record for a task — links a task back to the specific
/// emission of a named event that woke it.
package struct EventTriggerRow: Sendable {
    package let emissionID: UUID?  // nil for rows inserted before the append-only migration
    package let eventName: String
    package let queue: String
    package let triggeredAt: Date
}

extension EventTriggerRow {
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        emissionID = try col.next()!.decode(UUID?.self, context: .default)
        eventName = try col.next()!.decode(String.self, context: .default)
        queue = try col.next()!.decode(String.self, context: .default)
        triggeredAt = try col.next()!.decode(Date.self, context: .default)
    }
}

// MARK: - Queries

/// Read-only queries used by the Strand dashboard HTTP API.
/// All writes go through ``Queries``; this namespace is purely observational.
package enum ManagementQueries {

    // MARK: - Queue stats

    /// All queues with per-state task counts (for the queue list view).
    package static func listQueueStats(
        on client: PostgresClient,
        namespaceID: String,
        rootOnly: Bool = false,
        logger: Logger
    ) async throws -> [QueueStatsRow] {
        let stream = try await client.query(
            """
            SELECT
              q.name,
              q.created_at,
              COUNT(t.id) FILTER (WHERE t.state = 'PENDING')    AS pending,
              COUNT(t.id) FILTER (WHERE t.state = 'RUNNING')    AS running,
              COUNT(t.id) FILTER (WHERE t.state = 'SLEEPING')   AS sleeping,
              COUNT(t.id) FILTER (WHERE t.state = 'WAITING')    AS waiting,
              COUNT(t.id) FILTER (WHERE t.state = 'COMPLETED')  AS completed,
              COUNT(t.id) FILTER (WHERE t.state = 'FAILED')     AS failed,
              COUNT(t.id) FILTER (WHERE t.state = 'CANCELLED')  AS cancelled,
              q.is_paused
            FROM strand.queues q
            -- When rootOnly=true, only join root tasks (parent_task_id IS NULL)
            -- so the stats bar counts the same population as the task list.
            LEFT JOIN strand.tasks t ON t.queue = q.name
                                    AND t.namespace_id = q.namespace_id
                                    AND (NOT \(rootOnly) OR t.parent_task_id IS NULL)
            WHERE q.namespace_id = \(namespaceID)
            GROUP BY q.name, q.created_at, q.is_paused
            ORDER BY q.name
            """,
            logger: logger
        )
        var rows: [QueueStatsRow] = []
        for try await row in stream { rows.append(try QueueStatsRow(row: row)) }
        return rows
    }

    /// Stats for a single queue.
    package static func queueStats(
        on client: PostgresClient,
        namespaceID: String,
        queue: String,
        rootOnly: Bool = false,
        logger: Logger
    ) async throws -> QueueStatsRow? {
        let stream = try await client.query(
            """
            SELECT
              q.name,
              q.created_at,
              COUNT(t.id) FILTER (WHERE t.state = 'PENDING')    AS pending,
              COUNT(t.id) FILTER (WHERE t.state = 'RUNNING')    AS running,
              COUNT(t.id) FILTER (WHERE t.state = 'SLEEPING')   AS sleeping,
              COUNT(t.id) FILTER (WHERE t.state = 'WAITING')    AS waiting,
              COUNT(t.id) FILTER (WHERE t.state = 'COMPLETED')  AS completed,
              COUNT(t.id) FILTER (WHERE t.state = 'FAILED')     AS failed,
              COUNT(t.id) FILTER (WHERE t.state = 'CANCELLED')  AS cancelled,
              q.is_paused
            FROM strand.queues q
            -- When rootOnly=true, only join root tasks (parent_task_id IS NULL)
            -- so the stats bar counts the same population as the task list.
            LEFT JOIN strand.tasks t ON t.queue = q.name
                                    AND t.namespace_id = q.namespace_id
                                    AND (NOT \(rootOnly) OR t.parent_task_id IS NULL)
            WHERE q.name = \(queue) AND q.namespace_id = \(namespaceID)
            GROUP BY q.name, q.created_at, q.is_paused
            """,
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else { return nil }
        return try QueueStatsRow(row: row)
    }

    // MARK: - Tasks

    /// Cursor-paginated task list ordered by `id` (UUIDv7, time-ordered).
    ///
    /// The cursor is the raw UUID of the last seen task. Pass `nil` for the first page.
    /// `nextCursor` in the returned page is the UUID string to use for the next call,
    /// or `nil` when there are no more pages.
    package static func listTasks(
        on client: PostgresClient,
        namespaceID: String,
        queue: String?,
        state: String?,
        name: String?,
        kind: TaskKind? = nil,
        rootOnly: Bool? = nil,
        cursor: UUID?,
        limit: Int,
        logger: Logger
    ) async throws -> CursorPage<TaskSummaryRow> {
        let fetchLimit = limit + 1  // fetch one extra to detect a next page
        let stream = try await client.query(
            """
            SELECT id, name, queue, state, attempt, created_at, first_run_at, completed_at,
                   kind, parent_task_id, scheduling_metadata, idempotency_key
            FROM strand.tasks
            WHERE namespace_id = \(namespaceID)
              AND (\(queue)::text IS NULL OR queue = \(queue))
              AND (\(state)::text IS NULL OR state = \(state))
              AND (\(name)::text IS NULL OR name = \(name))
              AND (\(kind)::text IS NULL OR kind = \(kind))
              AND (\(rootOnly)::bool IS NULL OR (parent_task_id IS NULL) = \(rootOnly))
              AND (\(cursor)::uuid IS NULL OR id < \(cursor))
            ORDER BY id DESC
            LIMIT \(fetchLimit)
            """,
            logger: logger
        )
        var rows: [TaskSummaryRow] = []
        for try await row in stream { rows.append(try TaskSummaryRow(row: row)) }
        let hasMore = rows.count > limit
        if hasMore { rows.removeLast() }
        let nextCursor = hasMore ? rows.last?.id.uuidString : nil
        return CursorPage(items: rows, nextCursor: nextCursor)
    }

    /// Full task detail including raw params and result buffers.
    package static func getTask(
        on client: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        logger: Logger
    ) async throws -> TaskDetailRow? {
        let stream = try await client.query(
            """
            SELECT id, name, queue, params, state, attempt, max_attempts,
                   created_at, first_run_at, completed_at, result, cancelled_at,
                   kind, parent_task_id, scheduling_metadata, idempotency_key
            FROM strand.tasks WHERE id = \(taskID) AND namespace_id = \(namespaceID)
            """,
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else { return nil }
        return try TaskDetailRow(row: row)
    }

    // MARK: - Runs

    /// All runs for a task, most-recent attempt first.
    package static func listRuns(
        on client: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        logger: Logger
    ) async throws -> [RunSummaryRow] {
        let stream = try await client.query(
            """
            SELECT id, attempt, state, worker_id, sdk_version,
                   started_at, finished_at, lease_expires_at, created_at, failure_reason
            FROM strand.runs
            WHERE task_id = \(taskID) AND namespace_id = \(namespaceID)
            ORDER BY attempt DESC
            """,
            logger: logger
        )
        var rows: [RunSummaryRow] = []
        for try await row in stream { rows.append(try RunSummaryRow(row: row)) }
        return rows
    }

    /// All checkpoints for a run, ordered by creation time.
    package static func listCheckpoints(
        on client: PostgresClient,
        runID: UUID,
        logger: Logger
    ) async throws -> [CheckpointRow] {
        let stream = try await client.query(
            """
            SELECT seq_num, name, state
            FROM strand.checkpoints
            WHERE run_id = \(runID)
            ORDER BY created_at ASC
            """,
            logger: logger
        )
        var rows: [CheckpointRow] = []
        for try await row in stream { rows.append(try CheckpointRow(row: row)) }
        return rows
    }

    // MARK: - Events

    /// Cursor-paginated event list, newest first.
    ///
    /// The cursor is the Unix timestamp (seconds since epoch) of the last seen event,
    /// encoded as a decimal string. Pass `nil` for the first page.
    package static func listEvents(
        on client: PostgresClient,
        namespaceID: String,
        queue: String,
        since: Date?,
        cursor: Date?,
        limit: Int,
        logger: Logger
    ) async throws -> CursorPage<EventRow> {
        let fetchLimit = limit + 1
        let stream = try await client.query(
            """
            SELECT
                e.id,
                e.name,
                e.payload,
                e.created_at,
                e.queue,
                COALESCE(
                    (SELECT json_agg(
                                json_build_object(
                                    'task_id',    et.task_id,
                                    'task_name',  t.name,
                                    'task_state', t.state::text,
                                    'task_kind',  t.kind::text
                                )
                                ORDER BY et.triggered_at DESC
                            )
                     FROM   strand.event_triggers et
                     JOIN   strand.tasks t
                            ON  t.id = et.task_id
                            AND t.namespace_id = e.namespace_id
                     WHERE  et.emission_id = e.id
                    ),
                    '[]'::json
                ) AS triggered_tasks
            FROM strand.events e
            WHERE e.namespace_id = \(namespaceID)
              AND e.queue = \(queue)
              AND (\(since)::timestamptz IS NULL OR e.created_at >= \(since))
              AND (\(cursor)::timestamptz IS NULL OR e.created_at < \(cursor))
            ORDER BY e.created_at DESC
            LIMIT \(fetchLimit)
            """,
            logger: logger
        )
        var rows: [EventRow] = []
        for try await row in stream { rows.append(try EventRow(row: row)) }
        let hasMore = rows.count > limit
        if hasMore { rows.removeLast() }
        // Encode cursor as Unix timestamp string for opaque round-trip.
        let nextCursor = hasMore ? rows.last.map { "\($0.createdAt.timeIntervalSince1970)" } : nil
        return CursorPage(items: rows, nextCursor: nextCursor)
    }

    // MARK: - Global events

    /// Cursor-paginated event list across all queues, newest first.
    package static func listEventsGlobal(
        on client: PostgresClient,
        namespaceID: String,
        queue: String?,
        name: String?,
        since: Date?,
        cursor: Date?,
        limit: Int,
        logger: Logger
    ) async throws -> CursorPage<EventRow> {
        let fetchLimit = limit + 1
        let stream = try await client.query(
            """
            SELECT
                e.id,
                e.name,
                e.payload,
                e.created_at,
                e.queue,
                COALESCE(
                    (SELECT json_agg(
                                json_build_object(
                                    'task_id',    et.task_id,
                                    'task_name',  t.name,
                                    'task_state', t.state::text,
                                    'task_kind',  t.kind::text
                                )
                                ORDER BY et.triggered_at DESC
                            )
                     FROM   strand.event_triggers et
                     JOIN   strand.tasks t
                            ON  t.id = et.task_id
                            AND t.namespace_id = e.namespace_id
                     WHERE  et.emission_id = e.id
                    ),
                    '[]'::json
                ) AS triggered_tasks
            FROM strand.events e
            WHERE e.namespace_id = \(namespaceID)
              AND (\(queue)::text IS NULL OR e.queue = \(queue))
              AND (\(name)::text IS NULL OR e.name = \(name))
              AND (\(since)::timestamptz IS NULL OR e.created_at >= \(since))
              AND (\(cursor)::timestamptz IS NULL OR e.created_at < \(cursor))
            ORDER BY e.created_at DESC
            LIMIT \(fetchLimit)
            """,
            logger: logger
        )
        var rows: [EventRow] = []
        for try await row in stream { rows.append(try EventRow(row: row)) }
        let hasMore = rows.count > limit
        if hasMore { rows.removeLast() }
        let nextCursor = hasMore ? rows.last.map { "\($0.createdAt.timeIntervalSince1970)" } : nil
        return CursorPage(items: rows, nextCursor: nextCursor)
    }

    /// Returns the event-trigger record for a task, if any.
    /// Used by the task detail page to link a workflow back to the specific event
    /// emission that woke it from a `ctx.waitForEvent` suspension.
    package static func getEventTriggerForTask(
        on client: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        logger: Logger
    ) async throws -> EventTriggerRow? {
        let stream = try await client.query(
            """
            SELECT et.emission_id, et.event_name, et.queue, et.triggered_at
            FROM strand.event_triggers et
            WHERE et.task_id = \(taskID)
            ORDER BY et.triggered_at DESC
            LIMIT 1
            """,
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else { return nil }
        return try EventTriggerRow(row: row)
    }

    // MARK: - Formatting helpers

    /// Formats a timer duration (in milliseconds) as a compact, locale-independent
    /// human-readable string. Used as the SLEEP span name in the trace view.
    ///
    /// Example output: `"500ms"`, `"30s"`, `"1m 30s"`, `"2h"`, `"1d 12h"`.
    ///
    /// `Duration.milliseconds(ms).formatted(.units(..., width: .narrow))` would be
    /// shorter but is unsuitable here for two reasons:
    /// 1. `DateComponentsFormatter` is not available in `FoundationEssentials`
    ///    (used on Linux), so the `.narrow` style would require full Foundation.
    /// 2. Both formatters produce locale-sensitive output (e.g. `"30 сек"` on a
    ///    Russian-locale server). This function runs server-side and its output is
    ///    stored as span name data returned to all clients — consistent,
    ///    locale-independent output is required.
    package static func sleepLabel(durationMs ms: Int) -> String {
        if ms < 1_000 { return "\(ms)ms" }
        if ms < 60_000 { return "\(ms / 1_000)s" }
        if ms < 3_600_000 {
            let m = ms / 60_000
            let s = (ms % 60_000) / 1_000
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        }
        if ms < 86_400_000 {
            let h = ms / 3_600_000
            let m = (ms % 3_600_000) / 60_000
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        let days = ms / 86_400_000
        let h = (ms % 86_400_000) / 3_600_000
        return h > 0 ? "\(days)d \(h)h" : "\(days)d"
    }

    // MARK: - Retention helpers

    /// Returns all namespace IDs from `strand.namespaces`, ordered alphabetically.
    /// Used by the pruner when `namespaceID` is `nil` (prune all namespaces).
    /// Connection overload — SQL lives here.
    package static func allNamespaceIDs(
        on conn: PostgresConnection,
        logger: Logger
    ) async throws -> [String] {
        let stream = try await conn.query(
            "SELECT id FROM strand.namespaces ORDER BY id",
            logger: logger
        )
        var ids: [String] = []
        for try await row in stream {
            var col = row.makeIterator()
            if let id = try? col.next()?.decode(String.self, context: .default) {
                ids.append(id)
            }
        }
        return ids
    }

    package static func allNamespaceIDs(
        on client: PostgresClient,
        logger: Logger
    ) async throws -> [String] {
        try await client.withConnection { conn in
            try await allNamespaceIDs(on: conn, logger: logger)
        }
    }

    /// Minimum `retention_days` across all namespaces, falling back to 30.
    ///
    /// Used for partition-drop cutoff calculations in multi-namespace mode:
    /// partitions are shared across all namespaces, so the most conservative
    /// (shortest) retention window must be respected — a partition cannot be
    /// dropped if any namespace still needs data from it.
    /// Connection overload — SQL lives here.
    package static func minimumRetentionDays(
        on conn: PostgresConnection,
        logger: Logger
    ) async throws -> Int {
        let stream = try await conn.query(
            "SELECT COALESCE(MIN(retention_days), 30) FROM strand.namespaces",
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else { return 30 }
        var col = row.makeIterator()
        return (try? col.next()?.decode(Int.self, context: .default)) ?? 30
    }

    package static func minimumRetentionDays(
        on client: PostgresClient,
        logger: Logger
    ) async throws -> Int {
        try await client.withConnection { conn in
            try await minimumRetentionDays(on: conn, logger: logger)
        }
    }

    /// Returns `retention_days` for a single namespace, falling back to 30
    /// if the row is missing. Used per-namespace in `tryPrune` and in
    /// `tryManagePartitions` when a specific namespace is configured.
    /// Connection overload — SQL lives here.
    package static func retentionDays(
        namespaceID: String,
        on conn: PostgresConnection,
        logger: Logger
    ) async throws -> Int {
        let stream = try await conn.query(
            "SELECT retention_days FROM strand.namespaces WHERE id = \(namespaceID)",
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else { return 30 }
        var col = row.makeIterator()
        return (try? col.next()?.decode(Int.self, context: .default)) ?? 30
    }

    /// Client overload — one-liner that delegates to the connection overload.
    package static func retentionDays(
        namespaceID: String,
        on client: PostgresClient,
        logger: Logger
    ) async throws -> Int {
        try await client.withConnection { conn in
            try await retentionDays(namespaceID: namespaceID, on: conn, logger: logger)
        }
    }

    // MARK: - Cleanup

    /// Deletes terminal tasks older than `ageSeconds` and their associated
    /// runs, checkpoints, and event-wait registrations.
    ///
    /// Uses `FOR UPDATE SKIP LOCKED` so concurrent cleanup calls never
    /// double-process the same rows. Returns the number of tasks deleted.
    package static func cleanupTasks(
        on client: PostgresClient,
        namespaceID: String,
        queue: String?,
        ageSeconds: Int?,
        limit: Int,
        logger: Logger
    ) async throws -> Int {
        let effectiveAgeSeconds: Int
        if let explicit = ageSeconds {
            effectiveAgeSeconds = explicit
        } else {
            let nsStream = try await client.query(
                "SELECT retention_days FROM strand.namespaces WHERE id = \(namespaceID)",
                logger: logger
            )
            var days = 30
            if let nsRow = try await nsStream.first(where: { _ in true }) {
                var col = nsRow.makeIterator()
                days = (try? col.next()?.decode(Int.self, context: .default)) ?? 30
            }
            effectiveAgeSeconds = days * 24 * 3600
        }
        let stream = try await client.query(
            """
            -- Each state clause uses its own terminal timestamp so the
            -- partial indexes (strand_tasks_completed_at_idx, etc.) can be
            -- used instead of scanning the full table.
            --
            -- IMPORTANT — parent-task guard:
            -- Never prune a child task (parent_task_id IS NOT NULL) while its
            -- parent workflow is still alive. Doing so would delete the child's
            -- task_completions row, which is the durable result store used by
            -- crash-recovery (_activate → loadCompletedChildActivities). Without
            -- that row, a post-crash replay would re-execute already-completed
            -- activities, causing duplicate side effects.
            --
            -- A child task is safe to prune when:
            --   (a) it has no parent (root task), OR
            --   (b) its parent no longer exists (was already pruned), OR
            --   (c) its parent is itself terminal — i.e. the whole workflow tree
            --       is done and the parent will be pruned in the same or a
            --       subsequent cycle.
            WITH to_delete AS (
                SELECT id FROM strand.tasks t
                WHERE namespace_id = \(namespaceID)
                  AND (\(queue)::text IS NULL OR queue = \(queue))
                  AND (
                        (state = 'COMPLETED'        AND completed_at < NOW() - \(effectiveAgeSeconds) * INTERVAL '1 second')
                     OR (state = 'CONTINUED_AS_NEW'  AND completed_at < NOW() - \(effectiveAgeSeconds) * INTERVAL '1 second')
                     OR (state = 'CANCELLED'         AND cancelled_at < NOW() - \(effectiveAgeSeconds) * INTERVAL '1 second')
                     OR (state = 'FAILED'            AND created_at   < NOW() - \(effectiveAgeSeconds) * INTERVAL '1 second')
                  )
                  AND (
                      -- Root task — safe to prune independently.
                      t.parent_task_id IS NULL
                      -- Parent no longer exists (was already pruned) — orphan cleanup.
                      OR NOT EXISTS (
                          SELECT 1 FROM strand.tasks parent
                          WHERE parent.id = t.parent_task_id
                      )
                      -- Parent is itself terminal — whole tree is done.
                      OR EXISTS (
                          SELECT 1 FROM strand.tasks parent
                          WHERE parent.id = t.parent_task_id
                            AND parent.state IN ('COMPLETED', 'CONTINUED_AS_NEW', 'FAILED', 'CANCELLED')
                      )
                  )
                LIMIT \(limit)
                FOR UPDATE SKIP LOCKED
            ),
            del_checkpoints AS (
                DELETE FROM strand.checkpoints WHERE task_id IN (SELECT id FROM to_delete)
            ),
            del_event_waits AS (
                DELETE FROM strand.event_waits WHERE task_id IN (SELECT id FROM to_delete)
            ),
            del_workflow_history AS (
                DELETE FROM strand.workflow_history WHERE task_id IN (SELECT id FROM to_delete)
            ),
            del_workflow_state AS (
                DELETE FROM strand.workflow_state WHERE task_id IN (SELECT id FROM to_delete)
            ),
            del_workflow_signals AS (
                DELETE FROM strand.workflow_signals WHERE task_id IN (SELECT id FROM to_delete)
            ),
            del_task_completions AS (
                DELETE FROM strand.task_completions WHERE task_id IN (SELECT id FROM to_delete)
            ),
            del_runs AS (
                DELETE FROM strand.runs WHERE task_id IN (SELECT id FROM to_delete)
            ),
            del_tasks AS (
                DELETE FROM strand.tasks WHERE id IN (SELECT id FROM to_delete)
                RETURNING id
            )
            SELECT COUNT(*) FROM del_tasks
            """,
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else { return 0 }
        var col = row.makeIterator()
        let count = try col.next()!.decode(Int.self, context: .default)
        if count > 0 {
            logger.debug(
                "cleanup removed \(count) terminal tasks",
                metadata: [
                    "strand.namespace": .string(namespaceID),
                    "strand.queue": .string(queue ?? "*"),
                    "strand.count": .stringConvertible(count),
                ]
            )
        }
        return count
    }

    /// Deletes events from `strand.events` older than `ageSeconds`.
    ///
    /// Events are append-only and have no FK to tasks, so they are never
    /// cascade-deleted by ``cleanupTasks``. Without explicit pruning they
    /// accumulate indefinitely.
    ///
    /// Deleting an event sets `emission_id` to NULL on any `strand.event_triggers`
    /// rows that reference it (via `ON DELETE SET NULL`). Those event_trigger
    /// rows are eventually cleaned up by ``cleanupTasks`` when their tasks are
    /// pruned.
    ///
    /// Returns the number of events deleted.
    package static func cleanupEvents(
        on client: PostgresClient,
        namespaceID: String,
        ageSeconds: Int?,
        limit: Int,
        logger: Logger
    ) async throws -> Int {
        let effectiveAgeSeconds: Int
        if let explicit = ageSeconds {
            effectiveAgeSeconds = explicit
        } else {
            let nsStream = try await client.query(
                "SELECT retention_days FROM strand.namespaces WHERE id = \(namespaceID)",
                logger: logger
            )
            var days = 30
            if let nsRow = try await nsStream.first(where: { _ in true }) {
                var col = nsRow.makeIterator()
                days = (try? col.next()?.decode(Int.self, context: .default)) ?? 30
            }
            effectiveAgeSeconds = days * 24 * 3600
        }

        let stream = try await client.query(
            """
            WITH to_delete AS (
                SELECT id FROM strand.events
                WHERE namespace_id = \(namespaceID)
                  AND created_at < NOW() - \(effectiveAgeSeconds) * INTERVAL '1 second'
                ORDER BY created_at ASC
                LIMIT \(limit)
                FOR UPDATE SKIP LOCKED
            )
            DELETE FROM strand.events
            WHERE id IN (SELECT id FROM to_delete)
            RETURNING id
            """,
            logger: logger
        )
        var count = 0
        for try await _ in stream { count += 1 }
        if count > 0 {
            logger.debug(
                "cleanup removed \(count) events",
                metadata: [
                    "strand.namespace": .string(namespaceID),
                    "strand.count": .stringConvertible(count),
                ]
            )
        }
        return count
    }
}

// MARK: - Workflows (distinct task definitions)

/// Summary of a unique workflow (task) definition seen in `strand.tasks`.
package struct WorkflowRow: Sendable {
    package let name: String
    package let kind: TaskKind
    package let totalRuns: Int
    /// Tasks currently executing (state = RUNNING).
    package let runningRuns: Int
    /// Tasks in queue (PENDING, SLEEPING, or WAITING).
    package let queuedRuns: Int
    package let failedRuns: Int
    package let lastSeenAt: Date?
    /// Average wall-clock duration of completed root runs in milliseconds.
    package let avgDurationMs: Double?
}

extension WorkflowRow {
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        name = try col.next()!.decode(String.self, context: .default)
        kind = try col.next()!.decode(TaskKind.self, context: .default)
        totalRuns = try col.next()!.decode(Int.self, context: .default)
        runningRuns = try col.next()!.decode(Int.self, context: .default)
        queuedRuns = try col.next()!.decode(Int.self, context: .default)
        failedRuns = try col.next()!.decode(Int.self, context: .default)
        lastSeenAt = try col.next()!.decode(Date?.self, context: .default)
        avgDurationMs = try col.next()!.decode(Double?.self, context: .default)
    }
}

extension ManagementQueries {
    /// Returns one row per distinct `(name, kind)` where `parent_task_id IS NULL`.
    ///
    /// - Parameter kind: Filter to a specific kind, or `nil` for all kinds.
    ///   Callers must always be explicit — there is no default.
    package static func listTaskDefinitions(
        on client: PostgresClient,
        namespaceID: String,
        kind: TaskKind?,
        logger: Logger
    ) async throws -> [WorkflowRow] {
        let stream = try await client.query(
            """
            SELECT
              name,
              kind,
              COUNT(*)                                                                            AS total,
              COUNT(*) FILTER (WHERE state = 'RUNNING')                                         AS running,
              COUNT(*) FILTER (WHERE state IN ('PENDING','SLEEPING','WAITING'))                  AS queued,
              COUNT(*) FILTER (WHERE state = 'FAILED')                                          AS failed,
              MAX(created_at)                                                                    AS last_seen_at,
              -- Postgres 14+ changed EXTRACT() to return NUMERIC for interval args.
              -- Cast to float8 immediately so AVG(float8) = float8, which
              -- PostgresNIO decodes as Swift Double.
              AVG(
                EXTRACT(EPOCH FROM (completed_at - created_at))::float8 * 1000
              ) FILTER (WHERE state = 'COMPLETED' AND completed_at IS NOT NULL)                 AS avg_duration_ms
            FROM strand.tasks
            WHERE namespace_id = \(namespaceID)
              AND (\(kind)::text IS NULL OR kind = \(kind))
              AND parent_task_id IS NULL
            GROUP BY name, kind
            ORDER BY last_seen_at DESC NULLS LAST, name ASC, kind ASC
            """,
            logger: logger
        )
        var rows: [WorkflowRow] = []
        for try await row in stream { rows.append(try WorkflowRow(row: row)) }
        return rows
    }
}

extension ManagementQueries {
    /// Returns tasks spawned by `parentTaskID` (i.e. activities launched by a workflow),
    /// ordered newest first.
    package static func listChildTasks(
        on client: PostgresClient,
        namespaceID: String,
        parentTaskID: UUID,
        cursor: UUID?,
        limit: Int,
        logger: Logger
    ) async throws -> CursorPage<TaskSummaryRow> {
        let fetchLimit = limit + 1
        let stream = try await client.query(
            """
            SELECT id, name, queue, state, attempt, created_at, first_run_at, completed_at,
                   kind, parent_task_id, scheduling_metadata, idempotency_key
            FROM strand.tasks
            WHERE namespace_id = \(namespaceID)
              AND parent_task_id = \(parentTaskID)
              AND (\(cursor)::uuid IS NULL OR id < \(cursor))
            ORDER BY id DESC
            LIMIT \(fetchLimit)
            """,
            logger: logger
        )
        var rows: [TaskSummaryRow] = []
        for try await row in stream { rows.append(try TaskSummaryRow(row: row)) }
        let hasMore = rows.count > limit
        if hasMore { rows.removeLast() }
        let nextCursor = hasMore ? rows.last?.id.uuidString : nil
        return CursorPage(items: rows, nextCursor: nextCursor)
    }
}

// MARK: - Workers

package struct WorkerRow: Sendable {
    package let workerID: String
    package let queue: String  // from strand.workers.queue
    package let concurrency: Int  // from strand.workers.concurrency
    package let runningTasks: Int  // from strand.workers.running
    package let completedRecently: Int  // from strand.runs JOIN
    package let startedAt: Date  // from strand.workers.started_at
    package let lastSeenAt: Date?  // from strand.workers.updated_at
    package let leaseExpiresAt: Date?  // from strand.runs JOIN
    package let sdkVersion: String?  // from strand.workers.sdk_version
}

extension WorkerRow {
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        workerID = try col.next()!.decode(String.self, context: .default)
        queue = try col.next()!.decode(String.self, context: .default)
        concurrency = try col.next()!.decode(Int.self, context: .default)
        runningTasks = try col.next()!.decode(Int.self, context: .default)
        completedRecently = try col.next()!.decode(Int.self, context: .default)
        startedAt = try col.next()!.decode(Date.self, context: .default)
        lastSeenAt = try col.next()!.decode(Date?.self, context: .default)
        leaseExpiresAt = try col.next()!.decode(Date?.self, context: .default)
        sdkVersion = try col.next()!.decode(String?.self, context: .default)
    }
}

/// One task row in a worker's recent-run history.
package struct WorkerTaskRow: Sendable {
    package let taskID: UUID
    package let taskName: String
    package let kind: TaskKind
    package let queue: String
    package let taskState: TaskState
    package let attempt: Int
    package let startedAt: Date?
    package let finishedAt: Date?
    package let failureBuffer: ByteBuffer?
}

extension WorkerTaskRow {
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        taskID = try col.next()!.decode(UUID.self, context: .default)
        taskName = try col.next()!.decode(String.self, context: .default)
        kind = try col.next()!.decode(TaskKind.self, context: .default)
        queue = try col.next()!.decode(String.self, context: .default)
        taskState = try col.next()!.decode(TaskState.self, context: .default)
        attempt = try col.next()!.decode(Int.self, context: .default)
        startedAt = try col.next()!.decode(Date?.self, context: .default)
        finishedAt = try col.next()!.decode(Date?.self, context: .default)
        failureBuffer = try col.next()!.decode(ByteBuffer?.self, context: .default)
    }
}

package struct DailyRunCountRow: Sendable {
    package let date: Date  // truncated to day (UTC)
    package let total: Int
    package let failed: Int
}

extension ManagementQueries {
    /// Returns daily run counts for a task definition over the last `days` days.
    /// Used by `GET /api/:namespace/task-definitions/:name/activity`.
    package static func taskDefinitionActivity(
        on client: PostgresClient,
        namespaceID: String,
        name: String,
        days: Int,
        logger: Logger
    ) async throws -> [DailyRunCountRow] {
        let cutoff = Date(timeIntervalSinceNow: -Double(days) * 86_400)
        let stream = try await client.query(
            """
            SELECT
                DATE_TRUNC('day', created_at) AS date,
                COUNT(*)::int                                              AS total,
                COUNT(*) FILTER (WHERE state = 'FAILED')::int             AS failed
            FROM strand.tasks
            WHERE namespace_id = \(namespaceID)
              AND name = \(name)
              AND parent_task_id IS NULL
              AND created_at >= \(cutoff)
            GROUP BY DATE_TRUNC('day', created_at)
            ORDER BY date ASC
            """,
            logger: logger
        )
        var rows: [DailyRunCountRow] = []
        for try await row in stream {
            var col = row.makeIterator()
            let date = try col.next()!.decode(Date.self, context: .default)
            let total = try col.next()!.decode(Int.self, context: .default)
            let failed = try col.next()!.decode(Int.self, context: .default)
            rows.append(DailyRunCountRow(date: date, total: total, failed: failed))
        }
        return rows
    }
}

extension ManagementQueries {
    /// Returns worker summaries sourced from `strand.workers` (live heartbeat rows),
    /// LEFT JOIN `strand.runs` for `completedRecently` and `leaseExpiresAt`.
    package static func listWorkers(
        on client: PostgresClient,
        namespaceID: String,
        logger: Logger
    ) async throws -> [WorkerRow] {
        let stream = try await client.query(
            """
            SELECT
              w.id              AS worker_id,
              w.queue,
              w.concurrency,
              w.running         AS running_tasks,
              COALESCE(r.completed_recently, 0) AS completed_recently,
              w.started_at,
              w.updated_at      AS last_seen_at,
              r.lease_expires_at,
              w.sdk_version
            FROM strand.workers w
            LEFT JOIN (
              SELECT
                worker_id,
                COUNT(*) FILTER (WHERE state IN ('COMPLETED','FAILED','CANCELLED')
                                   AND finished_at > NOW() - INTERVAL '5 minutes') AS completed_recently,
                MAX(lease_expires_at) FILTER (WHERE state = 'RUNNING') AS lease_expires_at
              FROM strand.runs
              WHERE namespace_id = \(namespaceID)
                AND worker_id IS NOT NULL
                AND (state = 'RUNNING'
                  OR (state IN ('COMPLETED','FAILED','CANCELLED')
                      AND finished_at > NOW() - INTERVAL '5 minutes'))
              GROUP BY worker_id
            ) r ON r.worker_id = w.id
            WHERE w.namespace_id = \(namespaceID)
            ORDER BY w.running DESC, w.updated_at DESC
            """,
            logger: logger
        )
        var rows: [WorkerRow] = []
        for try await row in stream { rows.append(try WorkerRow(row: row)) }
        return rows
    }

    /// Returns the summary row for one worker plus its 50 most recent task runs.
    /// Returns `nil` when the worker has no row in `strand.workers`.
    package static func getWorkerDetail(
        on client: PostgresClient,
        namespaceID: String,
        workerID: String,
        logger: Logger
    ) async throws -> (summary: WorkerRow?, recentTasks: [WorkerTaskRow]) {
        // Summary — same shape as listWorkers but filtered to one worker.
        let summaryStream = try await client.query(
            """
            SELECT
              w.id              AS worker_id,
              w.queue,
              w.concurrency,
              w.running         AS running_tasks,
              COALESCE(r.completed_recently, 0) AS completed_recently,
              w.started_at,
              w.updated_at      AS last_seen_at,
              r.lease_expires_at,
              w.sdk_version
            FROM strand.workers w
            LEFT JOIN (
              SELECT
                worker_id,
                COUNT(*) FILTER (WHERE state IN ('COMPLETED','FAILED','CANCELLED')
                                   AND finished_at > NOW() - INTERVAL '5 minutes') AS completed_recently,
                MAX(lease_expires_at) FILTER (WHERE state = 'RUNNING') AS lease_expires_at
              FROM strand.runs
              WHERE namespace_id = \(namespaceID)
                AND worker_id    = \(workerID)
                AND (state = 'RUNNING'
                  OR (state IN ('COMPLETED','FAILED','CANCELLED')
                      AND finished_at > NOW() - INTERVAL '5 minutes'))
              GROUP BY worker_id
            ) r ON r.worker_id = w.id
            WHERE w.namespace_id = \(namespaceID)
              AND w.id           = \(workerID)
            """,
            logger: logger
        )
        let summary = try await summaryStream.first(where: { _ in true }).map {
            try WorkerRow(row: $0)
        }

        // Recent task runs — join tasks so we have name/kind/queue/state.
        let taskStream = try await client.query(
            """
            SELECT t.id, t.name, t.kind, t.queue, t.state,
                   r.attempt, r.started_at, r.finished_at, r.failure_reason
            FROM strand.runs r
            JOIN strand.tasks t ON t.id = r.task_id
            WHERE r.namespace_id = \(namespaceID)
              AND r.worker_id    = \(workerID)
            ORDER BY r.started_at DESC NULLS LAST
            LIMIT 50
            """,
            logger: logger
        )
        var tasks: [WorkerTaskRow] = []
        for try await row in taskStream { tasks.append(try WorkerTaskRow(row: row)) }
        return (summary: summary, recentTasks: tasks)
    }
}

extension ManagementQueries {
    /// Returns one `(name, kind)` pair per distinct task name across the
    /// namespace, including child tasks (no parent_task_id filter).
    ///
    /// Used by the dashboard metrics page to badge task names with W/A
    /// regardless of whether they are root or child tasks.
    ///
    /// - Parameter limit: Maximum number of distinct task names to return.
    ///   Callers that need more should paginate using `listTasks` with a name cursor.
    package static func listTaskKinds(
        on client: PostgresClient,
        namespaceID: String,
        limit: Int,
        logger: Logger
    ) async throws -> [(name: String, kind: TaskKind)] {
        let stream = try await client.query(
            """
            SELECT DISTINCT ON (name) name, kind
            FROM strand.tasks
            WHERE namespace_id = \(namespaceID)
            ORDER BY name, kind
            LIMIT \(limit)
            """,
            logger: logger
        )
        var results: [(name: String, kind: TaskKind)] = []
        for try await row in stream {
            var col = row.makeIterator()
            let name = try col.next()!.decode(String.self, context: .default)
            let kind = try col.next()!.decode(TaskKind.self, context: .default)
            results.append((name: name, kind: kind))
        }
        return results
    }
}

extension ManagementQueries {
    /// Returns up to `limit` workflows currently suspended in `ctx.waitForEvent(eventName)`
    /// on the given queue, ordered by wait registration time (oldest first).
    /// Used by the dashboard "Waiting for this event" panel.
    package static func listEventWaiters(
        on client: PostgresClient,
        namespaceID: String,
        queue: String,
        eventName: String,
        limit: Int = 20,
        logger: Logger
    ) async throws -> [EventWaiterRow] {
        let stream = try await client.query(
            """
            SELECT ew.task_id, t.name, t.state, ew.seq_num, ew.timeout_at
            FROM   strand.event_waits ew
            JOIN   strand.tasks t
                   ON  t.id           = ew.task_id
                   AND t.namespace_id = \(namespaceID)
            WHERE  ew.namespace_id = \(namespaceID)
              AND  ew.queue        = \(queue)
              AND  ew.event_name   = \(eventName)
              AND  ew.event_name IS NOT NULL
            ORDER  BY ew.created_at
            LIMIT  \(limit)
            """,
            logger: logger
        )
        var rows: [EventWaiterRow] = []
        for try await row in stream { rows.append(try EventWaiterRow(row: row)) }
        return rows
    }
}

// MARK: - OLAP latency types

/// Row from the OLAP latency-percentiles query. All durations in milliseconds.
package struct OLAPLatencyRow: Sendable {
    package let taskName: String
    package let count: Int
    package let p50Ms: Double?
    package let p95Ms: Double?
    package let p99Ms: Double?
    package let minMs: Double?
    package let maxMs: Double?
}

/// One time-bucketed row from the OLAP latency time-series query.
package struct OLAPBucketRow: Sendable {
    package let bucket: Date
    package let taskName: String
    package let count: Int
    package let p50Ms: Double?
    package let p95Ms: Double?
}

extension ManagementQueries {

    /// Exact p50/p95/p99/min/max latency per task name from `strand.trace_spans`
    /// using `PERCENTILE_CONT`. Rows are ordered by execution count descending.
    /// The `hours` parameter controls the lookback window; `limit` caps the number
    /// of task names returned (default 50, capped at 500).
    ///
    /// Backed by `strand_trace_spans_latency_idx` (migration 004).
    package static func latencyPercentiles(
        on client: PostgresClient,
        namespaceID: String,
        hours: Int,
        limit: Int = 50,
        logger: Logger
    ) async throws -> [OLAPLatencyRow] {
        let safeLimit = min(max(limit, 1), 500)  // clamp: 1 … 500
        let cutoff = Date(timeIntervalSinceNow: -Double(hours) * 3600)

        let stream = try await client.query(
            """
            SELECT
              name AS task_name,
              COUNT(*)::integer AS count,
              PERCENTILE_CONT(0.50) WITHIN GROUP (
                ORDER BY EXTRACT(EPOCH FROM (finished_at - started_at))::double precision * 1000
              ) AS p50_ms,
              PERCENTILE_CONT(0.95) WITHIN GROUP (
                ORDER BY EXTRACT(EPOCH FROM (finished_at - started_at))::double precision * 1000
              ) AS p95_ms,
              PERCENTILE_CONT(0.99) WITHIN GROUP (
                ORDER BY EXTRACT(EPOCH FROM (finished_at - started_at))::double precision * 1000
              ) AS p99_ms,
              MIN(EXTRACT(EPOCH FROM (finished_at - started_at))::double precision * 1000) AS min_ms,
              MAX(EXTRACT(EPOCH FROM (finished_at - started_at))::double precision * 1000) AS max_ms
            FROM strand.trace_spans
            WHERE namespace_id = \(namespaceID)
              AND kind IN ('WORKFLOW', 'ACTIVITY')
              AND state = 'COMPLETED'
              AND started_at IS NOT NULL
              AND finished_at IS NOT NULL
              AND finished_at >= \(cutoff)
            GROUP BY name
            ORDER BY count DESC
            LIMIT \(safeLimit)
            """,
            logger: logger
        )
        var rows: [OLAPLatencyRow] = []
        for try await row in stream {
            var col = row.makeIterator()
            let taskName = try col.next()!.decode(String.self, context: .default)
            let count = try col.next()!.decode(Int.self, context: .default)
            let p50 = try col.next()!.decode(Double?.self, context: .default)
            let p95 = try col.next()!.decode(Double?.self, context: .default)
            let p99 = try col.next()!.decode(Double?.self, context: .default)
            let minMs = try col.next()!.decode(Double?.self, context: .default)
            let maxMs = try col.next()!.decode(Double?.self, context: .default)
            rows.append(
                OLAPLatencyRow(
                    taskName: taskName,
                    count: count,
                    p50Ms: p50,
                    p95Ms: p95,
                    p99Ms: p99,
                    minMs: minMs,
                    maxMs: maxMs
                )
            )
        }
        return rows
    }

    /// Time-bucketed p50/p95 latency from `strand.trace_spans`.
    /// Granularity: minute (`hours <= 1`), hour (`hours > 1`).
    /// Optional `taskName` filter limits results to a single task definition.
    ///
    /// Backed by `strand_trace_spans_latency_idx` (migration 004).
    package static func latencyTimeSeries(
        on client: PostgresClient,
        namespaceID: String,
        hours: Int,
        taskName: String?,
        logger: Logger
    ) async throws -> [OLAPBucketRow] {
        let cutoff = Date(timeIntervalSinceNow: -Double(hours) * 3600)
        let query: PostgresQuery
        if hours <= 1 {
            if let taskName = taskName {
                query = """
                    SELECT DATE_TRUNC('minute', finished_at) AS bucket,
                           name AS task_name,
                           COUNT(*)::integer AS count,
                           PERCENTILE_CONT(0.50) WITHIN GROUP (
                             ORDER BY EXTRACT(EPOCH FROM (finished_at - started_at))::double precision * 1000
                           ) AS p50_ms,
                           PERCENTILE_CONT(0.95) WITHIN GROUP (
                             ORDER BY EXTRACT(EPOCH FROM (finished_at - started_at))::double precision * 1000
                           ) AS p95_ms
                    FROM strand.trace_spans
                    WHERE namespace_id = \(namespaceID)
                      AND kind IN ('WORKFLOW', 'ACTIVITY')
                      AND state = 'COMPLETED'
                      AND started_at IS NOT NULL
                      AND finished_at IS NOT NULL
                      AND finished_at >= \(cutoff)
                      AND name = \(taskName)
                    GROUP BY 1, 2
                    ORDER BY 1
                    """
            } else {
                query = """
                    SELECT DATE_TRUNC('minute', finished_at) AS bucket,
                           name AS task_name,
                           COUNT(*)::integer AS count,
                           PERCENTILE_CONT(0.50) WITHIN GROUP (
                             ORDER BY EXTRACT(EPOCH FROM (finished_at - started_at))::double precision * 1000
                           ) AS p50_ms,
                           PERCENTILE_CONT(0.95) WITHIN GROUP (
                             ORDER BY EXTRACT(EPOCH FROM (finished_at - started_at))::double precision * 1000
                           ) AS p95_ms
                    FROM strand.trace_spans
                    WHERE namespace_id = \(namespaceID)
                      AND kind IN ('WORKFLOW', 'ACTIVITY')
                      AND state = 'COMPLETED'
                      AND started_at IS NOT NULL
                      AND finished_at IS NOT NULL
                      AND finished_at >= \(cutoff)
                    GROUP BY 1, 2
                    ORDER BY 1
                    """
            }
        } else {
            if let taskName = taskName {
                query = """
                    SELECT DATE_TRUNC('hour', finished_at) AS bucket,
                           name AS task_name,
                           COUNT(*)::integer AS count,
                           PERCENTILE_CONT(0.50) WITHIN GROUP (
                             ORDER BY EXTRACT(EPOCH FROM (finished_at - started_at))::double precision * 1000
                           ) AS p50_ms,
                           PERCENTILE_CONT(0.95) WITHIN GROUP (
                             ORDER BY EXTRACT(EPOCH FROM (finished_at - started_at))::double precision * 1000
                           ) AS p95_ms
                    FROM strand.trace_spans
                    WHERE namespace_id = \(namespaceID)
                      AND kind IN ('WORKFLOW', 'ACTIVITY')
                      AND state = 'COMPLETED'
                      AND started_at IS NOT NULL
                      AND finished_at IS NOT NULL
                      AND finished_at >= \(cutoff)
                      AND name = \(taskName)
                    GROUP BY 1, 2
                    ORDER BY 1
                    """
            } else {
                query = """
                    SELECT DATE_TRUNC('hour', finished_at) AS bucket,
                           name AS task_name,
                           COUNT(*)::integer AS count,
                           PERCENTILE_CONT(0.50) WITHIN GROUP (
                             ORDER BY EXTRACT(EPOCH FROM (finished_at - started_at))::double precision * 1000
                           ) AS p50_ms,
                           PERCENTILE_CONT(0.95) WITHIN GROUP (
                             ORDER BY EXTRACT(EPOCH FROM (finished_at - started_at))::double precision * 1000
                           ) AS p95_ms
                    FROM strand.trace_spans
                    WHERE namespace_id = \(namespaceID)
                      AND kind IN ('WORKFLOW', 'ACTIVITY')
                      AND state = 'COMPLETED'
                      AND started_at IS NOT NULL
                      AND finished_at IS NOT NULL
                      AND finished_at >= \(cutoff)
                    GROUP BY 1, 2
                    ORDER BY 1
                    """
            }
        }
        let stream = try await client.query(query, logger: logger)
        var rows: [OLAPBucketRow] = []
        for try await row in stream {
            var col = row.makeIterator()
            let bucket = try col.next()!.decode(Date.self, context: .default)
            let name = try col.next()!.decode(String.self, context: .default)
            let count = try col.next()!.decode(Int.self, context: .default)
            let p50 = try col.next()!.decode(Double?.self, context: .default)
            let p95 = try col.next()!.decode(Double?.self, context: .default)
            rows.append(OLAPBucketRow(bucket: bucket, taskName: name, count: count, p50Ms: p50, p95Ms: p95))
        }
        return rows
    }
}
