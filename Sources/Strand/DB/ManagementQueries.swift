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
        payloadBuffer = try col.next()!.decode(ByteBuffer?.self, context: .default)
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
              COUNT(t.id) FILTER (WHERE t.state = 'PENDING')    AS pending,
              COUNT(t.id) FILTER (WHERE t.state = 'RUNNING')    AS running,
              COUNT(t.id) FILTER (WHERE t.state = 'SLEEPING')   AS sleeping,
              COUNT(t.id) FILTER (WHERE t.state = 'WAITING')    AS waiting,
              COUNT(t.id) FILTER (WHERE t.state = 'COMPLETED')  AS completed,
              COUNT(t.id) FILTER (WHERE t.state = 'FAILED')     AS failed,
              COUNT(t.id) FILTER (WHERE t.state = 'CANCELLED')  AS cancelled,
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

    /// Represents a real workflow step (WAIT / SLEEP / SIGNAL / EMIT) that is
    /// stored in the history log rather than as a separate `strand.tasks` row.
    package struct ExecutionHistorySpanRow: Sendable {
        /// The workflow task this span belongs to. Used to link the span
        /// back to the workflow in the trace inspector ("View task" navigation).
        package let workflowTaskID: UUID
        package let spanKind: WorkflowSpanKind  // WAIT | SLEEP | SIGNAL | EMIT
        package let name: String  // event name, signal name, or duration label
        /// Sequence number from `strand.workflow_history`. Used to compute a
        /// deterministic span ID so the UI does not flicker on polling re-renders.
        package let seqNum: Int
        package let startedAt: Date
        package let endedAt: Date?  // nil while still suspended / sleeping
        package let state: WorkflowSpanState
        package let emissionID: UUID?  // only for WAIT spans: links to strand.events
        /// Raw JSON payload received when the waitForEvent resolved (nil on timeout or
        /// if the wait is still open). Sourced from `strand.checkpoints`.
        package let receivedPayload: ByteBuffer?
    }

    // ── Parse event_data helpers ──────────────────────────────────────────
    private static func eventName(from buf: ByteBuffer?) -> String? {
        guard let b = buf else { return nil }
        return (try? JSON.decode(WorkflowStateQueries.NamedEventData.self, from: b))?.eventName
    }

    private static func signalName(from buf: ByteBuffer?) -> String? {
        guard let b = buf else { return nil }
        return (try? JSON.decode(WorkflowStateQueries.SignalReceivedData.self, from: b))?.name
    }

    /// Derives execution history spans from `strand.workflow_history` for all given
    /// workflow task IDs.
    ///
    /// Pairs complementary history events (TIMER_STARTED+TIMER_FIRED,
    /// EVENT_WAIT_STARTED+EVENT_RECEIVED) into duration spans and promotes
    /// point-in-time events (SIGNAL_RECEIVED, EVENT_EMITTED) into instant spans.
    /// For resolved WAIT spans, looks up `emission_id` from `strand.event_triggers`
    /// so the trace inspector can link back to the specific event that woke the run.
    package static func executionHistorySpansForTrace(
        on client: PostgresClient,
        namespaceID: String,
        workflowTaskIDs: [UUID],
        logger: Logger
    ) async throws -> [ExecutionHistorySpanRow] {
        guard !workflowTaskIDs.isEmpty else { return [] }

        // ── 1. Fetch relevant history events ────────────────────────────────────
        let histStream = try await client.query(
            """
            SELECT wh.task_id, wh.seq, wh.event_type, wh.event_data, wh.created_at
            FROM   strand.workflow_history wh
            WHERE  wh.task_id    = ANY(\(workflowTaskIDs))
              AND  wh.event_type IN (
                    'EVENT_WAIT_STARTED', 'EVENT_RECEIVED', 'EVENT_WAIT_TIMED_OUT',
                    'TIMER_STARTED',      'TIMER_FIRED',
                    'SIGNAL_RECEIVED',    'EVENT_EMITTED',
                    'CONDITION_WAITING',  'CONDITION_MET',  'CONDITION_TIMED_OUT'
                   )
            ORDER  BY wh.task_id, wh.seq
            """,
            logger: logger
        )

        // Collect events grouped by task_id, preserving seq order.
        struct HEvt {
            let seq: Int
            let eventType: WorkflowStateQueries.HistoryEventType
            let eventData: ByteBuffer?
            let createdAt: Date
        }
        var byTask: [UUID: [HEvt]] = [:]
        for try await row in histStream {
            var col = row.makeIterator()
            let taskID = try col.next()!.decode(UUID.self, context: .default)
            let seq = try col.next()!.decode(Int.self, context: .default)
            let rawType = try col.next()!.decode(String.self, context: .default)
            let eventData = try col.next()!.decode(ByteBuffer?.self, context: .default)
            let createdAt = try col.next()!.decode(Date.self, context: .default)
            guard let eventType = WorkflowStateQueries.HistoryEventType(rawValue: rawType) else { continue }
            byTask[taskID, default: []].append(
                HEvt(
                    seq: seq,
                    eventType: eventType,
                    eventData: eventData,
                    createdAt: createdAt
                )
            )
        }

        // ── 2. Fetch emission IDs for resolved WAIT spans ────────────────────────
        // Key: (taskID, eventName) → emissionID
        var emissionMap: [UUID: [String: UUID]] = [:]
        let etStream = try await client.query(
            """
            SELECT et.task_id, et.event_name, et.emission_id
            FROM   strand.event_triggers et
            WHERE  et.task_id     = ANY(\(workflowTaskIDs))
              AND  et.emission_id IS NOT NULL
            """,
            logger: logger
        )
        for try await row in etStream {
            var col = row.makeIterator()
            let taskID = try col.next()!.decode(UUID.self, context: .default)
            let eventName = try col.next()!.decode(String.self, context: .default)
            let emissionID = try col.next()!.decode(UUID?.self, context: .default)
            if let emissionID { emissionMap[taskID, default: [:]][eventName] = emissionID }
        }

        // ── 3. Fetch waitForEvent checkpoints (received payloads only) ─────────────────
        // Checkpoints hold the actual event payload for resolved EVENT_RECEIVED spans.
        // Timed-out waits are now detected exclusively via EVENT_WAIT_TIMED_OUT history rows.
        var waitPayloads: [UUID: [String: ByteBuffer]] = [:]
        let wfPrefix = "waitForEvent:"
        let cpStream = try await client.query(
            """
            SELECT DISTINCT ON (r.task_id, c.name)
                   r.task_id, c.name, c.state
            FROM   strand.checkpoints c
            JOIN   strand.runs r ON r.id = c.run_id
            WHERE  r.task_id = ANY(\(workflowTaskIDs))
              AND  c.name LIKE 'waitForEvent:%'
            ORDER  BY r.task_id, c.name, r.attempt DESC
            """,
            logger: logger
        )
        for try await row in cpStream {
            var col = row.makeIterator()
            let taskID = try col.next()!.decode(UUID.self, context: .default)
            let cpName = try col.next()!.decode(String.self, context: .default)
            let cpState = try col.next()!.decode(ByteBuffer?.self, context: .default)
            guard cpName.hasPrefix(wfPrefix), let buf = cpState else { continue }
            let eName = String(cpName.dropFirst(wfPrefix.count))
            // Only store actual payloads — TimeoutSentinel rows are no longer needed
            // here because EVENT_WAIT_TIMED_OUT in workflow_history is the source of truth.
            if !TimeoutSentinel.detect(in: buf) {
                waitPayloads[taskID, default: [:]][eName] = buf
            }
        }

        // ── 5. Pair events and emit ExecutionHistorySpanRows ─────────────────
        var results: [ExecutionHistorySpanRow] = []

        for (taskID, events) in byTask {
            var i = 0
            while i < events.count {
                let evt = events[i]
                switch evt.eventType {

                case .timerStarted:
                    let durationMs =
                        evt.eventData
                        .flatMap { try? JSON.decode(WorkflowStateQueries.TimerStartedData.self, from: $0) }
                        .map(\.durationMs) ?? 0
                    let label = ManagementQueries.sleepLabel(durationMs: durationMs)
                    // Find the next TIMER_FIRED for this task (seq > N).
                    if let endIdx = events[(i + 1)...].firstIndex(where: { $0.eventType == .timerFired }) {
                        results.append(
                            ExecutionHistorySpanRow(
                                workflowTaskID: taskID,
                                spanKind: .sleep,
                                name: label,
                                seqNum: evt.seq,
                                startedAt: evt.createdAt,
                                endedAt: events[endIdx].createdAt,
                                state: .completed,
                                emissionID: nil,
                                receivedPayload: nil
                            )
                        )
                        i = endIdx + 1
                        continue
                    } else {
                        results.append(
                            ExecutionHistorySpanRow(
                                workflowTaskID: taskID,
                                spanKind: .sleep,
                                name: label,
                                seqNum: evt.seq,
                                startedAt: evt.createdAt,
                                endedAt: nil,
                                state: .waiting,
                                emissionID: nil,
                                receivedPayload: nil
                            )
                        )
                    }

                case .eventWaitStarted:
                    let eName = eventName(from: evt.eventData) ?? WorkflowSpanKind.wait.displayName
                    // First: EVENT_RECEIVED — event arrived successfully.
                    if let endIdx = events[(i + 1)...].firstIndex(where: {
                        $0.eventType == .eventReceived && eventName(from: $0.eventData) == eName
                    }) {
                        let emID = emissionMap[taskID]?[eName]
                        let receivedPayload = waitPayloads[taskID]?[eName]
                        results.append(
                            ExecutionHistorySpanRow(
                                workflowTaskID: taskID,
                                spanKind: .wait,
                                name: eName,
                                seqNum: evt.seq,
                                startedAt: evt.createdAt,
                                endedAt: events[endIdx].createdAt,
                                state: .completed,
                                emissionID: emID,
                                receivedPayload: receivedPayload
                            )
                        )
                        i = endIdx + 1
                        continue
                        // EVENT_WAIT_TIMED_OUT — exact end time recorded when the deadline fired.
                    } else if let endIdx = events[(i + 1)...].firstIndex(where: {
                        $0.eventType == .eventWaitTimedOut && eventName(from: $0.eventData) == eName
                    }) {
                        results.append(
                            ExecutionHistorySpanRow(
                                workflowTaskID: taskID,
                                spanKind: .wait,
                                name: eName,
                                seqNum: evt.seq,
                                startedAt: evt.createdAt,
                                endedAt: events[endIdx].createdAt,
                                state: .timedOut,
                                emissionID: nil,
                                receivedPayload: nil
                            )
                        )
                        i = endIdx + 1
                        continue
                    } else {
                        // No completion event found — wait is still open.
                        results.append(
                            ExecutionHistorySpanRow(
                                workflowTaskID: taskID,
                                spanKind: .wait,
                                name: eName,
                                seqNum: evt.seq,
                                startedAt: evt.createdAt,
                                endedAt: nil,
                                state: .waiting,
                                emissionID: nil,
                                receivedPayload: nil
                            )
                        )
                    }

                case .signalReceived:
                    let sName = signalName(from: evt.eventData) ?? WorkflowSpanKind.signal.displayName
                    results.append(
                        ExecutionHistorySpanRow(
                            workflowTaskID: taskID,
                            spanKind: .signal,
                            name: sName,
                            seqNum: evt.seq,
                            startedAt: evt.createdAt,
                            endedAt: evt.createdAt,
                            state: .completed,
                            emissionID: nil,
                            receivedPayload: nil
                        )
                    )

                case .eventEmitted:
                    let eName = eventName(from: evt.eventData) ?? WorkflowSpanKind.emit.displayName
                    results.append(
                        ExecutionHistorySpanRow(
                            workflowTaskID: taskID,
                            spanKind: .emit,
                            name: eName,
                            seqNum: evt.seq,
                            startedAt: evt.createdAt,
                            endedAt: evt.createdAt,
                            state: .completed,
                            emissionID: nil,
                            receivedPayload: nil
                        )
                    )

                case .conditionWaiting:
                    // Look ahead for the completion event, stepping over any intermediate
                    // CONDITION_WAITING re-parks (predicate still false after a signal).
                    if let endIdx = events[(i + 1)...].firstIndex(where: {
                        $0.eventType == .conditionMet || $0.eventType == .conditionTimedOut
                    }) {
                        results.append(
                            ExecutionHistorySpanRow(
                                workflowTaskID: taskID,
                                spanKind: .condition,
                                name: "condition",
                                seqNum: evt.seq,
                                startedAt: evt.createdAt,
                                endedAt: events[endIdx].createdAt,
                                state: events[endIdx].eventType == .conditionMet ? .completed : .timedOut,
                                emissionID: nil,
                                receivedPayload: nil
                            )
                        )
                        i = endIdx + 1
                        continue
                    } else {
                        // No completion found — still waiting or only re-parks remain.
                        results.append(
                            ExecutionHistorySpanRow(
                                workflowTaskID: taskID,
                                spanKind: .condition,
                                name: "condition",
                                seqNum: evt.seq,
                                startedAt: evt.createdAt,
                                endedAt: nil,
                                state: .waiting,
                                emissionID: nil,
                                receivedPayload: nil
                            )
                        )
                        // Skip subsequent CONDITION_WAITING entries — they are re-parks of
                        // the same condition call and do not produce separate spans.
                        while i + 1 < events.count && events[i + 1].eventType == .conditionWaiting {
                            i += 1
                        }
                    }

                case .conditionMet, .conditionTimedOut:
                    break  // consumed by the .conditionWaiting look-ahead above

                default:
                    break
                }
                i += 1
            }
        }

        return results
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
            WITH to_delete AS (
                SELECT id FROM strand.tasks
                WHERE namespace_id = \(namespaceID)
                  AND (\(queue)::text IS NULL OR queue = \(queue))
                  AND (
                        (state = 'COMPLETED' AND completed_at < NOW() - \(effectiveAgeSeconds) * INTERVAL '1 second')
                     OR (state = 'CANCELLED' AND cancelled_at < NOW() - \(effectiveAgeSeconds) * INTERVAL '1 second')
                     OR (state = 'FAILED'    AND created_at   < NOW() - \(effectiveAgeSeconds) * INTERVAL '1 second')
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
              r.lease_expires_at
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
              r.lease_expires_at
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
