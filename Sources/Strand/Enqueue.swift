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
    public var fairnessWeight: Double

    /// Rate limit for this task.
    ///
    /// When non-nil, each enqueue atomically claims a time slot and sets the
    /// run's `available_at` accordingly.  `nil` (the default) means no rate
    /// limiting.  See ``RateLimit`` for full documentation.
    public var rateLimit: RateLimit?

    /// Human-readable description for this execution — shown in the Loom
    /// dashboard.  Stored in the `strand.tasks.description` column; `nil` stores nothing.
    public var description: String?

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
        fairnessWeight: Double = 1.0,
        rateLimit: RateLimit? = nil,
        description: String? = nil
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
        self.rateLimit = rateLimit
        self.description = description
    }
}

// MARK: - EnqueueResult

/// Result returned after successfully enqueuing a task.
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

// MARK: - WorkflowSpanKind

/// All possible span kinds in a workflow trace.
/// Named `WorkflowSpanKind` (not `SpanKind`) to avoid a naming conflict with
/// `swift-distributed-tracing`'s `SpanKind` (.client / .server / .producer / .consumer).
///
/// `workflow` and `activity` come from actual `strand.tasks` rows.
/// The rest are synthesised from `strand.workflow_history` events by the
/// trace-building route in StrandServer.
public enum WorkflowSpanKind: String, Sendable, Codable, CaseIterable {
    case workflow = "WORKFLOW"
    case activity = "ACTIVITY"
    case wait = "WAIT"  // ctx.waitForEvent(...)
    case sleep = "SLEEP"  // ctx.sleep(for:)
    case signal = "SIGNAL"  // handleSignal delivery
    case update = "UPDATE"  // @WorkflowUpdate delivery
    case emit = "EMIT"  // ctx.emitEvent(...)
    case condition = "CONDITION"  // ctx.condition(...) — reserved for future use
}

extension WorkflowSpanKind {
    /// Converts a `TaskKind` (DB column value) to the corresponding `WorkflowSpanKind`.
    public init(taskKind: TaskKind) {
        switch taskKind {
        case .workflow: self = .workflow
        case .activity: self = .activity
        }
    }

    /// Human-readable lowercase label for use in trace span names.
    /// Used as a fallback when the event name or signal name cannot be decoded
    /// from the history event payload.
    var displayName: String { rawValue.lowercased() }
}

// MARK: - WorkflowSpanKind PostgresCodable

extension WorkflowSpanKind: PostgresCodable {
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
        guard let kind = WorkflowSpanKind(rawValue: raw) else {
            throw PostgresDecodingError.Code.typeMismatch
        }
        self = kind
    }
}

// MARK: - WorkflowSpanState

/// State of a span in the workflow trace view.
/// Used by both real task spans (derived from `TaskState`) and
/// execution history spans (WAIT / SLEEP / SIGNAL / EMIT).
public enum WorkflowSpanState: String, Sendable, Codable {
    case pending = "PENDING"
    case running = "RUNNING"
    case waiting = "WAITING"
    case retrying = "RETRYING"
    case failed = "FAILED"
    case timedOut = "TIMED_OUT"
    case crashed = "CRASHED"
    case cancelled = "CANCELLED"
    case delayed = "DELAYED"
    case completed = "COMPLETED"
}

// MARK: - WorkflowSpanState PostgresCodable

extension WorkflowSpanState: PostgresCodable {
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
        guard let state = WorkflowSpanState(rawValue: raw) else {
            throw PostgresDecodingError.Code.typeMismatch
        }
        self = state
    }
}

// MARK: - Task result types

// MARK: - TaskState (internal scheduling state)

