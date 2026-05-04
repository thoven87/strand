# Writing workflows

Workflows orchestrate activities. They are durable: if the process crashes
mid-execution the next worker replays from the last checkpoint.

## Struct-based definition

Conform to ``Workflow`` and implement `run(context:input:)`:

```swift
struct OrderFulfillmentWorkflow: Workflow {
    typealias Input  = OrderInput
    typealias Output = FulfillmentResult

    mutating func run(
        context: WorkflowContext<Self>,
        input: OrderInput
    ) async throws -> FulfillmentResult {
        // Each activity is a checkpoint.
        // If the process restarts here, chargeResult loads from the checkpoint cache.
        let chargeResult = try await context.runActivity(
            ChargeCardActivity.self,
            input: .init(amount: input.total)
        )
        let shipResult = try await context.runActivity(
            ShipOrderActivity.self,
            input: .init(paymentID: chargeResult.paymentID)
        )
        return FulfillmentResult(
            orderID: input.orderID,
            trackingNumber: shipResult.trackingNumber
        )
    }
}
```

## Parallel activities

Use Swift's structured concurrency to fan out:

```swift
async let invoice = context.runActivity(GenerateInvoiceActivity.self, input: orderID)
async let email   = context.runActivity(SendConfirmationActivity.self, input: orderID)
let (inv, _)      = try await (invoice, email)
```

Or `withThrowingTaskGroup` for dynamic fan-out over a collection:

```swift
var results: [ChunkResult] = []
try await withThrowingTaskGroup(of: ChunkResult.self) { group in
    for chunk in chunks {
        group.addTask {
            try await context.runActivity(ProcessChunkActivity.self, input: chunk)
        }
    }
    for try await result in group { results.append(result) }
}
```

## Sleeping

Suspend the workflow until a point in time. The worker slot is freed during sleep.

```swift
try await context.sleep(for: .hours(24))
try await context.sleep(until: nextBusinessDay)
```

## Waiting for events

```swift
// Suspend until an external system emits "payment.confirmed"
let confirmation = try await context.waitForEvent(
    "payment.confirmed",
    as: PaymentConfirmation.self,
    timeout: .hours(48)
)
```

Emit from outside the workflow:

```swift
try await client.emitEvent("payment.confirmed",
                            payload: PaymentConfirmation(id: "pay_123"),
                            queue: "orders")
```

## Mutable workflow state

Declare `var` properties on the struct to carry state across activations:

```swift
struct ApprovalWorkflow: Workflow {
    typealias Input  = ApprovalRequest
    typealias Output = ApprovalDecision

    var approved: Bool = false

    mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
        if name == "approve" { approved = true  }
        if name == "reject"  { approved = false }
    }

    mutating func run(
        context: WorkflowContext<Self>,
        input: ApprovalRequest
    ) async throws -> ApprovalDecision {
        try await context.condition { $0.approved }
        return ApprovalDecision(approved: approved, requestID: input.id)
    }
}
```

Signal from a web handler:

```swift
let handle = try await client.workflow(id: "approval-\(requestID)", as: ApprovalWorkflow.self)
try await handle?.signal(name: "approve")
```

## Versioning (safe deploys)

Use `context.version(changeID:)` when changing workflow logic in a deployed
system. In-flight workflows replay their original path; new executions take
the updated path:

```swift
if try context.version(changeID: "add-fraud-check") {
    _ = try await context.runActivity(FraudCheckActivity.self, input: input)
}
```

## Child workflows

Spawn a sub-workflow and await its result:

```swift
let report = try await context.runChildWorkflow(
    DailyReportWorkflow.self,
    options: ChildWorkflowOptions(queue: "analytics"),
    input: ReportInput(date: today)
)
```

## Continue-as-new

Reset the workflow's history to prevent unbounded checkpoint growth in
long-running loops:

```swift
mutating func run(context: WorkflowContext<Self>, input: LoopInput) async throws -> Never {
    _ = try await context.runActivity(ProcessBatchActivity.self, input: input)
    try context.continueAsNew(input: LoopInput(cursor: input.nextCursor))
}
```

## Deterministic helpers

Use these context methods instead of their non-deterministic Swift equivalents:

| Instead of | Use |
|---|---|
| `Date.now` | `context.activationTime` |
| `UUID()` | `try context.uuid()` |
| `Int.random(in:)` | `try context.random(in:)` |
