public import Logging  // Logger in ActivityContext.logger is public API
package import NIOCore  // ByteBuffer is part of the package-internal interface (_heartbeatImpl signature, init heartbeatDetailsBuffer)
public import PostgresNIO  // PostgresClient captured in heartbeatImpl closure; internal to _run(); public import required for PostgresCodable conformances
import Synchronization  // Mutex<Bool> for _ActivityCancellationFlag
import Tracing

#if canImport(FoundationEssentials)
public import FoundationEssentials  // UUID in ActivityContext.activityID, Date in ActivityOptions are public API
#else
public import Foundation
#endif

// MARK: - StrandVoid

/// A `Codable`, `Sendable` unit type used as the `Output` of an ``Activity``
/// that performs a side effect and returns no meaningful value.
///
/// ```swift
/// struct SendEmailActivity: Activity {
///     func run(input: EmailInput, context: ActivityContext) async throws -> StrandVoid {
///         try await smtp.send(to: input.address, body: input.body)
///         return .done
///     }
/// }
/// ```
public struct StrandVoid: Codable, Sendable, Equatable {
    /// The single shared instance. Return this from your activity handler.
    public static let done = StrandVoid()
    public init() {}
}

// MARK: - ActivityCancellationType

/// How the workflow handles cancellation propagation to an activity.
///
/// - `.tryCancel`: Send a cancellation request; the workflow continues without
///   waiting for the activity to acknowledge. Default.
/// - `.waitCancellationCompleted`: Send cancellation and wait for the activity
///   to finish before the workflow proceeds.
/// - `.abandon`: Do not send cancellation to this activity when the workflow
///   is cancelled. The activity runs to completion independently.
///
/// `.abandon` is enforced: activities with this type are excluded from the
/// `cancelTask` cascade when the parent workflow is cancelled or fails.
/// `.waitCancellationCompleted` propagation semantics are planned for a future
/// milestone.
public enum ActivityCancellationType: String, Sendable, Codable {
    case tryCancel = "TRY_CANCEL"
    case waitCancellationCompleted = "WAIT_CANCELLATION_COMPLETED"
    case abandon = "ABANDON"
}

extension ActivityCancellationType: PostgresCodable {
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
        guard let value = ActivityCancellationType(rawValue: raw) else {
            throw PostgresDecodingError.Code.typeMismatch
        }
        self = value
    }
}

// MARK: - RateLimit

/// Leaky-bucket rate limit for an activity.  When set, each enqueue atomically
/// claims a time slot; the run waits in PENDING until its slot arrives.
///
/// Only enforced when explicitly set — `nil` (the default) means no rate limit
/// and the activity is enqueued at full speed, exactly as without this option.
///
/// - `limit` / `period`: together define the slot interval.
///   `.init(limit: 10, period: .seconds(1))` → one slot every 100 ms.
///   `.init(limit: 2, period: .minutes(1))` → one slot every 30 s.
///
/// - `key`: optional partition key that gives each entity its own independent
///   bucket.  `nil` = one global bucket shared by all executions of this
///   activity type on this queue.  Use the workflow's own computed value —
///   there is no server-side expression language; Swift code is the expression.
///
/// ```swift
/// // Global: 10 payment activities per second across all customers
/// options: .init(rateLimit: .init(limit: 10, period: .seconds(1)))
///
/// // Per-customer: 2 enrichment calls per minute per customer ID
/// options: .init(
///     rateLimit: .init(limit: 2, period: .minutes(1), key: "customer:\(customerID)")
/// )
/// ```
public struct RateLimit: Sendable {
    /// Maximum executions allowed within `period`.
    public var limit: Double
    /// Time window over which `limit` applies. Default: `.seconds(1)`.
    public var period: Duration
    /// Optional partition key.  `nil` = one global bucket for this activity
    /// type on this queue.  A non-nil value gives each entity its own bucket.
    public var key: String?

    /// Returns `nil` when `limit` is not positive; no crash.
    public init?(limit: Double, period: Duration = .seconds(1), key: String? = nil) {
        guard limit > 0 else { return nil }
        self.limit = limit
        self.period = period
        self.key = key
    }

    // MARK: - Internal