/// Internal run-level state used by `strand.runs` and `strand.tasks`.
///
/// This enum is `package`-only — it is never exposed to library consumers.
/// All public API surfaces use ``TaskStatus`` instead, which collapses the
/// granular scheduling states (SLEEPING, WAITING) into a single RUNNING value.
package enum TaskState: String, Sendable, Codable {
    case pending = "PENDING"
    case running = "RUNNING"
    /// Workflow activation completed and released its slot; suspended on a
    /// timer or timed event wait.  The run auto-wakes when `available_at` elapses.
    case sleeping = "SLEEPING"
    /// Workflow activation completed and released its slot; suspended waiting
    /// for child activities/workflows to complete or for an untimed event.
    case waiting = "WAITING"
    /// Workflow is paused by an explicit pause operation.
    case paused = "PAUSED"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
    /// The workflow called `context.continueAsNew(input:)` — a new task was
    /// enqueued with a fresh input and this task’s execution is complete.
    case continuedAsNew = "CONTINUED_AS_NEW"

    /// Returns `true` for states from which a task will never transition again.
    package var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .continuedAsNew: return true
        case .pending, .running, .sleeping, .waiting, .paused: return false
        }
    }

    /// Projects this internal scheduling state to the public ``TaskStatus``.
    ///
    /// The mapping is intentionally lossy: `sleeping` and `waiting` both become
    /// `.running` because from a user’s perspective the task is still in progress.
    package var taskStatus: TaskStatus {
        switch self {
        case .pending: return .queued
        case .running, .sleeping, .waiting: return .running
        case .paused: return .paused
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .continuedAsNew: return .continuedAsNew
        }
    }
}

// MARK: - TaskStatus (public API state)

/// The observable status of a task execution — what the public API and Loom
/// dashboard expose to callers.
///
/// Unlike the internal ``TaskState``, this enum does not distinguish *why* a
/// workflow is suspended between activations.  Whether a workflow is sleeping
/// on a timer, waiting for an activity, or waiting for a named event, the
/// public status is always `running`.
public enum TaskStatus: String, Sendable, Codable {
    /// Not yet claimed by a worker (was PENDING internally).
    case queued = "QUEUED"
    /// Being executed or suspended between activations (RUNNING / SLEEPING / WAITING).
    case running = "RUNNING"
    /// Explicitly paused; will not be scheduled until resumed.
    case paused = "PAUSED"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
    case continuedAsNew = "CONTINUED_AS_NEW"

    /// Returns `true` for terminal states.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .continuedAsNew: return true
        case .queued, .running, .paused: return false
        }
    }

    /// The internal `TaskState` values that correspond to this status.
    ///
    /// `RUNNING` expands to the three scheduling sub-states; `QUEUED` maps to
    /// `PENDING`; all others map 1-to-1.  Use with `= ANY($1)` so a single
    /// parameterised query covers every expansion case without string-building.
    package var dbStates: [TaskState] {
        switch self {
        case .running: return [.running, .sleeping, .waiting]
        case .queued: return [.pending]
        case .paused: return [.paused]
        case .completed: return [.completed]
        case .failed: return [.failed]
        case .cancelled: return [.cancelled]
        case .continuedAsNew: return [.continuedAsNew]
        }
    }
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

extension TaskPriority: PostgresCodable {
    public static var psqlType: PostgresDataType { .int8 }
    public static var psqlFormat: PostgresFormat { .binary }

    public func encode<E: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<E>
    ) throws {
        // Delegate to Int's encoding so the wire format matches what
        // PostgresNIO uses for bare Int parameters (bigint / int8).
        // Postgres implicitly casts int8 → int4 for the INTEGER column.
        rawValue.encode(into: &byteBuffer, context: context)
    }

    public init<D: PostgresJSONDecoder>(
        from byteBuffer: inout ByteBuffer,
        type: PostgresDataType,
        format: PostgresFormat,
        context: PostgresDecodingContext<D>
    ) throws {
        let raw = try Int(from: &byteBuffer, type: type, format: format, context: context)
        guard let priority = TaskPriority(rawValue: raw) else {
            throw PostgresDecodingError.Code.typeMismatch
        }
        self = priority
    }
}

// TaskState PostgresCodable — package-only, used by internal DB queries.
// PostgresNonThrowingEncodable: our encode only calls rawValue.encode which never throws.
// PostgresArrayEncodable: allows [TaskState] to be interpolated as = ANY($1) in queries.
extension TaskState: PostgresNonThrowingEncodable {}
extension TaskState: PostgresArrayEncodable {
    package static var psqlArrayType: PostgresDataType { .textArray }
}
extension TaskState: PostgresCodable {
    package static var psqlType: PostgresDataType { .text }
    package static var psqlFormat: PostgresFormat { .binary }

