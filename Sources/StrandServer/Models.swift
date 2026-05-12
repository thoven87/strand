import Hummingbird
import NIOCore
import NIOFoundationCompat
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Shared response types

struct SchedulingInfoResponse: Codable, Sendable {
    let scheduleName: String?
    let scheduleId: String?
    let executionTime: Date
    let partitionTime: Date?
    /// ISO 8601 offset from the schedule pattern (e.g. "PT15M"). nil when offset is zero.
    let scheduleOffset: String?
}
extension SchedulingInfoResponse: ResponseCodable {}

struct QueueResponse: Codable, Sendable {
    let name: String
    let createdAt: Date
    let isPaused: Bool
    let stats: StatsBody

    struct StatsBody: Codable, Sendable {
        let pending: Int
        let running: Int
        /// Workflows suspended on a `ctx.sleep(for:)` timer.
        let sleeping: Int
        /// Workflows suspended waiting for an activity, child workflow, or named event.
        let waiting: Int
        let completed: Int
        let failed: Int
        let cancelled: Int
    }

    init(from row: QueueStatsRow) {
        name = row.name
        createdAt = row.createdAt
        isPaused = row.isPaused
        stats = StatsBody(
            pending: row.pending,
            running: row.running,
            sleeping: row.sleeping,
            waiting: row.waiting,
            completed: row.completed,
            failed: row.failed,
            cancelled: row.cancelled
        )
    }
}
extension QueueResponse: ResponseCodable {}

struct CursorPageResponse<T: Codable & Sendable>: Codable, Sendable {
    let items: [T]
    let nextCursor: String?
}
extension CursorPageResponse: ResponseCodable {}

struct TaskSummaryResponse: Codable, Sendable {
    let id: UUID
    let name: String
    let queue: String
    let state: String
    let attempt: Int
    let createdAt: Date
    let completedAt: Date?
    let firstRunAt: Date?
    /// `.workflow` or `.activity` — lets the UI distinguish root workflows from child activities.
    let kind: TaskKind
    /// UUID of the parent workflow task, or `null` for root tasks.
    let parentTaskId: UUID?
    /// Schedule name that triggered this task, or `null` if not scheduled.
    let scheduleName: String?
    /// Human-readable workflow ID — the value passed to ``WorkflowOptions/id`` at
    /// enqueue time, or the auto-generated `"WorkflowName-<ms>"` string.
    /// `nil` for activity tasks (spawned internally, not via `startWorkflow`).
    let workflowId: String?

    init(from row: TaskSummaryRow) {
        id = row.id
        name = row.name
        queue = row.queue
        state = row.state.rawValue
        attempt = row.attempt
        createdAt = row.createdAt
        completedAt = row.completedAt
        firstRunAt = row.firstRunAt
        kind = row.kind
        parentTaskId = row.parentTaskId
        scheduleName = row.scheduleName
        workflowId = row.workflowId
    }
}
extension TaskSummaryResponse: ResponseCodable {}

struct TaskDetailResponse: Codable, Sendable {
    let id: UUID
    let name: String
    let queue: String
    let params: String  // raw JSON
    let state: String
    let attempt: Int
    let maxAttempts: Int?
    let createdAt: Date
    let firstRunAt: Date?
    let completedAt: Date?
    let result: String?  // raw JSON
    let cancelledAt: Date?
    let kind: TaskKind
    let parentTaskId: UUID?
    /// Human-readable workflow ID. See ``TaskSummaryResponse/workflowId``.
    let workflowId: String?
    /// Scheduling metadata for tasks triggered by a schedule, or `null` if not scheduled.
    let scheduling: SchedulingInfoResponse?

    init(from row: TaskDetailRow) {
        id = row.id
        name = row.name
        queue = row.queue
        params = String(buffer: row.paramsBuffer)
        state = row.state.rawValue
        attempt = row.attempt
        maxAttempts = row.maxAttempts
        createdAt = row.createdAt
        firstRunAt = row.firstRunAt
        completedAt = row.completedAt
        result = row.resultBuffer.map { String(buffer: $0) }
        cancelledAt = row.cancelledAt
        kind = row.kind
        parentTaskId = row.parentTaskId
        workflowId = row.workflowId
        scheduling = row.schedulingMetadata.map {
            SchedulingInfoResponse(
                scheduleName: $0.scheduledBy,
                scheduleId: $0.scheduleId,
                executionTime: $0.executionTime,
                partitionTime: $0.partitionTime,
                scheduleOffset: $0.scheduleOffset
            )
        }
    }
}
extension TaskDetailResponse: ResponseCodable {}

