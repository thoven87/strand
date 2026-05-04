public import Logging  // Logger in ActivityContext.logger is public API
import NIOCore  // ByteBuffer used internally in _activityToken() closure; not in Activity.swift's own public API
import PostgresNIO  // PostgresClient captured in heartbeatImpl closure; internal to _run()
import Tracing

#if canImport(FoundationEssentials)
public import FoundationEssentials  // UUID in ActivityContext.activityID, Date in ActivityOptions are public API
#else
public import Foundation
#endif

// MARK: - StrandVoid

/// A `Codable`, `Sendable` unit type used as the `Output` of an ``ActivityDefinition``
/// that performs a side effect and returns no meaningful value.
///
/// ```swift
/// struct SendEmailActivity: ActivityDefinition {
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

// MARK: - ActivityOptions

/// Per-activity execution configuration: timeout, retry, routing, priority, and fairness.
public struct ActivityOptions: Sendable {
    /// Maximum time this activity attempt may run. `nil` defers to the
    /// worker's claim timeout.
    public var timeout: Duration?

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
    public var fairnessWeight: Float

    /// Key-value metadata forwarded with the activity task (e.g. trace IDs).
    public var headers: [String: String]

    /// Deduplication key. If an activity with this key already exists the
    /// existing task ID is returned instead of creating a new one.
    /// `nil` = auto-generated from parent task UUID + call-site counter.
    public var idempotencyKey: String?

    /// Automatic cancellation policy for this activity.
    public var cancellation: CancellationPolicy?

    public init(
        timeout: Duration? = nil,
        maxDuration: Duration? = nil,
        maxAttempts: Int? = nil,
        retryStrategy: RetryStrategy? = nil,
        queue: String? = nil,
        priority: TaskPriority = .normal,
        delayUntil: Date? = nil,
        fairnessKey: String? = nil,
        fairnessWeight: Float = 1.0,
        headers: [String: String] = [:],
        idempotencyKey: String? = nil,
        cancellation: CancellationPolicy? = nil
    ) {
        self.timeout = timeout
        self.maxDuration = maxDuration
        self.maxAttempts = maxAttempts
        self.retryStrategy = retryStrategy
        self.queue = queue
        self.priority = priority
        self.delayUntil = delayUntil
        self.fairnessKey = fairnessKey
        self.fairnessWeight = max(fairnessWeight, 0.001)
        self.headers = headers
        self.idempotencyKey = idempotencyKey
        self.cancellation = cancellation
    }
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

    // Package-internal: the parent workflow's task UUID (for parent_task_id FK).
    package let parentWorkflowID: UUID?

    // Package-internal: heartbeat implementation injected by the worker.
    package let _heartbeatImpl: @Sendable () async throws -> Void

    package init(
        activityID: UUID,
        activityName: String,
        queueName: String,
        attempt: Int,
        logger: Logger,
        parentWorkflowID: UUID?,
        heartbeatImpl: @escaping @Sendable () async throws -> Void = {}  // default no-op
    ) {
        self.activityID = activityID
        self.activityName = activityName
        self.queueName = queueName
        self.attempt = attempt
        self.logger = logger
        self.parentWorkflowID = parentWorkflowID
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
        try await _heartbeatImpl()
    }
}

// MARK: - Activity

/// A self-contained, independently retryable unit of work.
///
/// Closure-based standalone activity for use with `StrandClient.enqueue(_:params:)`
/// and `StrandClient.runActivity(_:params:)`. For worker-registered activities that
/// hold dependencies, use ``ActivityDefinition`` instead.
///
/// ```swift
/// let chargeCard = Activity<ChargeInput, ChargeResult>(name: "charge-card") { input, _ in
///     ChargeResult(paymentID: try await stripe.charge(input.amount))
/// }
/// // Fire-and-forget from the client:
/// let enq = try await client.enqueue(chargeCard, params: ChargeInput(amount: 99.99))
/// ```
public struct Activity<P: Codable & Sendable, R: Codable & Sendable>: Sendable {

    public let name: String
    public let queue: String?
    public let defaultMaxAttempts: Int?

    /// Package-internal: the typed handler.
    package let handler: @Sendable (P, ActivityContext) async throws -> R

    /// Package-internal: the execution kind stored in strand.tasks.kind.
    package let executionKind: TaskKind = .activity

