@_exported import NIOCore  // re-export so consumers get ByteBuffer without importing NIOCore directly
public import PostgresNIO  // required for ParentClosePolicy/ChildWorkflowCancellationType PostgresCodable conformances

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

    /// Runtime hook for `@WorkflowUpdate` handlers. Do not implement directly —
    /// the `@Workflow` macro generates this from `@WorkflowUpdate`-annotated methods.
    ///
    /// Returns the JSON-encoded result on success, `nil` when the update name is
    /// unrecognised. Throw to propagate a validation error back to the caller.
    @_documentation(visibility: internal)
    mutating func handleUpdate(
        name: String,
        correlationID: String,
        payload: ByteBuffer?
    ) throws -> ByteBuffer?
}

extension Workflow {
    public static var workflowName: String { String(describing: Self.self) }
    public mutating func handleSignal(name: String, payload: ByteBuffer?) throws {}
    public mutating func handleUpdate(
        name: String,
        correlationID: String,
        payload: ByteBuffer?
    ) throws -> ByteBuffer? { nil }

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
/// ## Instance-scoped delivery via `matching:` predicate
///
/// Multiple concurrent workflow instances can share the same event name.
/// Use the `matching:` parameter on `waitForEvent` to filter by a payload
/// field — Postgres evaluates `payload @> predicate` at emission time via a
/// GIN index, so only the matching workflow instance is woken:
///
/// ```swift
/// // 1. Define the event once:
/// struct OrderApprovedEvent: WorkflowEvent {
///     typealias Payload = ApprovalPayload
///     static let name = "order.approved"
/// }
///
/// // 2. Wait in the workflow — filter by orderId so only this instance wakes:
/// let approval = try await context.waitForEvent(
///     OrderApprovedEvent.self,
///     matching: \.orderId == input.orderId
/// )
///
/// // 3. Emit from a handler — predicate routing happens in Postgres:
/// try await client.emit(
///     OrderApprovedEvent.self,
///     payload: ApprovalPayload(orderId: "abc-123", approved: true)
/// )
/// ```
///
/// ## Broadcast (no predicate)
///
/// Omit `matching:` to wake every workflow waiting for this event type:
/// ```swift
/// let signal = try await context.waitForEvent(SystemShutdownEvent.self)
/// try await client.emit(SystemShutdownEvent.self, payload: ShutdownPayload())
/// ```
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

// MARK: - EventPredicate

/// A serializable equality predicate for payload-based event routing.
///
/// Created via the `==` operator on a `KeyPath` of the event's `Payload` type.
/// The predicate is stored as JSONB in `strand.event_waits` and evaluated by
/// Postgres at emission time using the `@>` containment operator — only the
/// workflows whose predicate is a subset of the incoming event payload are woken.
/// Filtering happens **before** any workflow is resumed.
///
/// ```swift
/// // Flat field:
/// \.approvalId == input.approvalId     // stores {"approvalId": "abc-123"}
///
/// // Nested field:
/// \.order.id == input.orderID          // stores {"order": {"id": "abc-123"}}
/// ```
///
/// - Note: The property name is extracted from Swift's KeyPath description string
///   (`String(describing:)`). This is reliable for stored properties in current
///   Swift (5.9+). Computed properties or very deep nesting may require using
///   ``EventPredicate/init(path:equals:)`` with an explicit dot-path string.
public struct EventPredicate<Target>: Sendable {
    /// Dot-separated path components, e.g. `["order", "id"]`.
    let pathComponents: [String]
    /// JSON-encoded bytes of the expected value (e.g. `"\"abc-123\""` for a String).
    let valueBytes: [UInt8]

