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
        let sleeping: Int
        let completed: Int
        let failed: Int
        let cancelled: Int
    }

    init(from row: QueueStatsRow) {
        name = row.name
        createdAt = row.createdAt
        isPaused = row.isPaused
        stats = StatsBody(
            pending: row.pending, running: row.running, sleeping: row.sleeping,
            completed: row.completed, failed: row.failed, cancelled: row.cancelled
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
    /// `.workflow` or `.activity` — lets the UI distinguish root workflows from child activities.
    let kind: TaskKind
    /// UUID of the parent workflow task, or `null` for root tasks.
    let parentTaskId: UUID?
    /// Schedule name that triggered this task, or `null` if not scheduled.
    let scheduleName: String?

    init(from row: TaskSummaryRow) {
        id = row.id
        name = row.name
        queue = row.queue
        state = row.state.rawValue
        attempt = row.attempt
        createdAt = row.createdAt
        completedAt = row.completedAt
        kind = row.kind
        parentTaskId = row.parentTaskId
        scheduleName = row.scheduleName
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
        scheduling = row.schedulingMetadata.map {
            SchedulingInfoResponse(
                scheduleName: $0.scheduledBy,
                scheduleId: $0.scheduleId,
                executionTime: $0.executionTime,
                partitionTime: $0.partitionTime,
                scheduleOffset: $0.scheduleOffset)
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
    let name: String
    let payload: String?  // raw JSON
    let createdAt: Date
    let queue: String
    init(from row: EventRow) {
        name = row.name
        payload = row.payloadBuffer.map { String(buffer: $0) }
        createdAt = row.createdAt
        queue = row.queue
    }
}
extension EventResponse: ResponseCodable {}

struct SimpleResponse: Codable, Sendable {
    let message: String
    let id: String
}
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
        eventType = row.eventType
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
    let id: UUID
    let name: String
    let kind: TaskKind  // "WORKFLOW" | "ACTIVITY"
    let state: String  // SpanState: "COMPLETED" | "RUNNING" | "WAITING" | "FAILED" | "CANCELLED" | "PENDING"
    let startMs: Double  // milliseconds from root task creation
    let durationMs: Double  // total span duration in ms
    let queuedMs: Double?  // ms from creation to worker claim (nil when never started)
    let attempt: Int
    let maxAttempts: Int?
    let errorMessage: String?  // raw failure JSON string, nil on success
    let workerID: String?
    let createdAt: Date
    let startedAt: Date?  // when worker claimed the run
    let completedAt: Date?  // when the run finished
    let taskId: UUID  // same as id — for UI deep-link convenience
    let children: [TraceSpanResponse]
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
    let runningTasks: Int
    let completedRecently: Int
    let lastSeenAt: Date?
    let leaseExpiresAt: Date?
    let isHealthy: Bool
    let recentTasks: [WorkerTaskResponse]
}
extension WorkerDetailResponse: ResponseCodable {}
