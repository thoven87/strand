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
    package let completedAt: Date?
    /// `.workflow` or `.activity` — distinguishes root orchestrators from child leaf tasks.
    package let kind: TaskKind
    /// Non-nil for activity tasks spawned by a workflow.
    package let parentTaskId: UUID?
    /// Schedule name that triggered this task, or `nil` if not scheduled.
    package let scheduleName: String?
}

extension TaskSummaryRow {
    /// Column order: id, name, queue, state, attempt, created_at, completed_at, kind, parent_task_id, headers
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        id = try col.next()!.decode(UUID.self, context: .default)
        name = try col.next()!.decode(String.self, context: .default)
        queue = try col.next()!.decode(String.self, context: .default)
        state = try col.next()!.decode(TaskState.self, context: .default)
        attempt = try col.next()!.decode(Int.self, context: .default)
        createdAt = try col.next()!.decode(Date.self, context: .default)
        completedAt = try col.next()!.decode(Date?.self, context: .default)
        kind = try col.next()!.decode(TaskKind.self, context: .default)
        parentTaskId = try col.next()!.decode(UUID?.self, context: .default)
        let headersBuffer = try col.next()!.decode(ByteBuffer?.self, context: .default)
        let h = headersBuffer.flatMap { try? JSON.decode([String: String].self, from: $0) } ?? [:]
        scheduleName = SchedulingMetadata.from(headers: h)?.scheduledBy
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
        let headersBuffer = try col.next()!.decode(ByteBuffer?.self, context: .default)
        let h = headersBuffer.flatMap { try? JSON.decode([String: String].self, from: $0) } ?? [:]
        schedulingMetadata = SchedulingMetadata.from(headers: h)
    }
}

/// Run summary row returned by ``ManagementQueries/listRuns``.
package struct RunSummaryRow: Sendable {
    package let id: UUID
    package let attempt: Int
    package let state: TaskState
    package let workerID: String?
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
    package let sleeping: Int
    package let completed: Int
    package let failed: Int
    package let cancelled: Int
    /// Whether the queue is administratively paused (requires is_paused column migration).
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
        completed = try col.next()!.decode(Int.self, context: .default)
        failed = try col.next()!.decode(Int.self, context: .default)
        cancelled = try col.next()!.decode(Int.self, context: .default)
        isPaused = try col.next()!.decode(Bool.self, context: .default)
    }
}

/// Event row returned by ``ManagementQueries/listEvents``.
package struct EventRow: Sendable {
    package let name: String
    package let payloadBuffer: ByteBuffer?
    package let createdAt: Date
    package let queue: String
}

