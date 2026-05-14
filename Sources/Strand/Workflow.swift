public import NIOCore  // ByteBuffer in public handleSignal(name:payload:ByteBuffer?)

#if canImport(FoundationEssentials)
public import FoundationEssentials  // Date in WorkflowOptions.delayUntil
#else
public import Foundation
#endif

// MARK: - Registration tokens
//
// Type-erased closures the worker stores per registered handler.
// Underscore-prefixed: infrastructure details; never call these directly.

/// Opaque workflow activation token. Do not construct or call directly.
public struct _WorkflowToken: Sendable {
    let name: String
    let preferredQueue: String?
    let activate: @Sendable (ClaimedTask, _WorkerExec) async throws -> ByteBuffer?
}

/// Opaque activity execution token. Do not construct or call directly.
public struct _ActivityToken: Sendable {
    let name: String
    let preferredQueue: String?
    let run: @Sendable (ClaimedTask, _WorkerExec, TaskDeadline) async throws -> ByteBuffer
    let runLocal: @Sendable (ByteBuffer, _WorkerExec, UUID?) async throws -> ByteBuffer
}

// MARK: - WorkflowRegistrable

/// Marker protocol that enables workflow types in the `workflows:` array.
///
/// Every type conforming to ``Workflow`` automatically satisfies this protocol.
/// You never need to implement it manually.
public protocol WorkflowRegistrable: Sendable {
    /// The task name used for DB dispatch. Defaults to the Swift type name.
    static var workflowName: String { get }

    /// Infrastructure used by ``StrandWorker``. Do not call or implement manually;
    /// a default is provided via `extension Workflow`.
    static func _makeToken() -> _WorkflowToken
}

extension WorkflowRegistrable {
    /// Package-internal — not part of the public protocol surface.
    /// Called by `StrandClient.startWorkflow` when `WorkflowOptions.id` is nil.
    /// Users customise the workflow ID by passing `WorkflowOptions(id: "my-id")`.
    ///
    /// Format: `"<WorkflowName>-<epochMs>-<randomHex4>"` —
    /// e.g. `"OrderWorkflow-1746218580123-a3f2"`.
    ///
    /// The epoch-millisecond component keeps IDs time-ordered and human-scannable.
    /// The 4-hex-char random suffix (16 bits, 65536 values) prevents collisions
    /// when multiple workflows of the same type start within the same millisecond.
    static func generateWorkflowID() -> String {
        let ms = Int(Date.now.timeIntervalSince1970 * 1000)
        let rnd = String(format: "%04x", UInt16.random(in: .min ... .max))
        return "\(workflowName)-\(ms)-\(rnd)"
    }
}

// MARK: - Workflow

/// A durable workflow orchestrator implemented as a value-type struct.
///
/// The handler **must be deterministic**: no I/O, no `Date.now`, no `UUID()`.
/// All I/O belongs in ``Activity`` implementations.
///
/// ```swift
/// struct OrderWorkflow: Workflow {
///     typealias Input  = OrderInput
///     typealias Output = ShipResult
///
///     var isPaused = false
///
///     mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
///         if name == "pause"  { isPaused = true }
///         if name == "resume" { isPaused = false }
///     }
///
///     mutating func run(context: WorkflowContext<Self>, input: OrderInput) async throws -> ShipResult {
///         let charge = try await context.runActivity(ChargeCardActivity.self,
///             input: .init(amount: input.amount))
///         return try await context.runActivity(ShipOrderActivity.self,
///             input: .init(paymentID: charge.paymentID))
///     }
/// }
/// ```
public protocol Workflow: WorkflowRegistrable, Codable & Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable

    /// Creates a workflow instance in its initial state.
    ///
    /// The runtime calls `init()` on the first activation (before any signals or
    /// activities have been applied) instead of decoding from `{}`. This means
    /// stored properties can use non-optional types with default values:
    ///
    /// ```swift
    /// struct OrderWorkflow: Workflow {
    ///     var isPaused: Bool = false      // non-optional — fine
    ///     var priority: Priority = .standard
    /// }
    /// ```
    ///
    /// Swift synthesises `init()` automatically when all stored properties have
    /// default values (explicit `= value`) or are `Optional` (implicit `nil`).
    /// You only need to write `init() {}` explicitly if you have a stored property
    /// with no default that you want to initialise to some custom starting value.
    init()

    /// Called on each activation. Must be deterministic.
    mutating func run(context: WorkflowContext<Self>, input: Input) async throws -> Output

    /// Apply an externally-delivered signal before `run()` on each activation.
    /// Default implementation silently ignores unknown signals.
    mutating func handleSignal(name: String, payload: ByteBuffer?) throws
}

extension Workflow {
    public static var workflowName: String { String(describing: Self.self) }
    public mutating func handleSignal(name: String, payload: ByteBuffer?) throws {}