    // Non-throwing: rawValue.encode never throws for String.
    // The non-throwing signature satisfies both PostgresEncodable (which allows throws)
    // and PostgresNonThrowingEncodable (which requires no throws).
    package func encode<E: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<E>
    ) {
        rawValue.encode(into: &byteBuffer, context: context)
    }

    package init<D: PostgresJSONDecoder>(
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

// TaskStatus PostgresCodable — public, used by public API response decoding.
extension TaskStatus: PostgresCodable {
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
        guard let status = TaskStatus(rawValue: raw) else {
            throw PostgresDecodingError.Code.typeMismatch
        }
        self = status
    }
}

// MARK: - LocalActivityOptions

/// Options for in-process local activity execution.
///
/// Configuration options for local activity execution within a workflow.
///
/// Local activities run in-process on the same worker that schedules them —
/// no queue round-trip, no independent retry. These options control the
/// execution budget and retry behaviour.
public struct LocalActivityOptions: Sendable {
    /// Maximum time for each individual execution attempt.
    ///
    /// If the activity has not returned within this window the attempt is
    /// cancelled and (if retries remain) retried. `nil` means no per-attempt cap.
    public var timeout: Duration?

    /// Maximum total wall-clock time from scheduling to permanent completion
    /// across all retry attempts.
    ///
    /// `nil` means no total budget.
    public var maxDuration: Duration?

    /// Maximum execution attempts before the activity is marked permanently failed.
    ///
    /// `nil` = no attempt cap (retries indefinitely on failure within `maxDuration`).
    public var maxAttempts: Int?

    /// Retry policy on failure. `nil` uses the worker default (exponential backoff).
    public var retryStrategy: RetryStrategy?

    /// How the workflow handles cancellation of this local activity.
    ///
    /// Defaults to `.tryCancel`.
    public var cancellationType: ActivityCancellationType

    public init(
        timeout: Duration? = nil,
        maxDuration: Duration? = nil,
        maxAttempts: Int? = nil,
        retryStrategy: RetryStrategy? = nil,
        cancellationType: ActivityCancellationType = .tryCancel
    ) {
        self.timeout = timeout
        self.maxDuration = maxDuration
        self.maxAttempts = maxAttempts
        self.retryStrategy = retryStrategy
        self.cancellationType = cancellationType
    }
}

public struct TaskFailure: Sendable, Codable {
    public let errorType: String
    public let message: String
    public let traceback: String?
}

/// Snapshot of a task's terminal (or current) state.
public struct TaskResultSnapshot: Sendable, Codable {
    public let taskID: UUID
    public let state: TaskStatus
    /// Raw JSON string of the result value; `nil` if not yet completed.
    public let resultJSON: String?
    public let failure: TaskFailure?
    /// Decoded failure — populated from `strand.runs.failure_reason` by
    /// `StrandClient.taskSnapshot(from:)` when a DB row is decoded.  Used by
    /// `StrandClient.runActivity` to throw `A.Failure` directly without a
    /// second round of JSON decoding.
    ///
    /// Not part of the `Codable` representation: the failure IS durable in the
    /// DB, but this field is not serialised to JSON (e.g. over an HTTP API) and
    /// is set back to `nil` on `init(from decoder:)`.  External callers should
    /// read `TaskResultSnapshot.failure` instead.
    package let _activityFailure: ActivityFailure?

    // Codable only encodes the four public fields; _failureBuffer is runtime-only.
    private enum CodingKeys: String, CodingKey {
        case taskID, state, resultJSON, failure
    }

    /// Public memberwise initialiser (for external callers — no runtime failure data).
    public init(
        taskID: UUID,
        state: TaskStatus,
        resultJSON: String?,
        failure: TaskFailure?
    ) {
        self.taskID = taskID
        self.state = state
        self.resultJSON = resultJSON
        self.failure = failure
        self._activityFailure = nil
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.taskID = try c.decode(UUID.self, forKey: .taskID)
        self.state = try c.decode(TaskStatus.self, forKey: .state)
        self.resultJSON = try c.decodeIfPresent(String.self, forKey: .resultJSON)
        self.failure = try c.decodeIfPresent(TaskFailure.self, forKey: .failure)
        self._activityFailure = nil  // not in JSON wire format; see _activityFailure doc comment
    }

