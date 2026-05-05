# Signals and events

Two mechanisms let you send data into a running workflow from outside.

## Signals — workflow state mutations

A **signal** is a named message that mutates workflow state via
`handleSignal(name:payload:)`. The workflow calls `context.condition(...)` to
suspend until its state satisfies a predicate, then continues.

```swift
struct OrderWorkflow: Workflow {
    typealias Input  = OrderID
    typealias Output = OrderStatus

    var isPaused: Bool = false

    mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
        switch name {
        case "pause":  isPaused = true
        case "resume": isPaused = false
        default: break
        }
    }

    mutating func run(context: WorkflowContext<Self>, input: OrderID) async throws -> OrderStatus {
        // Suspend until unpaused
        try await context.condition { !$0.isPaused }
        let result = try await context.runActivity(ProcessOrderActivity.self, input: input)
        return result.status
    }
}
```

Send a signal from your application:

```swift
let handle = try await client.workflow(id: orderID, as: OrderWorkflow.self)
try await handle?.signal(name: "pause")
try await handle?.signal(name: "resume")
```

## Typed signals

For typed payloads use `decodeSignalPayload(_:from:)` inside the handler:

```swift
struct OrderWorkflow: Workflow {
    var priority: ShippingPriority = .standard

    mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
        switch name {
        case "set-priority":
            if let p = try decodeSignalPayload(ShippingPriority.self, from: payload) {
                priority = p
            }
        default: break
        }
    }
}

// Send a signal with a payload:
let handle = try await client.workflow(id: orderID, as: OrderWorkflow.self)
try await handle?.signal(name: "set-priority", payload: ShippingPriority.expedited)
```

### Type-safe signal definitions

Implement ``WorkflowSignalDefinition`` for compile-time safety at the call site:

```swift
extension OrderWorkflow {
    struct SetPriority: WorkflowSignalDefinition {
        typealias W     = OrderWorkflow
        typealias Input = ShippingPriority
        static let signalName = "set-priority"
        static func apply(to workflow: inout OrderWorkflow, input: ShippingPriority) {
            workflow.priority = input
        }
    }

    struct Pause: WorkflowSignalDefinition {
        typealias W     = OrderWorkflow
        typealias Input = StrandVoid
        static func apply(to workflow: inout OrderWorkflow, input: StrandVoid) {
            workflow.isPaused = true
        }
    }
}

// Type-safe call sites:
try await handle?.signal(OrderWorkflow.Pause.self)                          // no payload
try await handle?.signal(OrderWorkflow.SetPriority.self, payload: .expedited) // typed
```

## Events — queue-based wakeup

An **event** is emitted onto a queue and wakes any workflow waiting for it.
Events are cached — the first emit wins, so a workflow that starts waiting
after the event fires still receives it.

```swift
// Inside a workflow:
let shipment = try await context.waitForEvent(
    "shipment.packed",
    as: ShipmentInfo.self,
    timeout: .hours(48)    // fail if not received within 48 hours
)
```

Emit from outside (e.g. a webhook handler):

```swift
try await client.emitEvent(
    "shipment.packed",
    payload: ShipmentInfo(trackingNumber: "1Z999"),
    queue: "orders"
)
```

### Typed events

Define a ``WorkflowEvent`` type so both sides are checked by the compiler:

```swift
struct ShipmentPackedEvent: WorkflowEvent {
    typealias Payload = ShipmentInfo
    static let name   = "shipment.packed"
}

// In the workflow:
let shipment = try await context.waitForEvent(ShipmentPackedEvent.self,
                                               timeout: .hours(48))

// Emit from the client:
try await client.emit(ShipmentPackedEvent.self,
                      payload: ShipmentInfo(trackingNumber: "1Z999"),
                      queue: "orders")
```

## condition — suspend on arbitrary state

`context.condition(_:)` suspends the workflow until the predicate on the
workflow's own state returns `true`:

```swift
// Resume only when all items are approved
try await context.condition { $0.approvedCount >= $0.requiredApprovals }

// With timeout — throws StrandError.timeout if not satisfied in time
try await context.condition({ $0.approved }, timeout: .hours(24))
```

A practical use of this pattern is a **deployment approval gate**: the pipeline
workflow suspends after the build stage and waits indefinitely for an operator
to send an `approve` signal before proceeding to deploy. If the process is
restarted while waiting, the workflow resumes at exactly this suspension point.
See <doc:Examples#CIPipeline-—-durable-CI/CD-with-an-approval-gate> for the
full working example.