    /// Decodes a typed payload from the raw `ByteBuffer?` delivered to `handleSignal`.
    ///
    /// Returns `nil` when `buffer` is `nil` (signal with no payload).
    /// Throws `StrandError.serialization` when the buffer is present but cannot
    /// be decoded as `T`.
    ///
    /// ```swift
    /// mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
    ///     switch name {
    ///     case "priority":
    ///         if let p = try decodeSignalPayload(ShippingPriority.self, from: payload) {
    ///             priority = p
    ///         }
    ///     default: break
    ///     }
    /// }
    /// ```
    public func decodeSignalPayload<T: Codable & Sendable>(
        _ type: T.Type,
        from buffer: ByteBuffer?
    ) throws -> T? {
        guard let buf = buffer else { return nil }
        return try JSON.decode(type, from: buf)
    }

}

// MARK: - WorkflowEvent

/// A named, typed event that a workflow can wait for and a client can emit.
///
/// Define an event as a concrete type so the compiler enforces that both sides
/// agree on the name and payload type. A typo or payload mismatch becomes a
/// compile error instead of a silent runtime failure.
///
/// ```swift
/// // 1. Define the event once:
/// struct OrderShippedEvent: WorkflowEvent {
///     typealias Payload = TrackingInfo
///     static let name   = "order.shipped"
/// }
///
/// // 2. Wait for it in the workflow:
/// let tracking = try await context.waitForEvent(OrderShippedEvent.self)
///
/// // 3. Emit it from the client:
/// try await client.emit(OrderShippedEvent.self,
///     payload: TrackingInfo(number: "1Z999"),
///     to: orderHandle)
/// ```
///
/// For dynamic event names (e.g. per-order topics) the string API remains:
/// `context.waitForEvent("order.shipped:\(orderID)", as: TrackingInfo.self)`
public protocol WorkflowEvent: Sendable {
    /// The event payload. Must be `Codable` and `Sendable`.
    associatedtype Payload: Codable & Sendable

    /// Stable event name used for DB dispatch and client-side emission.
    /// Defaults to the Swift type name.
    static var name: String { get }
}

extension WorkflowEvent {
    public static var name: String { String(describing: Self.self) }
}

// MARK: - WorkflowSignalDefinition

/// Describes a named, typed signal a workflow can receive.
///
/// Conforming types are generated automatically by the `@WorkflowSignal` macro
/// (not yet implemented). Until the macro lands, define them manually as nested
/// types inside your workflow struct:
///
/// ```swift
/// struct OrderWorkflow: Workflow {
///     var isPaused: Bool = false
///
///     // Manual equivalent of @WorkflowSignal
///     struct Pause: WorkflowSignalDefinition {
///         typealias Input = StrandVoid
///         typealias W     = OrderWorkflow
///         static let signalName = "pause"
///         static func apply(to workflow: inout OrderWorkflow, input: StrandVoid) {
///             workflow.isPaused = true
///         }
///     }
/// }
///
/// // Type-safe call site:
/// try await handle.signal(OrderWorkflow.Pause.self)
/// ```
///
/// The `handleSignal(name:payload:)` implementation in `Workflow` dispatches
/// to registered definitions automatically when the workflow conforms to
/// ``WorkflowWithSignals``.
public protocol WorkflowSignalDefinition {
    /// The workflow type that owns this signal.
    associatedtype W: Workflow

    /// Payload type. Use `StrandVoid` for no-payload signals.
    associatedtype Input: Codable & Sendable

    /// Signal name used for dispatch. Defaults to the type name lowercased.
    static var signalName: String { get }

    /// Apply the signal to the workflow struct.
    static func apply(to workflow: inout W, input: Input)
}

extension WorkflowSignalDefinition {
    /// Default: the lowercased Swift type name (e.g. `Pause` → `"pause"`).
    public static var signalName: String {
        String(describing: Self.self).lowercased()
    }
}

// MARK: - ActivityBox

/// Marker protocol that enables activity instances in the `activities:` array.
///
/// Every type conforming to ``Activity`` automatically satisfies this
/// protocol. You never need to implement it manually.
public protocol ActivityBox: Sendable {
    /// The registered activity name — shown in logs and the dashboard.
    var activityName: String { get }

    /// Infrastructure used by ``StrandWorker``. Do not call or implement manually;
    /// a default is provided via `extension Activity`.
    func _makeToken() -> _ActivityToken
}

// MARK: - ActivityContainerProtocol

/// Groups related activities that share common dependencies (e.g. an HTTP client).
///
/// ```swift
/// struct PaymentActivities: ActivityContainerProtocol {
///     let stripe: StripeClient
///
///     var activities: [any ActivityBox] {
///         [ChargeCardActivity(stripe: stripe),
///          RefundCardActivity(stripe: stripe)]
///     }
/// }
/// ```
public protocol ActivityContainerProtocol: Sendable {
    var activities: [any ActivityBox] { get }
}

// MARK: - ArcBox

/// Reference-counted workflow state wrapper. One allocation per workflow lifetime.
///
/// `@unchecked Sendable`: all mutations occur in a single async task per activation.
public final class ArcBox<T: Sendable>: @unchecked Sendable {
    public var value: T
    public init(_ value: T) { self.value = value }

