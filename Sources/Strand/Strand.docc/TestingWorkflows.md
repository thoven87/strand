# Testing workflows

Strand ships a separate **``StrandTesting``** library with all the integration
test helpers. Add it once to your test target in `Package.swift`:

```swift
.testTarget(
    name: "MyAppTests",
    dependencies: [
        "MyApp",
        .product(name: "StrandTesting", package: "strand")
    ]
)
```

Then import it in your test files. You do **not** need `@testable import Strand`
unless you specifically need access to Strand internals.

## Integration tests

Use `withTestEnvironment` to get a client backed by a unique throwaway queue.
The queue and all its tasks are cleaned up automatically at the end of the block:

```swift
import Testing
import StrandTesting

@Test("order workflow charges card and ships", .tags(.integration))
func orderWorkflowChargesAndShips() async throws {
    try await withTestEnvironment { client in
        // withWorker starts the worker, runs the body, then calls
        // triggerGracefulShutdown() before returning — the worker is fully
        // stopped before withTestEnvironment's cleanup deletes the queue.
        try await withWorker(
            postgres: client.postgres,
            queueName: client.queueName,
            logger: client.logger,
            workflows: [OrderWorkflow.self],
            activities: [ChargeCardActivity(), ShipOrderActivity()]
        ) {
            let handle = try await client.startWorkflow(
                OrderWorkflow.self,
                input: OrderInput(amount: 99_00, orderID: "ord-1")
            )

            let snap = try await awaitTerminal(
                client: client,
                taskID: handle.taskID,
                timeout: .seconds(10)
            )
            #expect(snap.state == .completed)
        }
    }
}
```

## Helper functions

| Helper | Signature | Purpose |
|---|---|---|
| `withTestEnvironment(_:)` | `(StrandClient) async throws -> T` | Creates a unique queue, runs your test, deletes all artefacts |
| `makePostgresClient(logger:)` | `(Logger) -> PostgresClient` | Builds a client from env vars with local-dev defaults |
| `withWorker(postgres:queueName:logger:workflows:activities:_:)` | `async throws -> T` | Runs a worker for the duration of the closure; gracefully shuts it down before returning |
| `awaitTerminal(client:taskID:timeout:)` | `-> TaskResultSnapshot` | Polls until a task reaches a terminal state |
| `awaitSnapshot(_:where:timeout:label:)` | `-> TaskResultSnapshot` | Polls until a snapshot satisfies a predicate (e.g. `state == .waiting`) |
| `awaitScheduleRunCount(client:scheduleName:atLeast:timeout:)` | `async throws` | Polls until a schedule has fired at least N times |

## Tag-based filtering

All integration tests are tagged with `.integration`. Run only them:

```bash
swift test --filter integration
```

Skip them for a fast unit-test run:

```bash
swift test --skip integration
```

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `POSTGRES_HOST` | `localhost` | Postgres hostname |
| `POSTGRES_PORT` | `5499` | Postgres port |
| `POSTGRES_USER` | `strand` | Username |
| `POSTGRES_PASSWORD` | `strand` | Password |
| `POSTGRES_DB` | `strand_dev` | Database |

## Assertions

`TaskResultSnapshot` carries the terminal state and encoded result:

```swift
let snap = try await awaitTerminal(client: client, taskID: handle.taskID)
#expect(snap.state == .completed)

// Decode the result payload:
let result = try snap.decodeResult(as: OrderOutput.self)
#expect(result.trackingNumber.isEmpty == false)
```

## Testing signals

Send signals directly from the test, then verify state changes:

```swift
try await withTestEnvironment { client in
    try await withWorker(
        postgres: client.postgres,
        queueName: client.queueName,
        logger: client.logger,
        workflows: [ApprovalWorkflow.self]
    ) {
        let handle = try await client.startWorkflow(
            ApprovalWorkflow.self,
            input: ApprovalRequest(id: "req-1")
        )
        // Wait until the workflow is suspended at condition(...), then send the signal.
        try await awaitSnapshot(handle, where: { $0.state == .waiting })

        try await handle.signal(name: "approve")

        let snap = try await awaitTerminal(client: client, taskID: handle.taskID)
        #expect(snap.state == .completed)
    }
}
```