    /// Slot-allocation parameters for the `strand.rate_limit_slots` SQL.
    ///
    /// - Parameter activityName: the activity's registered name.
    ///   Used as the bucket prefix when `key` is `nil` (global bucket),
    ///   or as the prefix in `"ActivityName:entityKey"` (per-entity bucket).
    /// - Returns: `slotKey` — the row key in `strand.rate_limit_slots`;
    ///   `intervalMs` — milliseconds between consecutive slots,
    ///   derived from `period / limit` and clamped to at least 1 ms.
    internal func slotParams(for activityName: String) -> (slotKey: String, intervalMs: Int) {
        let slotKey = key.map { "\(activityName):\($0)" } ?? activityName
        let intervalMs = max(1, Int(Double(period.milliseconds) / limit))
        return (slotKey: slotKey, intervalMs: intervalMs)
    }
}

// MARK: - ActivityOptions

/// Per-activity execution configuration: timeout, retry, routing, priority, and fairness.
public struct ActivityOptions: Sendable {
    /// Maximum time this activity attempt may run. `nil` defers to the
    /// worker's claim timeout.
    public var timeout: Duration?

    /// Maximum time between successive `context.heartbeat()` calls.
    ///
    /// If the activity does not heartbeat within this window the worker lease
    /// expires and the run is re-queued as a new attempt — without waiting the
    /// full `timeout` (StartToClose) budget. Useful for long-running activities
    /// (e.g. `timeout: .hours(2), heartbeatTimeout: .seconds(30)`) where you
    /// want fast re-scheduling on a stuck worker without a very short claim window.
    ///
    /// `nil` = extend the lease by the worker's `claimTimeout` on each heartbeat
    /// (the existing behaviour).
    public var heartbeatTimeout: Duration?

    /// Maximum total wall-clock time from when the activity is first scheduled
    /// until it permanently completes, across ALL retry attempts.
    ///
    /// When this deadline is reached,
    /// `failRun` refuses to schedule another retry regardless of remaining
    /// `maxAttempts`. The task is immediately marked `FAILED`.
    ///
    /// `nil` = no total budget (only `maxAttempts` limits retries).
    public var maxDuration: Duration?

    /// Maximum execution attempts before the activity is marked FAILED.
    /// Overrides `Activity.defaultMaxAttempts`.
    public var maxAttempts: Int?

    /// Retry behaviour on failure. Overrides the Activity default.
    public var retryStrategy: RetryStrategy?

    /// Route to a specific queue. `nil` inherits the calling workflow's queue.
    public var queue: String?

    /// Dispatch priority. Lower number = higher urgency. Default: `.normal`.
    public var priority: TaskPriority

    /// Earliest time the activity may be claimed. `nil` = immediately.
    public var delayUntil: Date?

    /// Fairness group key — e.g. a tenant ID.
    /// Activities sharing a key are FIFO within that key; keys compete via
    /// weighted dispatch so no single group can starve others.
    public var fairnessKey: String?

    /// Relative throughput weight for this fairness key. Default `1.0`.
    /// A key with weight `5.0` is dispatched ~5× more often than `1.0`.
    public var fairnessWeight: Double

    /// Key-value metadata forwarded with the activity task (e.g. trace IDs).
    public var headers: [String: String]

    /// Stable identifier for this activity execution.
    ///
    /// Used for deduplication: if an activity with this key already exists in the
    /// same workflow, the existing task ID is returned instead of creating a new one.
    /// When `nil` (default) Strand auto-generates `"<workflowTaskID>:<seqNum>"` — a
    /// stable key that is the same on every replay of the same call site.
    public var id: String?

    /// Maximum time an activity can wait in the queue before being picked up by a worker.
    ///
    /// When exceeded the activity fails immediately rather than waiting indefinitely.
    /// Useful for detecting worker pool exhaustion.
    ///
    /// > Note: Enforcement requires a schema migration (`schedule_to_start_timeout_seconds`
    /// > column on `strand.tasks`). The field is accepted and stored; the timeout is not
    /// > yet enforced at the database level.
    public var scheduleToStartTimeout: Duration?

    /// How the workflow handles cancellation of this activity.
    ///
    /// Defaults to `.tryCancel` — sends a cancel signal and continues immediately.
    public var cancellationType: ActivityCancellationType

