# Testing workflows

Strand provides integration test helpers in `TestHelpers.swift` that run against
a real local Postgres instance.

## Integration tests

Use `withTestEnvironment` to get a client backed by a unique throwaway queue.
The queue and all its tasks are cleaned up automatically at the end of the block:

```swift
import Testing
@testable import Strand

@Test("order workflow charges card and ships", .tags(.integration))
func orderWorkflowChargesAndShips() async throws {
    try await withTestEnvironment { client in
        // makePostgresClient reads env vars with local-dev defaults:
        //   POSTGRES_HOST=localhost POSTGRES_PORT=5499
        //   POSTGRES_USER=strand    POSTGRES_PASSWORD=strand
        //   POSTGRES_DB=strand_dev
        let postgres = makePostgresClient(logger: Logger(label: "test"))
        let pgTask = Task { await postgres.run() }
        defer { pgTask.cancel() }
        try await Task.sleep(for: .milliseconds(100))

        let workerTask = startWorker(
            postgres: postgres,
            queueName: client.queueName,
            logger: Logger(label: "test.worker"),
            workflows: [OrderWorkflow.self],
            activities: [ChargeCardActivity(), ShipOrderActivity()]
        )
        defer { workerTask.cancel() }

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
```

## Helper functions

| Helper | Signature | Purpose |
|---|---|---|
| `withTestEnvironment(_:)` | `(StrandClient) async throws -> T` | Creates a unique queue, runs your test, deletes all artefacts |
| `makePostgresClient(logger:)` | `(Logger) -> PostgresClient` | Builds a client from env vars with local-dev defaults |
| `startWorker(postgres:queueName:logger:workflows:activities:)` | — | Launches a worker in a background `Task`; cancel to stop |
| `awaitTerminal(client:taskID:timeout:)` | `-> TaskResultSnapshot` | Polls until a task reaches a terminal state |

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
    // ... start worker ...
    let handle = try await client.startWorkflow(
        ApprovalWorkflow.self,
        input: ApprovalRequest(id: "req-1")
    )
    // Let the workflow reach the condition(...) suspension
    try await Task.sleep(for: .milliseconds(200))

    try await handle.signal(name: "approve")

    let snap = try await awaitTerminal(client: client, taskID: handle.taskID)
    #expect(snap.state == .completed)
}
```
