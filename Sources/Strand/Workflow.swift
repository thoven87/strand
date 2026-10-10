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

// MARK: - WorkflowRegistrable

/// Marker protocol that enables workflow types in the `workflows:` array.
///
/// Every type conforming to ``Workflow`` automatically satisfies this protocol.
/// You never need to implement it manually.
public protocol WorkflowRegistrable: Sendable {
    /// The task name used for DB dispatch. Defaults to the Swift type name.
    static var workflowName: String { get }

}

extension WorkflowRegistrable {
    /// Package-internal — not part of the public protocol surface.
    /// Called by `StrandClient.startWorkflow` when `WorkflowOptions.id` is nil.
    /// Users customise the workflow ID by passing `WorkflowOptions(id: "my-id")`.
    ///
    /// Format: `"<WorkflowName>-<epochMs>"` —
    /// e.g. `"OrderWorkflow-1746218580123"`.
    ///
    /// The epoch-millisecond suffix keeps IDs time-ordered and human-scannable.
    /// Millisecond precision is sufficient for distinct workflow instances; if you
    /// need strict uniqueness within the same millisecond supply an explicit
    /// `WorkflowOptions(id:)` instead.
    static func generateWorkflowID() -> String {
        let ms = Int(Date.now.timeIntervalSince1970 * 1000)
        return "\(workflowName)-\(ms)"
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
    associatedtype Output: Sendable

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
        return try _StrandCodecContext.codec.decode(type, from: buf)
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
    /// JSON-encoded value buffer (e.g. `"\"abc-123\""` for a String).
    let valueBytes: ByteBuffer

    /// Creates a predicate with an explicit dot-path string.
    ///
    /// Use this when `String(describing: keyPath)` doesn't produce the expected
    /// field name, for example with computed properties or protocol requirements.
    ///
    /// ```swift
    /// EventPredicate<MyPayload>(path: "order.merchantID", equals: input.merchantID)
    /// ```
    public init<V: Codable & Sendable>(path: String, equals value: V) {
        self.pathComponents = path.components(separatedBy: ".").filter { !$0.isEmpty }
        self.valueBytes = (try? JSON.encode(value)) ?? ByteBuffer()
    }

    internal init(pathComponents: [String], valueBytes: ByteBuffer) {
        self.pathComponents = pathComponents
        self.valueBytes = valueBytes
    }

    /// Serialises the predicate to a JSONB-compatible `ByteBuffer`.
    ///
    /// `["order", "id"]` + value `"abc-123"` → `{"order":{"id":"abc-123"}}`
    ///
    /// Single allocation: opens all braces left-to-right, writes the value,
    /// then closes all braces — O(N) byte copies regardless of nesting depth.
    func toPredicateBuffer() throws -> ByteBuffer {
        guard !pathComponents.isEmpty else { throw EventPredicateError.invalidValue }
        var buf = JSON.allocator.buffer(
            capacity: valueBytes.readableBytes + pathComponents.count * 8
        )
        // Write {"key": for each path component left-to-right.
        for component in pathComponents {
            guard let keyBuf = try? JSON.encode(component) else {
                throw EventPredicateError.invalidValue
            }
            buf.writeInteger(UInt8(ascii: "{"))
            buf.writeImmutableBuffer(keyBuf)
            buf.writeInteger(UInt8(ascii: ":"))
        }
        // Write the encoded value then close all braces.
        buf.writeImmutableBuffer(valueBytes)
        for _ in pathComponents { buf.writeInteger(UInt8(ascii: "}")) }
        return buf
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
    var parts = String(describing: lhs).components(separatedBy: ".")
    if parts.first?.hasPrefix("\\") == true { parts.removeFirst() }
    let components = parts.filter { !$0.isEmpty }
    let valueBytes = (try? JSON.encode(rhs)) ?? ByteBuffer()
    return EventPredicate(pathComponents: components, valueBytes: valueBytes)
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
///         typealias Input = Void
///         typealias W     = OrderWorkflow
///         static func apply(to workflow: inout OrderWorkflow, input: Void) {
///             workflow.isPaused = true
///         }
///     }
///
///     // Wire the definition into handleSignal — the @WorkflowSignal macro
///     // generates this automatically.
///     mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
///         if name == Pause.signalName {
///             Pause.apply(to: &self, input: ())
///         }
///     }
/// }
///
/// // Type-safe call site:
/// try await handle.signal(OrderWorkflow.Pause.self)
/// ```
/// Policy controlling what happens when a workflow exits while a signal or
/// update handler is still in progress.
///
/// Assign this on a per-handler basis via the `unfinishedPolicy` requirement
/// on ``WorkflowSignal`` and ``WorkflowUpdateDefinition``.
public struct HandlerUnfinishedPolicy: Sendable, Equatable {
    package enum Kind: Sendable, Equatable {
        case warnAndAbandon
        case abandon
    }
    package let kind: Kind
    private init(_ kind: Kind) { self.kind = kind }

    /// Log a warning when the workflow exits with this handler still running.
    ///
    /// This is the default. The warning names the handler and suggests
    /// `condition { context.allHandlersFinished }` as the remedy.
    public static let warnAndAbandon = HandlerUnfinishedPolicy(.warnAndAbandon)

    /// Silently abandon this handler when the workflow exits.
    ///
    /// Use when it is expected and acceptable for the handler to be
    /// interrupted by workflow completion — for example a fire-and-forget
    /// notification signal that need not complete before CAN.
    public static let abandon = HandlerUnfinishedPolicy(.abandon)
}

@_documentation(visibility: internal)
public protocol WorkflowSignal {
    /// The workflow type that owns this signal.
    associatedtype W: Workflow

    /// Payload type. Use `Void` for no-payload signals.
    associatedtype Input: Sendable

    /// Signal name used for dispatch. Defaults to the type name lowercased.
    static var signalName: String { get }

    /// What to do when the workflow exits while this handler is still running.
    /// Defaults to ``HandlerUnfinishedPolicy/warnAndAbandon``.
    static var unfinishedPolicy: HandlerUnfinishedPolicy { get }

    /// Apply the signal to the workflow struct.
    static func apply(to workflow: inout W, input: Input)
}

extension WorkflowSignal {
    /// Default: the lowercased Swift type name (e.g. `Pause` → `"pause"`).
    public static var signalName: String {
        String(describing: Self.self).lowercased()
    }
    public static var unfinishedPolicy: HandlerUnfinishedPolicy { .warnAndAbandon }
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
@_documentation(visibility: internal)
public protocol WorkflowQuery: Sendable {
    /// The workflow type this query belongs to.
    associatedtype W: Workflow
    /// The value returned by the query.
    associatedtype Output: Sendable
    /// Wire name used for display and introspection. Defaults to the struct name
    /// with the first letter lowercased (e.g. `GetStatus` → `"getStatus"`).
    static var queryName: String { get }
    /// Evaluates the query against a snapshot of the workflow state.
    static func run(workflow: W) throws -> Output
}

extension WorkflowQuery {
    public static var queryName: String {
        let s = String(describing: Self.self)
        return s.prefix(1).lowercased() + s.dropFirst()
    }
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
@_documentation(visibility: internal)
public protocol WorkflowUpdateDefinition {
    /// The workflow type that owns this update.
    associatedtype W: Workflow
    /// Input type. Must be `Codable & Sendable`.
    associatedtype Input: Codable & Sendable
    /// Output type.
    associatedtype Output: Sendable
    /// Update name used for dispatch. Defaults to the function name (camelCase).
    static var updateName: String { get }
    /// What to do when the workflow exits while this handler is still running.
    /// Defaults to ``HandlerUnfinishedPolicy/warnAndAbandon``.
    static var unfinishedPolicy: HandlerUnfinishedPolicy { get }
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
    public static var unfinishedPolicy: HandlerUnfinishedPolicy { .warnAndAbandon }
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
        try _StrandCodecContext.codec.decode(type, from: buf)
    }
    public static func encode<T: Encodable & Sendable>(_ value: T) throws -> ByteBuffer {
        try _StrandCodecContext.codec.encode(value)
    }
}

// MARK: - ActivityContainerProtocol

/// Groups related activities that share common dependencies (e.g. an HTTP client).
///
/// ```swift
/// struct PaymentActivities: ActivityContainerProtocol {
///     let stripe: StripeClient
///
///     var activities: [any Activity] {
///         [ChargeCardActivity(stripe: stripe),
///          RefundCardActivity(stripe: stripe)]
///     }
/// }
/// ```
@_documentation(visibility: internal)
public protocol ActivityContainerProtocol: Sendable {
    var activities: [any Activity] { get }
}

// MARK: - ArcBox

/// Reference-counted workflow state wrapper. One allocation per workflow lifetime.
///
/// `T: Sendable` is required so the compiler verifies that boxed values are
/// safe to cross concurrency boundaries. `nonisolated(unsafe)` on `value` then
/// suppresses the additional isolation check for that stored property, relying
/// on the surrounding invariant (single async task per activation, no concurrent
/// access) for safety beyond what the compiler can verify automatically.
public final class ArcBox<T: Sendable>: Sendable {
    nonisolated(unsafe) public var value: T
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

    /// Human-readable description for this execution — shown in the Loom
    /// dashboard.  Stored in the `strand.tasks.description` column; `nil` stores nothing.
    public var description: String?

    /// Optional rate limit applied when this workflow is started.
    /// Useful when many workflows are started in a batch and you want to
    /// control the enqueue rate (e.g. max 10 workflow starts per second).
    public var rateLimit: RateLimit?

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
        maxDuration: Duration? = nil,
        description: String? = nil,
        rateLimit: RateLimit? = nil
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
        self.description = description
        self.rateLimit = rateLimit
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
    /// The parent waits for the child activity to acknowledge cancellation before
    /// proceeding. The RUNNING run is preserved so the activity can perform cleanup;
    /// `context.isCancelled` is set to `true` via the heartbeat mechanism.
    case waitCancellationCompleted = "WAIT_CANCELLATION_COMPLETED"
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

    /// Human-readable display label for this child workflow.
    ///
    /// When set, this string is stored in `strand.tasks.description` and shown
    /// as the workflow label in the Loom UI. It does **not** change the
    /// idempotency key — Strand always derives that from `"<parentTaskUUID>:<seqNum>"`
    /// so that `loadCompletedChildActivities` can extract the sequence number
    /// and route the result back to the correct continuation on replay.
    ///
    /// Using this field for deduplication (e.g. "only start one billing child")
    /// is **not** supported: only one child per seqNum can exist per parent run
    /// by construction, and the auto-generated key already ensures idempotent
    /// replay across activations.
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