    /// Creates a predicate with an explicit dot-path string.
    ///
    /// Use this when `String(describing: keyPath)` doesn't produce the expected
    /// field name, for example with computed properties or protocol requirements.
    ///
    /// ```swift
    /// EventPredicate<MyPayload>(path: "order.merchantID", equals: input.merchantID)
    /// ```
    public init<V: Codable & Sendable>(path: String, equals value: V) {
        self.pathComponents = path.components(separatedBy: ".")
            .filter { !$0.isEmpty }
        self.valueBytes =
            (try? JSON.encode(value))
            .map { Array($0.readableBytesView) } ?? []
    }

    internal init(pathComponents: [String], valueBytes: [UInt8]) {
        self.pathComponents = pathComponents
        self.valueBytes = valueBytes
    }

    /// Serializes the predicate to a JSONB-compatible nested JSON byte array.
    ///
    /// `["order", "id"]` + value `"abc-123"` → `{"order":{"id":"abc-123"}}`
    ///
    /// Built from inside out using the already-encoded `valueBytes` — no
    /// `JSONSerialization` round-trip needed, works with `FoundationEssentials`.
    func toJSONBytes() throws -> [UInt8] {
        guard !pathComponents.isEmpty else { throw EventPredicateError.invalidValue }
        // JSON.encode(String) produces a quoted key, e.g. "order" → `"order"`.
        // Wrap one level at a time from the innermost component outward.
        var result = valueBytes
        for component in pathComponents.reversed() {
            guard let keyBuf = try? JSON.encode(component) else {
                throw EventPredicateError.invalidValue
            }
            result =
                [UInt8(ascii: "{")] + Array(keyBuf.readableBytesView)
                + [UInt8(ascii: ":")] + result + [UInt8(ascii: "}")]
        }
        return result
    }
}

/// Errors thrown during EventPredicate serialization.
public enum EventPredicateError: Error {
    case invalidValue
}

/// Creates a payload-equality predicate from a `KeyPath` and a concrete value.
///
/// The property path is extracted from Swift's KeyPath description string.
/// Both flat (`\.approvalId`) and shallow-nested (`\.order.id`) paths work
/// reliably in Swift 5.9+.
///
/// ```swift
/// let approval = try await context.waitForEvent(
///     "agent.approval.response",
///     as: ApprovalPayload.self,
///     matching: \.approvalId == input.approvalId
/// )
/// ```
public func == <Root, Value: Codable & Sendable>(
    lhs: KeyPath<Root, Value>,
    rhs: Value
) -> EventPredicate<Root> {
    // String(describing: \Foo.bar.baz) → "\Foo.bar.baz" in Swift 5.9+
    // Drop the first component ("\TypeName") to get the property path.
    let raw = String(describing: lhs)
    var parts = raw.components(separatedBy: ".")
    if let first = parts.first, first.hasPrefix("\\") {
        parts = Array(parts.dropFirst())
    }
    let components = parts.filter { !$0.isEmpty }
    let bytes = (try? JSON.encode(rhs)).map { Array($0.readableBytesView) } ?? []
    return EventPredicate(pathComponents: components, valueBytes: bytes)
}

// MARK: - WorkflowSignal

/// Describes a named, typed signal a workflow can receive.
///
/// Conforming types are generated automatically by the `@WorkflowSignal` macro.
/// You can also define them manually as nested types inside your workflow struct:
///
/// ```swift
/// struct OrderWorkflow: Workflow {
///     var isPaused: Bool = false
///
///     // Manual equivalent of @WorkflowSignal
///     struct Pause: WorkflowSignal {
///         typealias Input = StrandVoid
///         typealias W     = OrderWorkflow
///         static func apply(to workflow: inout OrderWorkflow, input: StrandVoid) {
///             workflow.isPaused = true
///         }
///     }
///
///     // Wire the definition into handleSignal — the @WorkflowSignal macro
///     // generates this automatically.
///     mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
///         if name == Pause.signalName {
///             Pause.apply(to: &self, input: .done)
///         }
///     }
/// }
///
/// // Type-safe call site:
/// try await handle.signal(OrderWorkflow.Pause.self)
/// ```
public protocol WorkflowSignal {
    /// The workflow type that owns this signal.
    associatedtype W: Workflow