struct RunResponse: Codable, Sendable {
    let id: UUID
    let attempt: Int
    let state: String
    let workerID: String?
    let startedAt: Date?
    let finishedAt: Date?
    let leaseExpiresAt: Date?
    let createdAt: Date
    let failureReason: String?  // raw JSON

    init(from row: RunSummaryRow) {
        id = row.id
        attempt = row.attempt
        state = row.state.rawValue
        workerID = row.workerID
        startedAt = row.startedAt
        finishedAt = row.finishedAt
        leaseExpiresAt = row.leaseExpiresAt
        createdAt = row.createdAt
        failureReason = row.failureBuffer.map { String(buffer: $0) }
    }
}
extension RunResponse: ResponseCodable {}

struct CheckpointResponse: Codable, Sendable {
    let seqNum: Int
    let name: String?  // optional debug label; nil when not provided at write time
    let state: String  // raw JSON
    init(from row: CheckpointRow) {
        seqNum = row.seqNum
        name = row.name
        state = String(buffer: row.stateBuffer)
    }
}
extension CheckpointResponse: ResponseCodable {}

struct EventResponse: Codable, Sendable {
    struct TriggeredTaskResponse: Codable, Sendable {
        let taskId: String
        let taskName: String
        let taskState: String
        let taskKind: String
    }
    let id: String  // emission UUID (lowercase) — new in append-only log
    let name: String
    let payload: String?  // raw JSON
    let createdAt: Date
    let queue: String
    let triggeredTasks: [TriggeredTaskResponse]
    init(from row: EventRow) {
        id = row.id.uuidString.lowercased()
        name = row.name
        payload = row.payloadBuffer.map { String(buffer: $0) }
        createdAt = row.createdAt
        queue = row.queue
        triggeredTasks = row.triggeredTasks.map {
            TriggeredTaskResponse(
                taskId: $0.taskId.uuidString,
                taskName: $0.taskName,
                taskState: $0.taskState,
                taskKind: $0.taskKind
            )
        }
    }
}
extension EventResponse: ResponseCodable {}

struct EventWaiterResponse: Codable, Sendable {
    let taskId: String  // UUID as lowercase string
    let taskName: String
    let taskState: String
    let seqNum: Int
    let timeoutAt: Date?

    init(from row: EventWaiterRow) {
        taskId = row.taskId.uuidString.lowercased()
        taskName = row.taskName
        taskState = row.taskState.rawValue
        seqNum = row.seqNum
        timeoutAt = row.timeoutAt
    }
}
extension EventWaiterResponse: ResponseCodable {}

/// Response returned by `GET /api/:namespace/tasks/:taskId/event-trigger`.
/// Links a workflow task back to the specific event emission that woke it.
struct EventTriggerResponse: Codable, Sendable {
    /// UUID of the specific `strand.events` row (emission) that woke this task.
    /// `nil` for tasks triggered before the append-only migration.
    let emissionId: String?
    let eventName: String
    let queue: String
    let triggeredAt: Date

    init(from row: EventTriggerRow) {
        emissionId = row.emissionID?.uuidString.lowercased()
        eventName = row.eventName
        queue = row.queue
        triggeredAt = row.triggeredAt
    }
}
extension EventTriggerResponse: ResponseCodable {}

struct SimpleResponse: Codable, Sendable {
    let message: String
    let id: String
}

/// One row per `(name, kind)` for root task definitions.
/// Returned by `GET /api/:namespace/task-definitions`.
struct TaskDefinitionResponse: Codable, Sendable {
    let name: String
    let kind: TaskKind
    let totalRuns: Int
    let runningRuns: Int
    let queuedRuns: Int
    let failedRuns: Int
    let lastSeenAt: Date?
    let avgDurationMs: Double?

    init(from row: WorkflowRow) {
        name = row.name
        kind = row.kind
        totalRuns = row.totalRuns
        runningRuns = row.runningRuns
        queuedRuns = row.queuedRuns
        failedRuns = row.failedRuns
        lastSeenAt = row.lastSeenAt
        avgDurationMs = row.avgDurationMs
    }
}
struct DailyRunCountResponse: Codable, Sendable {
    let date: Date
    let total: Int
    let failed: Int
}
extension DailyRunCountResponse: ResponseCodable {}

extension SimpleResponse: ResponseCodable {}

