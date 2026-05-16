// NIOCore is re-exported from Strand via @_exported import, so ByteBuffer is available
// to all Strand consumers without a separate `import NIOCore`.

// MARK: - @WorkflowSignal

/// Synthesises a `WorkflowSignal`-conforming nested struct for this signal method.
///
/// Apply to a `mutating func` with 0 or 1 parameters inside a workflow struct:
///
/// ```swift
/// struct ShippingWorkflow: Workflow {
///     var isPaused = false
///     var priority: Priority = .normal
///
///     // 0-param signal  →  generates struct Pause
///     @WorkflowSignal
///     mutating func pause() { isPaused = true }
///
///     // 1-param signal  →  generates struct SetPriority
///     @WorkflowSignal(name: "set-priority")
///     mutating func setPriority(_ p: Priority) { priority = p }
/// }
/// ```
///
/// The generated struct name is the function name with the first letter uppercased:
/// `pause` → `Pause`, `setPriority` → `SetPriority`.
///
/// The `name:` argument overrides the signal name used at the call site.
/// Without it the default is the lowercased struct name (e.g. `"pause"`, `"setpriority"`).
@attached(peer, names: arbitrary)
public macro WorkflowSignal(name: String? = nil) =
    #externalMacro(module: "StrandMacrosPlugin", type: "WorkflowSignalMacro")

// MARK: - @WorkflowQuery

/// Generates a `WorkflowQuery`-conforming nested struct for this read-only query function.
///
/// Apply to a parameter-less `func` that returns a value inside a `@Workflow` struct.
/// The function reads (but does not mutate) `self` — it is evaluated synchronously
/// against the last persisted state in `strand.workflow_state`.
///
/// ```swift
/// @Workflow
/// struct OrderWorkflow {
///     var isPaused = false
///     var priority = "standard"
///
///     @WorkflowQuery
///     func getStatus() -> OrderStatus {
///         OrderStatus(isPaused: isPaused, priority: priority)
///     }
/// }
///
/// // Call site:
/// let status = try await handle.query(OrderWorkflow.GetStatus.self)
/// ```
@attached(peer, names: arbitrary)
public macro WorkflowQuery() =
    #externalMacro(module: "StrandMacrosPlugin", type: "WorkflowQueryMacro")

// MARK: - @WorkflowUpdate

/// Generates a `WorkflowUpdateDefinition`-conforming nested struct for this update function.
///
/// Apply to a `mutating func(input:) throws -> Output` inside a `@Workflow` struct.
/// Unlike `@WorkflowSignal`, the caller awaits the result synchronously via
/// `handle.executeUpdate(_:payload:)`. The update is delivered as a signal and
/// the result is published via `strand.events` — no new DB table required.
///
/// ```swift
/// @Workflow
/// struct OrderWorkflow {
///     var priority = "standard"
///
///     @WorkflowUpdate
///     mutating func setPriority(input: String) throws -> String {
///         guard ["standard", "expedited", "overnight"].contains(input) else {
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
/// print(msg)  // "Priority changed from standard to expedited"
/// ```
@attached(peer, names: arbitrary)
public macro WorkflowUpdate() =
    #externalMacro(module: "StrandMacrosPlugin", type: "WorkflowUpdateMacro")

// MARK: - @Workflow

/// Adds `Workflow` protocol conformance and synthesises `handleSignal(name:payload:)`
/// from every `@WorkflowSignal`-annotated method and `handleUpdate(name:correlationID:payload:)`
/// from every `@WorkflowUpdate`-annotated method in the workflow struct.
///
/// Write `@Workflow struct Foo` instead of `struct Foo: Workflow` — the macro
/// adds the conformance via an extension so the struct declaration stays clean.
///
/// ```swift
/// @Workflow
/// struct ShippingWorkflow {
///     @WorkflowSignal mutating func pause() { isPaused = true }
///     @WorkflowSignal mutating func resume() { isPaused = false }
/// }
/// // generates:
/// // extension ShippingWorkflow: Workflow {}
/// // mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
/// //     switch name {
/// //     case Pause.signalName: Pause.apply(to: &self, input: .done)
/// //     case Resume.signalName: Resume.apply(to: &self, input: .done)
/// //     default: break
/// //     }
/// // }
/// ```
@attached(extension, conformances: Workflow, names: arbitrary)
@attached(member, names: named(handleSignal), named(handleUpdate), named(init))
public macro Workflow() =
    #externalMacro(module: "StrandMacrosPlugin", type: "WorkflowMacro")

// MARK: - @ContainerActivity

/// Marks a stored property as an activity managed by an `@ActivityContainer` struct.
///
/// The `@ActivityContainer` extension macro on the enclosing struct collects all
/// `@ContainerActivity`-annotated properties into the `activities: [any ActivityBox]` array.
///
/// ```swift
/// @ActivityContainer
/// struct PaymentActivities {
///     @ContainerActivity var charge: ChargeCardActivity
///     @ContainerActivity var refund: RefundCardActivity
/// }
/// ```
@attached(peer)
public macro ContainerActivity() =
    #externalMacro(module: "StrandMacrosPlugin", type: "ContainerActivityMacro")

// MARK: - @Activity

/// Marks a method as an activity inside an `@ActivityContainer` struct.
/// The `@ActivityContainer` macro reads this annotation to generate a nested
/// `Activity`-conforming struct that captures the container as `_container`.
///
/// ```swift
/// @ActivityContainer
/// struct OllamaActivities {
///     let ollama: OllamaClient
///
///     @Activity
///     func classify(input: ClassifyInput, context: ActivityContext) async throws -> ClassifyOutput {
///         try await ollama.chatJSON(system: "...", user: "...", as: ClassifyOutput.self)
///     }
/// }
/// // Accessible as: OllamaActivities.Classify.self
/// ```
@attached(peer)
public macro Activity() =
    #externalMacro(module: "StrandMacrosPlugin", type: "ActivityMacro")

// MARK: - @ActivityContainer

/// Synthesises `ActivityContainerProtocol` conformance from `@ContainerActivity` properties.
///
/// ```swift
/// @ActivityContainer
/// struct PaymentActivities {
///     @ContainerActivity var charge: ChargeCardActivity
///     @ContainerActivity var refund: RefundCardActivity
/// }
/// // generates:
/// // extension PaymentActivities: ActivityContainerProtocol {
/// //     var activities: [any ActivityBox] {
/// //         [charge, refund]
/// //     }
/// // }
/// ```
@attached(extension, conformances: ActivityContainerProtocol, names: arbitrary)
public macro ActivityContainer() =
    #externalMacro(module: "StrandMacrosPlugin", type: "ActivityContainerMacro")