    /// Payload type. Use `StrandVoid` for no-payload signals.
    associatedtype Input: Codable & Sendable

    /// Signal name used for dispatch. Defaults to the type name lowercased.
    static var signalName: String { get }

    /// Apply the signal to the workflow struct.
    static func apply(to workflow: inout W, input: Input)
}

extension WorkflowSignal {
    /// Default: the lowercased Swift type name (e.g. `Pause` → `"pause"`).
    public static var signalName: String {
        String(describing: Self.self).lowercased()
    }
}

// MARK: - WorkflowQuery

/// A read-only query on the current workflow state.
///
/// Apply `@WorkflowQuery` to a function inside a `@Workflow` struct to generate
/// a conforming nested struct automatically:
///
/// ```swift
/// @Workflow
/// struct OrderWorkflow {
///     var isPaused = false
///
///     @WorkflowQuery
///     func getStatus() -> OrderStatus {
///         OrderStatus(isPaused: isPaused, ...)
///     }
/// }
///
/// // Call site — reads the persisted workflow state without blocking the workflow:
/// let status = try await handle.query(OrderWorkflow.GetStatus.self)
/// ```
///
/// Queries are **read-only** and execute synchronously against the last persisted
/// state in `strand.workflow_state`. They never create a new workflow activation.
public protocol WorkflowQuery: Sendable {
    /// The workflow type this query belongs to.
    associatedtype W: Workflow
    /// The value returned by the query.
    associatedtype Output: Sendable
    /// Evaluates the query against a snapshot of the workflow state.
    static func run(workflow: W) throws -> Output
}

// MARK: - WorkflowUpdateDefinition

/// A synchronous workflow update: validates, mutates workflow state, and returns a result.
///
/// Apply `@WorkflowUpdate` to a `mutating func(input:) throws -> Output` inside a
/// `@Workflow` struct. The caller sends the update via `handle.executeUpdate(_:payload:)`
/// and awaits the typed result without creating a separate workflow activation.
///
/// ```swift
/// @Workflow
/// struct OrderWorkflow {
///     var priority = "standard"
///
///     @WorkflowUpdate
///     mutating func setPriority(input: String) throws -> String {
///         guard ["standard", "expedited"].contains(input) else {
///             throw WorkflowUpdateError("Invalid priority: \(input)")
///         }
///         let old = priority
///         priority = input
///         return "Priority changed from \(old) to \(priority)"
///     }
/// }
///
/// // Call site:
/// let msg = try await handle.executeUpdate(OrderWorkflow.SetPriority.self, payload: "expedited")
/// ```
public protocol WorkflowUpdateDefinition {
    /// The workflow type that owns this update.
    associatedtype W: Workflow
    /// Input type. Must be `Codable & Sendable`.
    associatedtype Input: Codable & Sendable
    /// Output type. Must be `Codable & Sendable`.
    associatedtype Output: Codable & Sendable
    /// Update name used for dispatch. Defaults to the function name (camelCase).
    static var updateName: String { get }
    /// Applies the update to the workflow struct and returns a result.
    static func apply(to workflow: inout W, input: Input) throws -> Output
}

extension WorkflowUpdateDefinition {
    /// Default: the function name with the first letter lowercased
    /// (e.g. `SetPriority` → `"setPriority"`).
    public static var updateName: String {
        let s = String(describing: Self.self)
        return s.prefix(1).lowercased() + s.dropFirst()
    }
}

// MARK: - WorkflowUpdateError

/// Thrown by `WorkflowHandle.update` when the workflow's `handleUpdate`
/// implementation throws a validation error.
public struct WorkflowUpdateError: Error, LocalizedError, Sendable {
    /// Human-readable description of what went wrong.
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

// MARK: - _StrandCoder

/// JSON encode/decode helpers used by `@Workflow`-generated `handleUpdate` implementations.
///
/// Underscore prefix: infrastructure detail, not part of the public API.
/// Only macro-generated code should call these methods directly.
public enum _StrandCoder {
    public static func decode<T: Decodable & Sendable>(_ type: T.Type, from buf: ByteBuffer) throws -> T {
        try JSON.decode(type, from: buf)
    }
    public static func encode<T: Encodable & Sendable>(_ value: T) throws -> ByteBuffer {
        try JSON.encode(value)
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

// MARK: - ParentClosePolicy / ChildWorkflowCancellationType

/// What happens to a child workflow when its parent workflow closes.
///
/// - `.terminate`: Terminate the child when the parent fails or is cancelled.
///   This is the default. Children that are still running are cancelled atomically
///   when the parent reaches a terminal failure state.
/// - `.abandon`: Let the child continue running independently. The child's result
///   is no longer tracked by the parent.
/// - `.requestCancel`: Send a cancellation signal to the child and let it clean up
///   gracefully before terminating.
///
/// The policy is stored in `strand.tasks.parent_close_policy` (TEXT column).
/// `.terminate` and `.abandon` are enforced by `failRun`'s recursive cascade.
/// `.requestCancel` sends a cancellation signal — enforcement planned.
public enum ParentClosePolicy: String, Sendable, Codable {
    case terminate = "TERMINATE"
    case abandon = "ABANDON"
    case requestCancel = "REQUEST_CANCEL"
}

/// How the parent workflow handles cancellation propagation to a child workflow.
///
/// - `.waitCancellationCompleted`: Wait for the child to finish or acknowledge
///   cancellation before the parent continues. Default.
/// - `.tryCancel`: Send cancellation and continue immediately.
/// - `.abandon`: Do not cancel the child when the parent is cancelled.
/// - `.terminate`: Terminate the child immediately.
public enum ChildWorkflowCancellationType: String, Sendable, Codable {
    case waitCancellationCompleted = "WAIT_CANCELLATION_COMPLETED"
    case tryCancel = "TRY_CANCEL"
    case abandon = "ABANDON"
    case terminate = "TERMINATE"
}

extension ParentClosePolicy: PostgresCodable {
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
        guard let value = ParentClosePolicy(rawValue: raw) else {
            throw PostgresDecodingError.Code.typeMismatch
        }
        self = value
    }
}

extension ChildWorkflowCancellationType: PostgresCodable {
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
        guard let value = ChildWorkflowCancellationType(rawValue: raw) else {
            throw PostgresDecodingError.Code.typeMismatch
        }
        self = value
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