struct EnqueueResultResponse: Codable, Sendable {
    let taskID: UUID
    let runID: UUID
    let attempt: Int
    init(from r: EnqueueResult) {
        taskID = r.taskID
        runID = r.runID
        attempt = r.attempt
    }
}
extension EnqueueResultResponse: ResponseCodable {}

struct HistoryEventResponse: Codable, Sendable {
    let seq: Int
    let eventType: String
    let eventData: String?  // raw JSON string, nil if no data
    let createdAt: Date

    init(from row: WorkflowStateQueries.HistoryEventRow) {
        seq = row.seq
        eventType = row.eventType.rawValue  // decode from enum — was row.eventType directly
        eventData = row.eventData.map { String(buffer: $0) }
        createdAt = row.createdAt
    }
}
extension HistoryEventResponse: ResponseCodable {}

struct WorkflowStateResponse: Codable, Sendable {
    /// Raw JSON string of the serialised workflow struct. Clients can
    /// JSON.parse this to inspect individual fields.
    let state: String
}
extension WorkflowStateResponse: ResponseCodable {}

struct TraceSpanResponse: Codable, Sendable {
    /// Stable unique key for the span.
    /// Task spans use `task.id.uuidString`.
    /// Execution history spans use `"<workflowUUID>-<seqNum>"` — their natural
    /// composite identifier. `String` (not `UUID`) so both forms are representable.
    let id: String
    let name: String
    let kind: WorkflowSpanKind
    let state: WorkflowSpanState
    let startMs: Double
    let durationMs: Double
    let queuedMs: Double?
    let attempt: Int
    let maxAttempts: Int?
    let errorMessage: String?
    let workerID: String?
    let createdAt: Date
    let startedAt: Date?
    let completedAt: Date?
    /// Task to navigate to when the inspector’s "View task" button is tapped.
    /// `nil` for execution history spans that have no independent task row.
    let taskId: UUID?
    let children: [TraceSpanResponse]
    /// The `strand.events` emission that resolved this WAIT span, if known.
    let emissionId: UUID?
    /// Raw JSON payload received when a `waitForEvent` resolved (WAIT spans only).
    let eventPayload: String?
}
extension TraceSpanResponse: ResponseCodable {}

// MARK: - Worker detail

struct WorkerTaskResponse: Codable, Sendable {
    let taskID: UUID
    let taskName: String
    let kind: String
    let queue: String
    let state: String
    let attempt: Int
    let startedAt: Date?
    let finishedAt: Date?
    let durationMs: Double?
    let failureReason: String?  // raw JSON from runs.failure_reason

    init(from row: WorkerTaskRow) {
        taskID = row.taskID
        taskName = row.taskName
        kind = row.kind.rawValue
        queue = row.queue
        state = row.taskState.rawValue
        attempt = row.attempt
        startedAt = row.startedAt
        finishedAt = row.finishedAt
        failureReason = row.failureBuffer.map { String(buffer: $0) }
        if let s = row.startedAt, let f = row.finishedAt {
            durationMs = f.timeIntervalSince(s) * 1000
        } else {
            durationMs = nil
        }
    }
}
extension WorkerTaskResponse: ResponseCodable {}

struct WorkerDetailResponse: Codable, Sendable {
    let workerID: String
    let queue: String
    let concurrency: Int
    let runningTasks: Int
    let completedRecently: Int
    let startedAt: Date?
    let lastSeenAt: Date?
    let leaseExpiresAt: Date?
    let isHealthy: Bool
    let recentTasks: [WorkerTaskResponse]
}
extension WorkerDetailResponse: ResponseCodable {}

/// Per-task performance metrics sourced from the DDSketch broadcast.
/// Returned by `GET /api/:namespace/metrics/task/:taskName`.
struct TaskMetricsResponse: Codable, Sendable {
    let taskName: String
    /// Total completions in the broadcast window (across all queues).
    let completedCount: Int
    /// Total failures in the broadcast window (across all queues).
    let failedCount: Int
    /// p50 execution time in ms (nil when no data in broadcast window).
    let p50Ms: Double?
    /// p95 execution time in ms.
    let p95Ms: Double?
    /// p99 execution time in ms.
    let p99Ms: Double?
    /// p50 queue-wait time in ms (time from PENDING to claimed).
    let p50WaitMs: Double?
    /// p95 queue-wait time in ms.
    let p95WaitMs: Double?
    /// Executions per second across all queues in the last broadcast cycle.
    let ratePerSec: Double?
}
extension TaskMetricsResponse: ResponseCodable {}