    public init(
        name: String,
        queue: String? = nil,
        maxAttempts: Int? = nil,
        run handler: @escaping @Sendable (P, ActivityContext) async throws -> R
    ) {
        self.name = name
        self.queue = queue
        self.defaultMaxAttempts = maxAttempts
        self.handler = handler
    }
}

// MARK: - ActivityDefinition

/// A dependency-injected, independently-retried unit of I/O.
///
/// Activities hold their dependencies as stored properties and are registered
/// on ``StrandWorker`` via `activities:` or `activityContainers:`. The worker
/// claims, executes, and retries them independently.
///
/// `ActivityDefinition` automatically satisfies ``ActivityBox``, so instances
/// can be passed directly in the `activities:` array without any wrapper.
///
/// ```swift
/// struct ChargeCardActivity: ActivityDefinition {
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
public protocol ActivityDefinition: ActivityBox {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable

    /// Unique registered name. Defaults to the Swift type name.
    static var name: String { get }

    /// Max attempts before the activity is marked FAILED.
    /// `nil` defers to the worker's default (``WorkerOptions/defaultMaxAttempts``).
    static var defaultMaxAttempts: Int? { get }

    /// Per-attempt execution timeout.
    /// `nil` defers to the worker's claim timeout (``WorkerOptions/claimTimeout``).
    static var defaultTimeout: Duration? { get }

    /// Run the activity. May perform I/O. Called on each attempt.
    func run(input: Input, context: ActivityContext) async throws -> Output
}

extension ActivityDefinition {
    public static var name: String { String(describing: Self.self) }
    public static var defaultMaxAttempts: Int? { nil }
    public static var defaultTimeout: Duration? { nil }

    // MARK: ActivityBox conformance

    /// The registered activity name (instance-level, satisfies ActivityBox).
    public var activityName: String { Self.name }
}

// Default ActivityBox._makeToken() and internal _run() entry point.
// Every ActivityDefinition gets these for free — no manual implementation needed.
extension ActivityDefinition {

    public func _makeToken() -> _ActivityToken {
        _ActivityToken(
            name: Self.name,
            preferredQueue: nil,
            run: { [self] claimed, exec, deadline in
                try await self._run(claimed: claimed, exec: exec, fatalDeadline: deadline)
            },
            runLocal: { [self] input, exec, parentID in
                try await self._runLocal(input: input, exec: exec, parentWorkflowID: parentID)
            }
        )
    }

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
            parentWorkflowID: parentWorkflowID,
            heartbeatImpl: {}  // no-op: local activities run synchronously in the activation
        )
        let output = try await self.run(input: decodedInput, context: ctx)
        return try JSON.encode(output)
    }

    /// Decode → run → encode. Used by both _makeToken and StrandWorkerBuilder.buildExpression.
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
        let heartbeatLogger = exec.logger

        let ctx = ActivityContext(
            activityID: claimed.taskID,
            activityName: claimed.taskName,
            queueName: exec.queue,
            attempt: claimed.attempt,
            logger: exec.logger,
            parentWorkflowID: claimed.parentWorkflowID,
            heartbeatImpl: {
                // Extend the Postgres lease to signal that the activity is still alive.
                try await Queries.extendClaim(
                    on: postgres,
                    namespaceID: namespace,
                    runID: runID,
                    extendBySeconds: claimTimeoutSecs,
                    logger: heartbeatLogger
                )
                // Also renew the in-process fatal deadline so a long-running
                // activity that regularly heartbeats is never killed by the 2×
                // claimTimeout guard.
                fatalDeadline?.renew()
            }
        )
        // OTel span: one span per activity execution attempt.
        // Zero-cost no-op when no tracing backend is bootstrapped.
        let output = try await withSpan("RunActivity:\(Self.name)", ofKind: .internal) { span in
            span.attributes[StrandLogKeys.taskName] = SpanAttribute.string(Self.name)
            span.attributes[StrandLogKeys.taskID] = SpanAttribute.string(
                claimed.taskID.uuidString.lowercased()
            )
            span.attributes[StrandLogKeys.runID] = SpanAttribute.string(
                claimed.runID.uuidString.lowercased()
            )
            span.attributes[StrandLogKeys.queue] = SpanAttribute.string(exec.queue)
            span.attributes[StrandLogKeys.attempt] = SpanAttribute.int(Int64(claimed.attempt))
            return try await self.run(input: input, context: ctx)
        }
        return try JSON.encode(output)
    }
}