    /// Explicit identifier for this child workflow execution.
    ///
    /// Used for deduplication: if a child workflow with this key already exists the
    /// existing task is returned instead of creating a new one.
    /// When `nil` (default) Strand auto-generates `"<parentTaskID>:<seqNum>"`.
    public var id: String?

    /// What happens to this child workflow when the parent fails or is cancelled.
    ///
    /// Defaults to `.terminate` — children are cancelled when the parent fails permanently.
    public var parentClosePolicy: ParentClosePolicy

    /// How the parent handles cancellation of this child workflow.
    ///
    /// Defaults to `.waitCancellationCompleted`.
    public var cancellationType: ChildWorkflowCancellationType

    public init(
        queue: String? = nil,
        priority: TaskPriority = .normal,
        maxAttempts: Int? = nil,
        headers: [String: String] = [:],
        fairnessKey: String? = nil,
        fairnessWeight: Double = 1.0,
        retryStrategy: RetryStrategy? = nil,
        delayUntil: Date? = nil,
        maxDuration: Duration? = nil,
        id: String? = nil,
        parentClosePolicy: ParentClosePolicy = .terminate,
        cancellationType: ChildWorkflowCancellationType = .waitCancellationCompleted
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
        self.id = id
        self.parentClosePolicy = parentClosePolicy
        self.cancellationType = cancellationType
    }
}