extension EventRow {
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        name = try col.next()!.decode(String.self, context: .default)
        payloadBuffer = try col.next()!.decode(ByteBuffer?.self, context: .default)
        createdAt = try col.next()!.decode(Date.self, context: .default)
        queue = try col.next()!.decode(String.self, context: .default)
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
        logger: Logger
    ) async throws -> [QueueStatsRow] {
        let stream = try await client.query(
            """
            SELECT
              q.name,
              q.created_at,
              COUNT(t.id) FILTER (WHERE t.state = 'PENDING')                    AS pending,
              COUNT(t.id) FILTER (WHERE t.state = 'RUNNING')                    AS running,
              COUNT(t.id) FILTER (WHERE t.state IN ('SLEEPING', 'WAITING'))     AS sleeping,
              COUNT(t.id) FILTER (WHERE t.state = 'COMPLETED')                  AS completed,
              COUNT(t.id) FILTER (WHERE t.state = 'FAILED')                     AS failed,
              COUNT(t.id) FILTER (WHERE t.state = 'CANCELLED')                  AS cancelled,
              q.is_paused
            FROM strand.queues q
            LEFT JOIN strand.tasks t ON t.queue = q.name AND t.namespace_id = q.namespace_id
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
        logger: Logger
    ) async throws -> QueueStatsRow? {
        let stream = try await client.query(
            """
            SELECT
              q.name,
              q.created_at,
              COUNT(t.id) FILTER (WHERE t.state = 'PENDING')                    AS pending,
              COUNT(t.id) FILTER (WHERE t.state = 'RUNNING')                    AS running,
              COUNT(t.id) FILTER (WHERE t.state IN ('SLEEPING', 'WAITING'))     AS sleeping,
              COUNT(t.id) FILTER (WHERE t.state = 'COMPLETED')                  AS completed,
              COUNT(t.id) FILTER (WHERE t.state = 'FAILED')                     AS failed,
              COUNT(t.id) FILTER (WHERE t.state = 'CANCELLED')                  AS cancelled,
              q.is_paused
            FROM strand.queues q
            LEFT JOIN strand.tasks t ON t.queue = q.name AND t.namespace_id = q.namespace_id
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
        cursor: UUID?,
        limit: Int,
        logger: Logger
    ) async throws -> CursorPage<TaskSummaryRow> {
        let fetchLimit = limit + 1  // fetch one extra to detect a next page
        let stream = try await client.query(
            """
            SELECT id, name, queue, state, attempt, created_at, completed_at, kind, parent_task_id, headers
            FROM strand.tasks
            WHERE namespace_id = \(namespaceID)
              AND (\(queue)::text IS NULL OR queue = \(queue))
              AND (\(state)::text IS NULL OR state = \(state))
              AND (\(name)::text IS NULL OR name = \(name))
              AND (\(kind)::text IS NULL OR kind = \(kind))
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
                   kind, parent_task_id, headers
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
            SELECT id, attempt, state, worker_id, started_at, finished_at,
                   lease_expires_at, created_at, failure_reason
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
        queue: String,
        cursor: Date?,
        limit: Int,
        logger: Logger
    ) async throws -> CursorPage<EventRow> {
        let fetchLimit = limit + 1
        let stream = try await client.query(
            """
            SELECT name, payload, created_at, queue
            FROM strand.events
            WHERE queue = \(queue)
              AND name NOT LIKE '$strand:%'
              AND (\(cursor)::timestamptz IS NULL OR created_at < \(cursor))
            ORDER BY created_at DESC
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
        queue: String?,
        cursor: Date?,
        limit: Int,
        logger: Logger
    ) async throws -> CursorPage<EventRow> {
        let fetchLimit = limit + 1
        let stream = try await client.query(
            """
            SELECT name, payload, created_at, queue
            FROM strand.events
            WHERE (\(queue)::text IS NULL OR queue = \(queue))
              AND name NOT LIKE '$strand:%'
              AND (\(cursor)::timestamptz IS NULL OR created_at < \(cursor))
            ORDER BY created_at DESC
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
            WITH to_delete AS (
                SELECT id FROM strand.tasks
                WHERE namespace_id = \(namespaceID)
                  AND (\(queue)::text IS NULL OR queue = \(queue))
                  AND state IN ('COMPLETED', 'FAILED', 'CANCELLED')
                  AND created_at < NOW() - \(effectiveAgeSeconds) * INTERVAL '1 second'
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
        logger.info(
            "cleanup removed \(count) terminal tasks",
            metadata: [
                "strand.namespace": .string(namespaceID),
                "strand.queue": .string(queue ?? "*"),
                "strand.count": .stringConvertible(count),
            ]
        )
        return count
    }
}

// MARK: - Workflows (distinct task definitions)

/// Summary of a unique workflow (task) definition seen in `strand.tasks`.
package struct WorkflowRow: Sendable {
    package let name: String
    package let totalRuns: Int
    package let activeRuns: Int
    package let failedRuns: Int
    package let lastSeenAt: Date?
}

extension WorkflowRow {
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        name = try col.next()!.decode(String.self, context: .default)
        totalRuns = try col.next()!.decode(Int.self, context: .default)
        activeRuns = try col.next()!.decode(Int.self, context: .default)
        failedRuns = try col.next()!.decode(Int.self, context: .default)
        lastSeenAt = try col.next()!.decode(Date?.self, context: .default)
    }
}

extension ManagementQueries {
    /// Returns one row per distinct `strand.tasks.name` where `kind = 'WORKFLOW'`, with run counts.
    package static func listWorkflows(
        on client: PostgresClient,
        namespaceID: String,
        logger: Logger
    ) async throws -> [WorkflowRow] {
        let stream = try await client.query(
            """
            SELECT
              name,
              COUNT(*)                                                          AS total,
              SUM(CASE WHEN state IN ('PENDING','RUNNING','SLEEPING','WAITING') THEN 1 ELSE 0 END) AS active,
              SUM(CASE WHEN state = 'FAILED'    THEN 1 ELSE 0 END)             AS failed,
              MAX(created_at)                                                   AS last_seen_at
            FROM strand.tasks
            WHERE namespace_id = \(namespaceID)
              AND kind = \(TaskKind.workflow)
            GROUP BY name
            ORDER BY last_seen_at DESC NULLS LAST, name ASC
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
            SELECT id, name, queue, state, attempt, created_at, completed_at, kind, parent_task_id, headers
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
    package let runningTasks: Int
    package let completedRecently: Int  // completed/failed in last 5 min
    package let lastSeenAt: Date?
    package let leaseExpiresAt: Date?
}

extension WorkerRow {
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        workerID = try col.next()!.decode(String.self, context: .default)
        runningTasks = try col.next()!.decode(Int.self, context: .default)
        completedRecently = try col.next()!.decode(Int.self, context: .default)
        lastSeenAt = try col.next()!.decode(Date?.self, context: .default)
        leaseExpiresAt = try col.next()!.decode(Date?.self, context: .default)
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

extension ManagementQueries {
    /// Returns worker summaries: currently-running workers + any that were
    /// active in the last 5 minutes.
    package static func listWorkers(
        on client: PostgresClient,
        namespaceID: String,
        logger: Logger
    ) async throws -> [WorkerRow] {
        let stream = try await client.query(
            """
            SELECT
              worker_id,
              COUNT(*)       FILTER (WHERE state = 'RUNNING')                       AS running_tasks,
              COUNT(*)       FILTER (WHERE state IN ('COMPLETED','FAILED','CANCELLED')
                                      AND finished_at > NOW() - INTERVAL '5 minutes') AS completed_recently,
              MAX(GREATEST(COALESCE(started_at, created_at),
                           COALESCE(finished_at, created_at)))                      AS last_seen_at,
              MAX(lease_expires_at) FILTER (WHERE state = 'RUNNING')               AS lease_expires_at
            FROM strand.runs
            WHERE namespace_id = \(namespaceID)
              AND worker_id IS NOT NULL
              AND (state = 'RUNNING'
                OR (state IN ('COMPLETED','FAILED','CANCELLED')
                    AND finished_at > NOW() - INTERVAL '5 minutes'))
            GROUP BY worker_id
            ORDER BY running_tasks DESC, last_seen_at DESC
            """,
            logger: logger
        )
        var rows: [WorkerRow] = []
        for try await row in stream { rows.append(try WorkerRow(row: row)) }
        return rows
    }

    /// Returns the summary row for one worker plus its 50 most recent task runs.
    /// Returns `nil` when the worker hasn't been seen in the last 24 hours.
    package static func getWorkerDetail(
        on client: PostgresClient,
        namespaceID: String,
        workerID: String,
        logger: Logger
    ) async throws -> (summary: WorkerRow?, recentTasks: [WorkerTaskRow]) {
        // Summary — same aggregation as listWorkers but for one worker.
        let summaryStream = try await client.query(
            """
            SELECT
              worker_id,
              COUNT(*)       FILTER (WHERE state = 'RUNNING')                       AS running_tasks,
              COUNT(*)       FILTER (WHERE state IN ('COMPLETED','FAILED','CANCELLED')
                                      AND finished_at > NOW() - INTERVAL '5 minutes') AS completed_recently,
              MAX(GREATEST(COALESCE(started_at, created_at),
                           COALESCE(finished_at, created_at)))                      AS last_seen_at,
              MAX(lease_expires_at) FILTER (WHERE state = 'RUNNING')               AS lease_expires_at
            FROM strand.runs
            WHERE namespace_id = \(namespaceID)
              AND worker_id    = \(workerID)
              AND (state = 'RUNNING'
                OR started_at > NOW() - INTERVAL '24 hours')
            GROUP BY worker_id
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

// MARK: - Trace

/// A flattened row returned by the recursive trace CTE.
/// Callers (StrandServer route handlers) build a tree from the flat list.
package struct TraceSpanRow: Sendable {
    package let id: UUID
    package let name: String
    package let kind: TaskKind
    package let state: TaskState
    package let parentTaskID: UUID?
    package let createdAt: Date
    package let attempt: Int
    package let maxAttempts: Int?
    package let depth: Int
    // from latest run (nil when never claimed)
    package let startedAt: Date?
    package let finishedAt: Date?
    package let workerID: String?
    package let failureBuffer: ByteBuffer?  // failure_reason (raw JSON BYTEA)
}

extension ManagementQueries {
    /// Runs a recursive CTE rooted at `rootTaskID` and returns all spans
    /// in breadth-first order (depth ASC, created_at ASC). Returns an empty
    /// array when the root task does not exist or belongs to a different namespace.
    package static func traceTask(
        on client: PostgresClient,
        namespaceID: String,
        rootTaskID: UUID,
        logger: Logger
    ) async throws -> [TraceSpanRow] {
        let stream = try await client.query(
            """
            WITH RECURSIVE tree AS (
              SELECT t.id, t.name, t.kind, t.state, t.parent_task_id,
                     t.created_at, t.attempt, t.max_attempts,
                     0 AS depth
              FROM strand.tasks t
              WHERE t.namespace_id = \(namespaceID) AND t.id = \(rootTaskID)
              UNION ALL
              SELECT t.id, t.name, t.kind, t.state, t.parent_task_id,
                     t.created_at, t.attempt, t.max_attempts,
                     tree.depth + 1
              FROM strand.tasks t
              JOIN tree ON t.parent_task_id = tree.id
              WHERE t.namespace_id = \(namespaceID) AND tree.depth < 50
            ),
            latest_runs AS (
              SELECT DISTINCT ON (task_id)
                task_id, started_at, finished_at, worker_id, failure_reason
              FROM strand.runs
              WHERE task_id IN (SELECT id FROM tree)
              ORDER BY task_id, attempt DESC
            )
            SELECT tree.id, tree.name, tree.kind, tree.state, tree.parent_task_id,
                   tree.created_at, tree.attempt, tree.max_attempts,
                   tree.depth,
                   lr.started_at, lr.finished_at, lr.worker_id, lr.failure_reason
            FROM tree
            LEFT JOIN latest_runs lr ON lr.task_id = tree.id
            ORDER BY tree.depth, tree.created_at
            """,
            logger: logger
        )
        var rows: [TraceSpanRow] = []
        for try await row in stream {
            var col = row.makeIterator()
            rows.append(
                TraceSpanRow(
                    id: try col.next()!.decode(UUID.self, context: .default),
                    name: try col.next()!.decode(String.self, context: .default),
                    kind: try col.next()!.decode(TaskKind.self, context: .default),
                    state: try col.next()!.decode(TaskState.self, context: .default),
                    parentTaskID: try col.next()!.decode(UUID?.self, context: .default),
                    createdAt: try col.next()!.decode(Date.self, context: .default),
                    attempt: try col.next()!.decode(Int.self, context: .default),
                    maxAttempts: try col.next()!.decode(Int?.self, context: .default),
                    depth: try col.next()!.decode(Int.self, context: .default),
                    startedAt: try col.next()!.decode(Date?.self, context: .default),
                    finishedAt: try col.next()!.decode(Date?.self, context: .default),
                    workerID: try col.next()!.decode(String?.self, context: .default),
                    failureBuffer: try col.next()!.decode(ByteBuffer?.self, context: .default)
                )
            )
        }
        return rows
    }
}
