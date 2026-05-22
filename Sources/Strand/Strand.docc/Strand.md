# ``Strand``

Postgres-native durable workflow engine for Swift.

## Overview

Strand runs workflows to completion even when worker processes crash. All state
lives in Postgres — no separate coordination service, no message broker.

A workflow is a Swift struct. When it calls `context.runActivity(...)` the
activity is enqueued as an independent task, the workflow suspends, and a worker
picks up the activity. When the activity completes the workflow resumes from
where it left off. Already-completed steps return instantly from a checkpoint
cache and never re-execute.

```swift
struct OrderWorkflow: Workflow {
    typealias Input  = OrderInput
    typealias Output = ShipResult

    mutating func run(
        context: WorkflowContext<Self>,
        input: OrderInput
    ) async throws -> ShipResult {
        let charge = try await context.runActivity(
            ChargeCardActivity.self,
            input: .init(amount: input.amount)
        )
        return try await context.runActivity(
            ShipOrderActivity.self,
            input: .init(paymentID: charge.paymentID)
        )
    }
}
```

## Topics

### Getting started
- <doc:GettingStarted>

### Core concepts
- <doc:Concepts>
- <doc:Activities>
- <doc:Workflows>

### How-to guides
- <doc:Scheduling>
- <doc:Timetables>
- <doc:SignalsAndEvents>
- <doc:RetryStrategies>
- <doc:VersioningGuide>
- <doc:TestingWorkflows>

### Recipes
- <doc:BuildingDataPipelines>

### Examples
- <doc:Examples>

### Operations
- <doc:WorkerTuning>
- <doc:Migrations>
- <doc:BootOrder>