    /// Automatic cancellation policy for this activity.
    public var cancellation: CancellationPolicy?

    /// Rate limit for this activity execution.
    ///
    /// When non-nil, each enqueue atomically claims a time slot in
    /// `strand.rate_limit_slots` and sets the run's `available_at` to that
    /// slot time.  `nil` (the default) means no rate limiting — the activity
    /// is enqueued immediately at full speed.
    public var rateLimit: RateLimit?

    public init(
        timeout: Duration? = nil,
        heartbeatTimeout: Duration? = nil,
        maxDuration: Duration? = nil,
        maxAttempts: Int? = nil,
        retryStrategy: RetryStrategy? = nil,
        queue: String? = nil,
        priority: TaskPriority = .normal,
        delayUntil: Date? = nil,
        fairnessKey: String? = nil,
        fairnessWeight: Double = 1.0,
        headers: [String: String] = [:],
        id: String? = nil,
        cancellation: CancellationPolicy? = nil,
        rateLimit: RateLimit? = nil,
        scheduleToStartTimeout: Duration? = nil,
        cancellationType: ActivityCancellationType = .tryCancel
    ) {
        self.timeout = timeout
        self.heartbeatTimeout = heartbeatTimeout
        self.maxDuration = maxDuration
        self.maxAttempts = maxAttempts
        self.retryStrategy = retryStrategy
        self.queue = queue
        self.priority = priority
        self.delayUntil = delayUntil
        self.fairnessKey = fairnessKey
        self.fairnessWeight = max(fairnessWeight, 0.001)
        self.headers = headers
        self.id = id
        self.cancellation = cancellation
        self.rateLimit = rateLimit
        self.scheduleToStartTimeout = scheduleToStartTimeout
        self.cancellationType = cancellationType
    }
}

// MARK: - ActivityContext

// MARK: - Cancellation flag

/// Shared mutable cancellation flag passed between `ActivityContext` and
/// the heartbeat closure inside `Activity._run`.
///
/// Using a reference type (class) lets both the struct and the closure refer
/// to the same storage without copying. `@unchecked Sendable` is safe here:
/// the `Mutex` provides the required thread safety.
package final class _ActivityCancellationFlag: Sendable {
    private let _flag: Mutex<Bool> = Mutex(false)
    package var isCancelled: Bool { _flag.withLock { $0 } }
    package func markCancelled() { _flag.withLock { $0 = true } }
}

// MARK: - ActivityContext

/// Minimal execution context passed into every Activity handler.
///
/// Unlike `WorkflowContext`, `ActivityContext` carries no orchestration
/// primitives — activities are pure units of work that do I/O and return
/// a typed result. They do not call other activities or workflows.
public struct ActivityContext: Sendable {
    /// The UUID of the task row in `strand.tasks` for this activity execution.
    public let activityID: UUID
    /// The registered name of this activity.
    public let activityName: String
    /// The queue this activity was claimed from.
    public let queueName: String
    /// Current attempt number (1-based).
    public let attempt: Int
    /// Logger scoped to this activity execution.
    public let logger: Logger
    /// When this activity task was originally enqueued.
    ///
    /// Decoded from the UUIDv7 timestamp embedded in `activityID` — the same
    /// information that is stored in `strand.tasks.created_at`, available here
    /// at zero cost without an extra DB column or init parameter.
    public var queuedAt: Date { activityID.v7CreatedAt ?? Date() }

    /// Scheduling metadata injected by ``StrandScheduler`` when this activity was
    /// triggered directly by a schedule (`.activity(...)` declaration). `nil` when
    /// the activity was enqueued via ``StrandClient/enqueueActivity(_:input:options:)``
    /// or spawned as a child of a workflow.
    ///
    /// Use `partitionTime` as the canonical anchor for what data period this
    /// execution covers — it is stable across retries and backfill re-runs:
    ///
    /// ```swift
    /// func run(input: Input, context: ActivityContext) async throws -> StrandVoid {
    ///     guard let meta = context.schedulingMetadata else {
    ///         // Directly enqueued — use queuedAt or input-supplied date
    ///         return try await processDay(input.date)
    ///     }
    ///     // Scheduled execution: partitionTime = data interval start (stable across retries)
    ///     // executionTime        = when the scheduler actually fired (wall-clock)
    ///     let day = meta.partitionTime ?? meta.executionTime
    ///     return try await processDay(day)
    /// }
    /// ```
    public let schedulingMetadata: SchedulingMetadata?