    /// Reads the boxed value through a closure without triggering Swift's
    /// law-of-exclusivity enforcement on the caller's access path.
    ///
    /// This is the safe way for `WorkflowContext.condition(_:)` to read
    /// `stateBox.value` post-drain: at that point the `mutating run()` call
    /// has already suspended and released its exclusive access.
    func withValue<R>(_ body: (T) -> R) -> R { body(value) }
}

// MARK: - WorkflowOptions

/// Options for ``StrandClient/startWorkflow(_:options:input:)``.
public struct WorkflowOptions: Sendable {
    /// Stable deduplication key. Existing running workflows with this ID are
    /// returned instead of starting a new one.
    public var id: String?
    /// Target queue. `nil` inherits the client's default queue.
    public var queue: String?
    /// Dispatch priority. Default: `.normal`.
    public var priority: TaskPriority
    /// Earliest time the workflow may be claimed. `nil` = immediately.
    public var delayUntil: Date?
    /// Maximum activation attempts before the workflow is marked FAILED.
    public var maxAttempts: Int?
    /// Retry policy. `nil` inherits the client default.
    public var retryStrategy: RetryStrategy?
    /// Key-value metadata forwarded with the task.
    public var headers: [String: String]
    /// Fairness group key — e.g. a tenant ID or customer name (max 64 bytes).
    /// Tasks sharing a key are FIFO within that key; keys compete via weighted dispatch.
    public var fairnessKey: String?
    /// Relative throughput weight for this fairness key. Default `1.0`.
    /// A key with weight `5.0` is dispatched approximately 5× more often than a key with `1.0`.
    /// Only meaningful when `fairnessKey` is set.
    public var fairnessWeight: Double
    /// Maximum total wall-clock duration from when the workflow is first enqueued until
    /// it permanently completes, across **all** retries and `continueAsNew` transitions.
    ///
    /// When this deadline is reached, `failRun` refuses to schedule another retry
    /// regardless of remaining `maxAttempts`. The task is immediately marked `FAILED`
    /// and workers skip claiming it once the deadline has elapsed.
    ///
    /// `nil` = no total budget; only `maxAttempts` limits the workflow.
    ///
    /// ```swift
    /// // Subscription workflow must complete within 10 minutes:
    /// try await client.startWorkflow(
    ///     SubscriptionWorkflow.self,
    ///     options: WorkflowOptions(id: "sub-\(customerID)", maxDuration: .seconds(600)),
    ///     input: customer
    /// )
    /// ```
    public var maxDuration: Duration?

    public init(
        id: String? = nil,
        queue: String? = nil,
        priority: TaskPriority = .normal,
        delayUntil: Date? = nil,
        maxAttempts: Int? = nil,
        retryStrategy: RetryStrategy? = nil,
        headers: [String: String] = [:],
        fairnessKey: String? = nil,
        fairnessWeight: Double = 1.0,
        maxDuration: Duration? = nil
    ) {
        self.id = id
        self.queue = queue
        self.priority = priority
        self.delayUntil = delayUntil
        self.maxAttempts = maxAttempts
        self.retryStrategy = retryStrategy
        self.headers = headers
        self.fairnessKey = fairnessKey
        self.fairnessWeight = max(fairnessWeight, 0.001)
        self.maxDuration = maxDuration
    }
}

// MARK: - ChildWorkflowOptions

/// Options for ``WorkflowContext/runChildWorkflow(_:options:input:)``.
public struct ChildWorkflowOptions: Sendable {
    /// Target queue for this child workflow. `nil` inherits the parent’s queue.
    public var queue: String?
    /// Dispatch priority. Default: `.normal`.
    public var priority: TaskPriority
    /// Maximum activation attempts before the child is marked FAILED.
    /// `nil` inherits the worker default.
    public var maxAttempts: Int?
    /// Key-value metadata forwarded with the child workflow task.
    public var headers: [String: String]
    /// Fairness group key for this child workflow. See ``WorkflowOptions/fairnessKey``.
    public var fairnessKey: String?
    /// Relative throughput weight for this child's fairness key. Default `1.0`.
    public var fairnessWeight: Double
    /// Retry policy on failure. `nil` inherits the worker default.
    public var retryStrategy: RetryStrategy?
    /// Earliest time this child workflow may be claimed. `nil` = immediately.
    public var delayUntil: Date?
    /// Maximum total wall-clock duration for this child workflow across all retries
    /// and `continueAsNew` transitions. `nil` = no total budget.
    /// Equivalent to ``WorkflowOptions/maxDuration`` for top-level workflows.
    public var maxDuration: Duration?

    public init(
        queue: String? = nil,
        priority: TaskPriority = .normal,
        maxAttempts: Int? = nil,
        headers: [String: String] = [:],
        fairnessKey: String? = nil,
        fairnessWeight: Double = 1.0,
        retryStrategy: RetryStrategy? = nil,
        delayUntil: Date? = nil,
        maxDuration: Duration? = nil
    ) {
        self.queue = queue
        self.priority = priority
        self.maxAttempts = maxAttempts
        self.headers = headers
        self.fairnessKey = fairnessKey
        self.fairnessWeight = max(fairnessWeight, 0.001)
        self.retryStrategy = retryStrategy
        self.delayUntil = delayUntil
        self.maxDuration = maxDuration
    }
}
