# Signals, Queries, Updates, and Events

Four mechanisms let external code communicate with a running workflow.

## Signals — fire-and-forget state mutations

A **signal** mutates workflow state between activations. The workflow uses
`context.condition(...)` to gate on that state. Signals can arrive at any
point — while the workflow is running activities, sleeping, or waiting — without
requiring an explicit suspension point.

Use `@WorkflowSignal` on a `mutating func` inside a `@Workflow` struct. The
`@Workflow` macro generates the typed dispatch and `handleSignal` automatically:

```swift
@Workflow
struct OrderWorkflow {
    var isPaused = false
    var priority = "standard"

    @WorkflowSignal mutating func pause()          { isPaused = true  }
    @WorkflowSignal mutating func resume()         { isPaused = false }
    @WorkflowSignal mutating func setPriority(_ p: String) { priority = p }

    mutating func run(context: WorkflowContext<Self>, input: OrderID) async throws -> OrderStatus {
        try await context.condition { !$0.isPaused }
        // ...
    }
}
```

Send a signal from your application:

```swift
try await handle.signal(OrderWorkflow.Pause.self)           // no payload
try await handle.signal(OrderWorkflow.SetPriority.self,
                         payload: "expedited")               // typed payload
```

The signal name defaults to the function name (camelCase): `"pause"`, `"setPriority"`.
Override it with `@WorkflowSignal(name: "my-name")` only when you need a different wire name.

> Note: Unlike ``WorkflowContext/waitForEvent(_:as:timeout:)``, signals are
> delivered regardless of what the workflow is currently doing — there is no
> explicit suspension point required.

## Updates — synchronous mutations that return a result

An **update** is like a signal but the caller awaits a typed result (or a
validation error). Use `@WorkflowUpdate` on a `mutating func(input:) throws -> Output`:

```swift
@Workflow
struct OrderWorkflow {
    var priority = "standard"
    var currentState = "processing"

    @WorkflowUpdate
    mutating func setPriority(input: String) throws -> String {
        guard currentState != "shipping" else {
            throw WorkflowUpdateError("Cannot change priority after shipping has started")
        }
        let old = priority
        priority = input
        return "Priority changed from \(old) to \(priority)"
    }
}
```

Await the result from your application:

```swift
let message = try await handle.update(OrderWorkflow.SetPriority.self,
                                       payload: "expedited")
print(message)  // "Priority changed from standard to expedited"
```

## Queries — read-only state inspection

A **query** reads the last persisted workflow state without blocking or
activating the workflow. Use `@WorkflowQuery` on a no-parameter function that
returns a value:

```swift
@Workflow
struct OrderWorkflow {
    var isPaused = false
    var currentState = "processing"

    struct OrderStatus: Codable, Sendable {
        let isPaused: Bool
        let currentState: String
    }

    @WorkflowQuery
    func getStatus() -> OrderStatus {
        OrderStatus(isPaused: isPaused, currentState: currentState)
    }
}
```

Read the state from your application:

```swift
let status = try await handle.query(OrderWorkflow.GetStatus.self)
print(status.isPaused)      // false
print(status.currentState)  // "processing"
```

Queries read from `strand.workflow_state` — the last snapshot saved when signals
were delivered or the workflow completed. If queried before the first state save
(e.g. before any signal arrives), the workflow's declared default values are
returned.

## Events — queue-based wakeup

An **event** is emitted onto a queue and wakes any workflow explicitly waiting
for it via ``WorkflowContext/waitForEvent(_:as:timeout:)``. Unlike signals, the
workflow must reach a `waitForEvent` suspension point to receive an event.
Events are persisted — a workflow that starts waiting after the event fires still
receives it.

```swift
// Inside a workflow — waits forever until the event arrives:
let approval = try await context.waitForEvent("order.approved",
                                               as: ApprovalDecision.self)

// With timeout — returns nil when the deadline elapses (not an error):
if let approval = try await context.waitForEvent("order.approved",
                                                  as: ApprovalDecision.self,
                                                  timeout: .hours(24)) {
    // received
} else {
    // timed out — take the SLA-elapsed path
}
```

Emit from outside:

```swift
try await client.emitEvent("order.approved",
                            payload: ApprovalDecision(approved: true),
                            queue: "orders")
```

### Typed events with `matching:` predicate

Define a ``WorkflowEvent`` type to get compiler-checked names and routing. The
`matching:` predicate lets multiple concurrent workflow instances share the same
event name — Postgres evaluates `payload @> predicate` at emission time via a
GIN index:

```swift
struct OrderApprovedEvent: WorkflowEvent {
    typealias Payload = ApprovalDecision
    static let name = "order.approved"
}

// In the workflow — only wakes on the event whose orderId matches:
let approval = try await context.waitForEvent(
    OrderApprovedEvent.self,
    matching: \.orderId == input.orderId,
    timeout: .hours(24)
)

// Emit from the client — predicate routing happens in Postgres:
try await client.emit(OrderApprovedEvent.self,
                      payload: ApprovalDecision(orderId: "abc-123", approved: true))
```

## When to use each

| Need | Use |
|---|---|
| Mutate state at any point (pause, cancel, update priority) | `@WorkflowSignal` |
| Mutate state and get a confirmation / validation error back | `@WorkflowUpdate` |
| Read current state without blocking the workflow | `@WorkflowQuery` |
| Wait for a human approval or external service callback | `waitForEvent` |

## condition — suspend on arbitrary state

`context.condition(_:)` suspends the workflow until the predicate on the
workflow's own state returns `true`. Signals mutate that state; `condition`
detects the change:

```swift
// Suspend until unpaused or cancelled:
try await context.condition { !$0.isPaused || $0.isCancelled }

// With timeout — returns false when the deadline elapses, not an error:
let approved = try await context.condition({ $0.isApproved }, timeout: .hours(24))
if !approved { /* SLA elapsed — auto-approve or escalate */ }
```

A common pattern is a **deployment approval gate**: the workflow suspends after
the build stage, an operator sends an `approve` signal, and the workflow
resumes at exactly this suspension point even across worker restarts.