    // Package-internal: the parent workflow's task UUID (for parent_task_id FK).
    public let parentWorkflowID: UUID?

    /// The namespace this activity is executing in.
    public let namespace: String
    /// The UUID of the current run attempt (`strand.runs.id`).
    /// Each retry gets a new `runID`; `activityID` stays the same across retries.
    ///
    /// For regular activities this is the exact `strand.runs.id` primary key — safe
    /// to query, log, or use as a correlation token.
    ///
    /// For local activities this is a freshly generated UUID that is **not** backed
    /// by a database row. It changes on every activation (including replays), so it
    /// must not be used for deduplication or DB lookups.
    public let runID: UUID
    /// Per-attempt execution cap. `nil` defers to the worker's claim timeout.
    public let timeout: Duration?
    /// Heartbeat window. When set, a missed heartbeat re-queues the activity after
    /// this duration rather than waiting the full `timeout`. `nil` = worker default.
    public let heartbeatTimeout: Duration?
    /// Maximum execution attempts configured for this activity. `nil` = worker default.
    public let maxAttempts: Int?
    /// Key-value metadata forwarded from the enqueue call site.
    public let headers: [String: String]
    /// Absolute deadline across all retry attempts. `nil` = no total budget.
    /// Use `deadlineAt.map { $0.timeIntervalSince(.now) }` to compute remaining budget.
    public let deadlineAt: Date?

    // Package-internal: heartbeat details from the previous attempt.
    private let _heartbeatDetailsBuffer: ByteBuffer?

    // Package-internal: heartbeat implementation — accepts optional progress details.
    package let _heartbeatImpl: @Sendable (ByteBuffer?) async throws -> Void

    // Shared cancellation flag — set by the heartbeat closure when extendClaim
    // returns no rows (the run is no longer RUNNING).
    private let _cancellationFlag: _ActivityCancellationFlag

    /// `true` when this activity has been externally cancelled via
    /// ``StrandClient/cancelTask(_:)`` or parent-workflow cancellation.
    ///
    /// Updated at each ``heartbeat()`` call — the heartbeat detects
    /// cancellation by trying to extend the lease in Postgres. Without
    /// regular heartbeating this property may lag behind the database state.
    ///
    /// Also returns `true` when Swift’s cooperative task cancellation is active
    /// (e.g. the worker is shutting down or the 2× claim-window deadline fired).
    ///
    /// ```swift
    /// func run(input: BatchInput, context: ActivityContext) async throws -> BatchResult {
    ///     var results: [ItemResult] = []
    ///     for (i, item) in input.items.enumerated() {
    ///         if context.isCancelled { break }      // clean early exit
    ///         if i.isMultiple(of: 50) {
    ///             try await context.heartbeat()      // refreshes isCancelled, throws if cancelled
    ///         }
    ///         results.append(try process(item))
    ///     }
    ///     return BatchResult(results: results, partial: context.isCancelled)
    /// }
    /// ```
    public var isCancelled: Bool {
        Task.isCancelled || _cancellationFlag.isCancelled
    }

    package init(
        activityID: UUID,
        activityName: String,
        queueName: String,
        attempt: Int,
        logger: Logger,
        namespace: String,
        runID: UUID,
        schedulingMetadata: SchedulingMetadata? = nil,
        parentWorkflowID: UUID?,
        timeout: Duration? = nil,
        heartbeatTimeout: Duration? = nil,
        maxAttempts: Int? = nil,
        headers: [String: String] = [:],
        deadlineAt: Date? = nil,
        heartbeatDetailsBuffer: ByteBuffer? = nil,
        cancellationFlag: _ActivityCancellationFlag = _ActivityCancellationFlag(),
        heartbeatImpl: @escaping @Sendable (ByteBuffer?) async throws -> Void = { _ in }  // default no-op
    ) {
        self.activityID = activityID
        self.activityName = activityName
        self.queueName = queueName
        self.attempt = attempt
        self.logger = logger
        self.namespace = namespace
        self.runID = runID
        self.schedulingMetadata = schedulingMetadata
        self.parentWorkflowID = parentWorkflowID
        self.timeout = timeout
        self.heartbeatTimeout = heartbeatTimeout
        self.maxAttempts = maxAttempts
        self.headers = headers
        self.deadlineAt = deadlineAt
        self._heartbeatDetailsBuffer = heartbeatDetailsBuffer
        self._cancellationFlag = cancellationFlag
        self._heartbeatImpl = heartbeatImpl
    }