    /// Package-internal initialiser that carries the already-decoded `ActivityFailure`
    /// for typed-failure propagation in `StrandClient.runActivity`.
    package init(
        taskID: UUID,
        state: TaskStatus,
        resultJSON: String?,
        failure: TaskFailure?,
        activityFailure: ActivityFailure?
    ) {
        self.taskID = taskID
        self.state = state
        self.resultJSON = resultJSON
        self.failure = failure
        self._activityFailure = activityFailure
    }

    /// Decodes the result JSON into `T`.
    ///
    /// Prefer `StrandClient.awaitTaskResult(id:as:)` for the common async-polling
    /// pattern. Use this method when you already hold a `TaskResultSnapshot` and
    /// want to decode it synchronously without an additional network round-trip.
    public func decodeResult<T: Decodable>(as type: T.Type = T.self) throws -> T {
        guard let json = resultJSON else {
            throw StrandError.serialization(underlying: MissingResultError())
        }
        return try JSON.decode(type, from: json)
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
// MARK: - Version migration

/// The migration status for a ``WorkflowContext/version(changeID:)`` gate
/// across all workflows in a namespace.
///
/// Returned by ``StrandClient/migrationStatus(changeID:)``.
public struct MigrationStatus: Sendable {
    /// The changeID this status describes.
    public let changeID: String
    /// Number of in-flight workflows still on the old code path (`value = false`).
    /// When this reaches zero it is safe to remove the `else` branch.
    public let pendingCount: Int
    /// Number of in-flight workflows that have passed the gate on the new path.
    public let completedCount: Int
    /// `true` when no in-flight workflow is still on the old path — safe to
    /// delete the `else` branch in the next deploy.
    public var isSafeToRemove: Bool { pendingCount == 0 }
}

public struct RetryOptions: Codable, Sendable {
    /// Determines which descendant tasks are reset alongside the selected task.
    ///
    /// When you retry a workflow, child activities that previously ran are stored in
    /// `task_completions`. On replay, the workflow would normally fast-path those
    /// results — returning the old success *or* old failure without re-executing
    /// the activity. The mode controls which children have their `task_completions`
    /// entry deleted and a fresh PENDING run created, forcing re-execution.
    ///
    /// Activities that are NOT reset replay their cached result instantly.
    public enum Mode: String, Codable, Sendable {
        /// Reset only FAILED and CANCELLED descendants.
        ///
        /// The right default for most retries: re-run what failed, skip what
        /// already succeeded. Completed activities replay from cache; only
        /// failed/cancelled ones are given fresh PENDING runs.
        case failedOnly = "failed_only"

        /// Reset FAILED/CANCELLED descendants **and** any descendant created at
        /// or after the earliest failure point, even if it completed successfully.
        ///
        /// Use this when a failed task may have produced bad side-effects that
        /// contaminate later activities, making their “completed” results
        /// unreliable and worth discarding.
        case failedAndDependents = "failed_and_dependents"

        /// Reset **every** descendant regardless of state.
        ///
        /// Every child activity re-runs from scratch — no results are replayed
        /// from cache. Use this when you cannot trust any previously-completed
        /// result and want a full fresh execution.
        case all
    }

    public var mode: Mode
    /// When `true`, resets the attempt counter to 1 and clears stored failure
    /// reasons — a clean slate with the original `max_attempts` budget intact.
    /// Also propagates to descendant tasks: their attempt counters are reset to 1
    /// rather than bumped.
    ///
    /// When `false` (default), the attempt counter continues from where it
    /// left off and `max_attempts` is bumped by one to allow the next attempt.
    public var resetHistory: Bool

    public init(mode: Mode = .failedOnly, resetHistory: Bool = false) {
        self.mode = mode
        self.resetHistory = resetHistory
    }
}
