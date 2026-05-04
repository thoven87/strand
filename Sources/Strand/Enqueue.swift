import NIOCore
public import PostgresNIO

#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

// MARK: - TaskPriority

/// Task dispatch priority. Lower number = higher urgency.
///
/// Priority is evaluated before `available_at` (FIFO within the same priority).
///
/// ```swift
/// // Urgent payment — jump ahead of normal work:
/// try await client.enqueue(paymentTask, params: info,
///                           options: EnqueueOptions(priority: .high))
///
/// // Background report — run when nothing else is waiting:
/// try await client.enqueue(reportTask, params: req,
///                           options: EnqueueOptions(priority: .minimal))
/// ```
public enum TaskPriority: Int, Sendable, Codable, Comparable, CustomStringConvertible {
    case critical = 1  // highest — process before everything else
    case high = 2
    case normal = 3  // default
    case low = 4
    case minimal = 5  // lowest — background / batch tasks

    public static let `default` = TaskPriority.normal

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue  // p1 < p2 → p1 is MORE urgent
    }

    public var description: String {
        switch self {
        case .critical: return "critical"
        case .high: return "high"
        case .normal: return "normal"
        case .low: return "low"
        case .minimal: return "minimal"
        }
    }
}

// MARK: - EnqueueOptions

/// Options controlling how a task is enqueued.
public struct EnqueueOptions: Sendable {
    /// Route to a specific queue, overriding `TaskDefinition.queue`.
    public var queue: String?
    /// Maximum execution attempts. Falls back to `StrandOptions.defaultMaxAttempts`.
    public var maxAttempts: Int?
    /// Retry behaviour on failure. Falls back to `StrandOptions.defaultRetryStrategy`.
    public var retryStrategy: RetryStrategy?
    /// Key-value metadata carried with the task (e.g. trace IDs).
    public var headers: [String: String]
    /// Automatic cancellation policy.
    public var cancellation: CancellationPolicy?
    /// Deduplication key — if a task with this key already exists the
    /// existing task is returned instead of creating a new one.
    public var idempotencyKey: String?
    /// Dispatch priority. Default: `.normal` (3).
    public var priority: TaskPriority
    /// Earliest time the task may be claimed by a worker. `nil` = immediately.
    public var delayUntil: Date?
    /// Maximum total wall-clock time across all retry attempts.
    /// `nil` = no deadline.
    public var maxDuration: Duration?
    /// Optional fairness group key — e.g. a tenant ID or customer name (max 64 bytes).
    /// Tasks sharing a key are FIFO within that key; keys compete via weighted dispatch.
    public var fairnessKey: String?
    /// Relative throughput weight for this fairness key. Default `1.0`.
    /// A key with weight `5.0` is dispatched approximately 5× more often than a key with `1.0`.
    /// Only meaningful when multiple keys share the same queue and priority level.
    public var fairnessWeight: Float

    public init(
        queue: String? = nil,
        maxAttempts: Int? = nil,
        retryStrategy: RetryStrategy? = nil,
        headers: [String: String] = [:],
        cancellation: CancellationPolicy? = nil,
        idempotencyKey: String? = nil,
        priority: TaskPriority = .normal,
        delayUntil: Date? = nil,
        maxDuration: Duration? = nil,
        fairnessKey: String? = nil,
        fairnessWeight: Float = 1.0
    ) {
        self.queue = queue
        self.maxAttempts = maxAttempts
        self.retryStrategy = retryStrategy
        self.headers = headers
        self.cancellation = cancellation
        self.idempotencyKey = idempotencyKey
        self.priority = priority
        self.delayUntil = delayUntil
        self.maxDuration = maxDuration
        self.fairnessKey = fairnessKey
        self.fairnessWeight = max(fairnessWeight, 0.001)  // guard against divide-by-zero
    }
}

// MARK: - EnqueueResult

/// Result returned after successfully enqueuing a task.
/// `taskID` and `runID` are `UUID` — use `.uuidString` if a `String` is needed.
public struct EnqueueResult: Sendable {
    public let taskID: UUID
    public let runID: UUID
    public let attempt: Int
    public let createdAt: Date
}

// MARK: - RetryTaskOptions

/// Options for retrying an existing failed task.
public struct RetryTaskOptions: Sendable {
    public var maxAttempts: Int?
    /// When `true`, enqueue a brand-new task instead of retrying in place.
    public var enqueueNew: Bool

    public init(maxAttempts: Int? = nil, enqueueNew: Bool = false) {
        self.maxAttempts = maxAttempts
        self.enqueueNew = enqueueNew
    }
}

// MARK: - Task kind

/// Whether a task is a root workflow orchestrator or a leaf activity.
public enum TaskKind: String, Sendable, Codable, CaseIterable {
    case workflow = "WORKFLOW"
    case activity = "ACTIVITY"
}

extension TaskKind: PostgresCodable {
    public static var psqlType: PostgresDataType { .text }
    public static var psqlFormat: PostgresFormat { .binary }

    public func encode<E: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<E>
    ) throws {
        rawValue.encode(into: &byteBuffer, context: context)
    }

    public init<D: PostgresJSONDecoder>(
        from byteBuffer: inout ByteBuffer,
        type: PostgresDataType,
        format: PostgresFormat,
        context: PostgresDecodingContext<D>
    ) throws {
        let raw = try String(from: &byteBuffer, type: type, format: format, context: context)
        guard let kind = TaskKind(rawValue: raw) else {
            throw PostgresDecodingError.Code.typeMismatch
        }
        self = kind
    }
}