    /// Extends the activity's worker claim lease, signalling that the activity is
    /// still alive. Call periodically from long-running activities to prevent the
    /// lease watchdog from marking the run as failed.
    ///
    /// ```swift
    /// func run(input: ProcessInput, context: ActivityContext) async throws -> ProcessResult {
    ///     for chunk in input.chunks {
    ///         try await context.heartbeat()   // keep the lease alive
    ///         process(chunk)
    ///     }
    ///     return .done
    /// }
    /// ```
    public func heartbeat() async throws {
        try await _heartbeatImpl(nil)
    }

    /// Extends the activity's lease **and** persists `details` as the heartbeat
    /// progress checkpoint.
    ///
    /// On the next retry attempt, call ``heartbeatDetails(as:)`` to retrieve this
    /// value and resume exactly where you left off:
    ///
    /// ```swift
    /// func run(input: FileInput, context: ActivityContext) async throws -> StrandVoid {
    ///     let startLine = context.heartbeatDetails(as: Int.self) ?? 0
    ///     for line in startLine ..< input.totalLines {
    ///         process(line)
    ///         if line.isMultiple(of: 100) {
    ///             try await context.heartbeat(line)   // survive any crash here
    ///         }
    ///     }
    ///     return .done
    /// }
    /// ```
    public func heartbeat<T: Codable & Sendable>(_ details: T) async throws {
        let buf = try JSON.encode(details)
        try await _heartbeatImpl(buf)
    }

    /// Returns the heartbeat details stored by the **previous** attempt, decoded
    /// as `T`. Returns `nil` on the first attempt or if the previous attempt
    /// never called ``heartbeat(_:)``.
    ///
    /// ```swift
    /// let startLine = context.heartbeatDetails(as: Int.self) ?? 0
    /// ```
    public func heartbeatDetails<T: Codable & Sendable>(as type: T.Type = T.self) -> T? {
        guard let buf = _heartbeatDetailsBuffer else { return nil }
        return try? JSON.decode(T.self, from: buf)
    }
}

// MARK: - Activity

/// A dependency-injected, independently-retried unit of I/O.
///
/// Activities hold their dependencies as stored properties and are registered
/// on ``StrandWorker`` via `activities:` or `activityContainers:`. The worker
/// claims, executes, and retries them independently.
///
/// Activity instances can be passed directly in the `activities:` array.
///
/// ```swift
/// struct ChargeCardActivity: Activity {
///     typealias Input  = ChargeInput
///     typealias Output = ChargeResult
///
///     let stripe: StripeClient
///
///     func run(input: ChargeInput, context: ActivityContext) async throws -> ChargeResult {
///         ChargeResult(paymentID: try await stripe.charge(input.amount))
///     }
/// }
/// ```
public protocol Activity: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable
    /// The typed error this activity can throw.
    ///
    /// Declare a concrete `Codable` error type to get direct typed propagation in
    /// `WorkflowContext.runActivity` — no `ActivityError` wrapper, no `.cause` cast.
    ///
    /// ```swift
    /// struct AddBankAccountActivity: Activity {
    ///     typealias Failure = BankAccountError   // BankAccountError: Codable
    ///     func run(input: Input, context: ActivityContext) async throws(BankAccountError) -> Output {
    ///         throw .invalidDetails
    ///     }
    /// }
    /// ```
    ///
    /// Use `Failure = Never` for activities that never fail with a typed error.
    associatedtype Failure: Error & Codable & Sendable = Never

    /// Unique registered name. Defaults to the Swift type name.
    static var name: String { get }

    /// Max attempts before the activity is marked FAILED.
    /// `nil` defers to the worker's default (``WorkerOptions/defaultMaxAttempts``).
    static var defaultMaxAttempts: Int? { get }

    /// Per-attempt execution timeout.
    /// `nil` defers to the worker's claim timeout (``WorkerOptions/claimTimeout``).
    static var defaultTimeout: Duration? { get }

    /// Run the activity. May perform I/O. Called on each attempt.
    ///
    /// The function is declared `async throws` (untyped) so that activities that
    /// use Swift's cancellation mechanism (`try await Task.sleep(...)`) compile
    /// correctly regardless of their `Failure` type. Typed-throw enforcement is
    /// voluntary: conformers that want compile-time guarantees write
    /// `async throws(Failure) -> Output` on their own `run` declaration — Swift
    /// accepts this as a subtype of the protocol requirement.
    ///
    /// `Failure` drives serialisation: Strand encodes the full `Codable` value
    /// into `strand.runs.failure_reason` when a thrown error matches `Failure`,
    /// and decodes it back in `WorkflowContext.runActivity` so the workflow sees
    /// `Failure` directly — no `ActivityError` wrapper.
    func run(input: Input, context: ActivityContext) async throws -> Output
}

extension Activity {
    public static var name: String { String(describing: Self.self) }
    public static var defaultMaxAttempts: Int? { nil }
    public static var defaultTimeout: Duration? { nil }

    /// Auto-generated idempotency key used by `StrandClient.enqueueActivity`
    /// when `ActivityOptions.id` is not supplied.
    ///
    /// Format: `"<ActivityName>-<epochMs>"` —
    /// e.g. `"ChargeCardActivity-1746218580123"`.
    static func generateActivityID() -> String {
        let ms = Int(Date.now.timeIntervalSince1970 * 1000)
        return "\(name)-\(ms)"
    }

}

extension Activity {

    /// Decode → run → encode for in-process local activity execution.
    /// No `ClaimedTask` needed — a minimal `ActivityContext` is synthesised.
    func _runLocal(
        input: ByteBuffer,
        exec: _WorkerExec,
        parentWorkflowID: UUID?
    ) async throws -> ByteBuffer {
        let decodedInput = try JSON.decode(Input.self, from: input)
        let ctx = ActivityContext(
            activityID: UUID.v7(),
            activityName: Self.name,
            queueName: exec.queue,
            attempt: 1,
            logger: exec.logger,
            namespace: exec.namespace,
            runID: UUID.v7(),  // ephemeral — not backed by a strand.runs row
            parentWorkflowID: parentWorkflowID,
            heartbeatImpl: { _ in }  // no-op: local activities run synchronously in the activation
        )
        let output = try await self.run(input: decodedInput, context: ctx)
        return try JSON.encode(output)
    }