// MARK: - Task result types

public enum TaskState: String, Sendable, Codable {
    case pending = "PENDING"
    case running = "RUNNING"
    /// Workflow is suspended waiting for an activity or child workflow to
    /// complete, or for a timed sleep to elapse. No worker slot is held.
    case sleeping = "SLEEPING"
    /// Workflow is suspended waiting for a named event or signal.
    case waiting = "WAITING"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
    /// The workflow called `context.continueAsNew(input:)` — a new task was
    /// enqueued with a fresh input and this task's execution is complete.
    case continuedAsNew = "CONTINUED_AS_NEW"
}

extension ScheduleAccuracy: PostgresCodable {
    public static var psqlType: PostgresDataType { .text }
    public static var psqlFormat: PostgresFormat { .binary }

    public func encode<E: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<E>
    ) throws {
        dbString.encode(into: &byteBuffer, context: context)
    }

    public init<D: PostgresJSONDecoder>(
        from byteBuffer: inout ByteBuffer,
        type: PostgresDataType,
        format: PostgresFormat,
        context: PostgresDecodingContext<D>
    ) throws {
        // Unknown / future values fall back to .latest so old rows stay safe.
        let raw = try String(from: &byteBuffer, type: type, format: format, context: context)
        self.init(dbString: raw)
    }
}

extension TaskState: PostgresCodable {
    public static var psqlType: PostgresDataType { .text }
    public static var psqlFormat: PostgresFormat { .binary }

    public func encode<E: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<E>
    ) throws {
        rawValue.encode(into: &byteBuffer, context: context)
    }

    public init<D: PostgresJSONDecoder>(
        from byteBuffer: inout ByteBuffer,
        type: PostgresDataType,
        format: PostgresFormat,
        context: PostgresDecodingContext<D>
    ) throws {
        let raw = try String(from: &byteBuffer, type: type, format: format, context: context)
        guard let state = TaskState(rawValue: raw) else {
            throw PostgresDecodingError.Code.typeMismatch
        }
        self = state
    }
}

// MARK: - LocalActivityOptions

/// Options for in-process local activity execution.
///
/// Local activities run on the same worker process as the workflow, within the
/// same activation — no DB task row, no queue round-trip. If the activity
/// fails the whole activation fails (no independent retry).
public struct LocalActivityOptions: Sendable {
    public init() {}
}

public struct TaskFailure: Sendable, Codable {
    public let errorType: String
    public let message: String
    public let traceback: String?
}

/// Snapshot of a task's terminal (or current) state.
public struct TaskResultSnapshot: Sendable, Codable {
    public let taskID: UUID
    public let state: TaskState
    /// Raw JSON string of the result value; `nil` if not yet completed.
    public let resultJSON: String?
    public let failure: TaskFailure?

    /// Decodes the result JSON into `T`. Internal — use `awaitTaskResult(id:as:)` instead.
    func decodeResult<T: Decodable>(as type: T.Type = T.self) throws -> T {
        guard let json = resultJSON, let data = json.data(using: .utf8) else {
            throw StrandError.serialization(underlying: MissingResultError())
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

private struct MissingResultError: Error, CustomStringConvertible {
    var description: String { "TaskResultSnapshot has no result JSON" }
}

// MARK: - AwaitTaskResultOptions

public struct AwaitTaskResultOptions: Sendable {
    public var timeout: Duration?
    public init(timeout: Duration? = nil) { self.timeout = timeout }
}

// MARK: - AwaitEventOptions

public struct AwaitEventOptions: Sendable {
    /// Override the auto-generated checkpoint name for this wait.
    public var stepName: String?
    /// Positive = timeout after this duration.
    /// Negative = return immediately if the event is not already present.
    /// `nil` = wait forever.
    public var timeout: Duration?

    public init(stepName: String? = nil, timeout: Duration? = nil) {
        self.stepName = stepName
        self.timeout = timeout
    }
}

// MARK: - RetryOptions

/// Options controlling how a failed or cancelled task is retried.
public struct RetryOptions: Codable, Sendable {
    /// Which tasks to include in the retry.
    ///
    /// In Strand all three modes produce the same execution behaviour: the
    /// workflow is re-enqueued and its checkpoint-replay mechanism naturally
    /// skips already-completed activities. The mode is preserved in the
    /// request for API compatibility and future use.
    public enum Mode: String, Codable, Sendable {
        /// Re-enqueue every task in the workflow (default).
        case all
        /// Re-enqueue only tasks that are in a failed or cancelled state.
        case failedOnly = "failed_only"
        /// Re-enqueue failed tasks plus any downstream tasks that depend on them.
        case failedAndDependents = "failed_and_dependents"
    }

    public var mode: Mode
    /// When `true`, resets the attempt counter to 1 and clears stored failure
    /// reasons — a clean slate with the original `max_attempts` budget intact.
    /// When `false` (default), the attempt counter continues from where it
    /// left off and `max_attempts` is bumped by one to allow the next attempt.
    public var resetHistory: Bool

    public init(mode: Mode = .all, resetHistory: Bool = false) {
        self.mode = mode
        self.resetHistory = resetHistory
    }
}