    /// Decode → run → encode. Called by `_addActivityRegistration` and local-activity dispatch.
    func _run(
        claimed: ClaimedTask,
        exec: _WorkerExec,
        fatalDeadline: TaskDeadline? = nil
    )
        async throws -> ByteBuffer
    {
        let input = try JSON.decode(Input.self, from: claimed.paramsBuffer)

        // Capture values needed by the heartbeat closure (must be Sendable).
        let postgres = exec.postgres
        let namespace = exec.namespace
        let runID = claimed.runID
        // Use the task's own timeout (if set and positive) for lease extensions;
        // fall back to the worker's claimTimeout. Zero is treated as unset so
        // that Duration.zero / accidental 0s never produce an instant-expire lease.
        let claimTimeoutSecs: Int
        if let t = claimed.timeoutSeconds, t > 0 {
            claimTimeoutSecs = t
        } else {
            claimTimeoutSecs = Int(exec.options.claimTimeout.components.seconds)
        }
        // Use heartbeatTimeout for lease extension if set; otherwise fall back to the
        // worker's claimTimeout. This ensures the activity is re-queued quickly when
        // it stops heartbeating, without requiring a very short claimTimeout.
        let heartbeatExtendSecs: Int
        if let ht = claimed.heartbeatTimeoutSeconds, ht > 0 {
            heartbeatExtendSecs = ht
        } else {
            heartbeatExtendSecs = claimTimeoutSecs
        }
        let heartbeatLogger = exec.logger

        // Create the cancellation flag before the context so the heartbeat
        // closure and ActivityContext.isCancelled share the same reference.
        let cancellationFlag = _ActivityCancellationFlag()

        let ctx = ActivityContext(
            activityID: claimed.taskID,
            activityName: claimed.taskName,
            queueName: exec.queue,
            attempt: claimed.attempt,
            logger: exec.logger,
            namespace: exec.namespace,
            runID: claimed.runID,
            schedulingMetadata: claimed.schedulingMetadata,
            parentWorkflowID: claimed.parentWorkflowID,
            timeout: claimed.timeoutSeconds.map { .seconds($0) },
            heartbeatTimeout: claimed.heartbeatTimeoutSeconds.map { .seconds($0) },
            maxAttempts: claimed.maxAttempts,
            headers: claimed.headers,
            deadlineAt: claimed.deadlineAt,
            heartbeatDetailsBuffer: claimed.heartbeatDetails,
            cancellationFlag: cancellationFlag,
            heartbeatImpl: { details in
                do {
                    // Extend the Postgres lease to signal that the activity is still alive.
                    // When `details` is non-nil, persists the heartbeat progress checkpoint
                    // so the next retry attempt can resume exactly where it left off.
                    // Returns true if the *task* is CANCELLED (even though the RUNNING
                    // run is preserved — waitCancellationCompleted semantics).
                    let taskCancelled = try await Queries.extendClaim(
                        on: postgres,
                        namespaceID: namespace,
                        runID: runID,
                        extendBySeconds: heartbeatExtendSecs,
                        heartbeatDetails: details,
                        logger: heartbeatLogger
                    )
                    // Also renew the in-process fatal deadline so a long-running
                    // activity that regularly heartbeats is never killed by the 2×
                    // claimTimeout guard.
                    fatalDeadline?.renew()
                    // For waitCancellationCompleted activities: the parent was cancelled
                    // but the RUNNING run is intentionally preserved so the activity can
                    // finish its cleanup. Signal isCancelled = true so the activity code
                    // can detect the cancellation and exit gracefully — without being
                    // hard-stopped by a thrown CancellationError.
                    //
                    // For regular (tryCancel) activities: when the parent is cancelled
                    // the run itself is also cancelled, so extendClaim finds no RUNNING
                    // row and throws InternalError before we ever reach this branch.
                    if taskCancelled {
                        cancellationFlag.markCancelled()
                        // Don't throw — allow the activity to complete naturally.
                    }
                } catch is InternalError {
                    // extendClaim found no RUNNING row — the run was cancelled
                    // externally. Set the flag so context.isCancelled returns true
                    // immediately, then throw CancellationError (Swift's standard
                    // cancellation type) rather than leaking InternalError.
                    cancellationFlag.markCancelled()
                    throw CancellationError()
                }
            }
        )
        // Worker.runTask already opens a .consumer span (with the workflow activation
        // span as its parent) that covers the full claim lifecycle.  Opening a second
        // identical span here produces duplicate entries in Jaeger — same name, same
        // strand.run.id, same attempt — which look like replay bugs.
        // The activity just runs directly inside the outer span.
        do {
            let output = try await self.run(input: input, context: ctx)
            return try JSON.encode(output)
        } catch let typedFailure as Failure {
            // Typed failure declared by the activity — encode the full Codable value.
            let payloadBuffer = try? JSON.encode(typedFailure)
            let src = (typedFailure as? any LocatableError).map { ($0.sourceFileID, $0.sourceLine) }
            throw _TypedActivityFailure(
                name: String(describing: type(of: typedFailure)),
                message: strandErrorMessage(typedFailure),
                payload: payloadBuffer,
                nonRetryable: typedFailure is any NonRetryableError,
                source: src
            )
        } catch is CancellationError {
            // Worker shutdown — propagate for proper runTask handling.
            throw CancellationError()
        } catch {
            // Non-typed or unexpected error (Failure = Never, or unhandled throw).
            let src = (error as? any LocatableError).map { ($0.sourceFileID, $0.sourceLine) }
            throw _TypedActivityFailure(
                name: String(describing: type(of: error)),
                message: strandErrorMessage(error),
                payload: nil,
                nonRetryable: error is any NonRetryableError,
                source: src
            )
        }
    }
}
