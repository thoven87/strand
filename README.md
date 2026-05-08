<p align="center">
  <img src="logo.svg" width="128" alt="Strand">
</p>

<h1 align="center">Strand</h1>

<p align="center"><strong>Postgres-native durable workflow engine for Swift 6.3.</strong></p>

No separate coordination service. No Redis. No Cassandra. Just Swift workers and Postgres.

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

If a worker crashes mid-workflow the next worker that picks it up resumes from the last checkpoint. No work is duplicated, no state is lost.

<p align="center">
  <img src="loom/screenshot.png" alt="Strand dashboard" width="900">
</p>

## Documentation

- **[Getting started](Sources/Strand/Strand.docc/GettingStarted.md)** — installation, first workflow, first worker
- **[Core concepts](Sources/Strand/Strand.docc/Concepts.md)** — execution model, checkpointing, determinism
- **[Activities](Sources/Strand/Strand.docc/Activities.md)** — I/O, retries, heartbeats, timeouts
- **[Workflows](Sources/Strand/Strand.docc/Workflows.md)** — orchestration, fan-out, sleep, signals
- **[Scheduling](Sources/Strand/Strand.docc/Scheduling.md)** — cron, intervals, catch-up
- **[Signals and events](Sources/Strand/Strand.docc/SignalsAndEvents.md)** — external wakeup
- **[Retry strategies](Sources/Strand/Strand.docc/RetryStrategies.md)** — backoff, non-retryable errors, deadlines
- **[Testing](Sources/Strand/Strand.docc/TestingWorkflows.md)** — integration test helpers
- **[Data pipelines](Sources/Strand/Strand.docc/BuildingDataPipelines.md)** — fan-out, multi-queue, crash recovery

## Quick start

### 1. Start Postgres

```yaml
# docker-compose.yml
services:
  db:
    image: postgres:18-alpine
    environment:
      POSTGRES_USER: strand
      POSTGRES_PASSWORD: strand
      POSTGRES_DB: strand_dev
    ports:
      - "5499:5432"
```

```bash
docker compose up -d
psql "postgresql://strand:strand@localhost:5499/strand_dev" -f strand.sql
```

### 2. Add to `Package.swift`

```swift
.package(url: "https://github.com/thoven87/strand", from: "0.1.0"),
```

### 3. Run

```swift
import Strand
import ServiceLifecycle

let postgres = PostgresClient(configuration: .init(
    host: "localhost", port: 5499,
    username: "strand", password: "strand",
    database: "strand_dev", tls: .disable
))
let client = StrandClient(postgres: postgres, queue: "default")
let worker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(queue: "default"),
    workflows: [OrderWorkflow.self],
    activities: [ChargeCardActivity(), ShipOrderActivity()]
)
let group = ServiceGroup(configuration: .init(
    services: [.init(service: postgres), .init(service: worker)],
    gracefulShutdownSignals: [.sigterm, .sigint]
))

// Start a workflow — returns a handle you can poll for the result:
let handle = try await client.startWorkflow(
    OrderWorkflow.self,
    input: OrderInput(amount: 99_00, orderID: "ord-1")
)

try await group.run()
```

## Scheduling

Declare recurring schedules directly on ``StrandScheduler`` — they are upserted
to the database when the service starts:

```swift
let scheduler = StrandScheduler(
    client: client,
    schedules: [
        .workflow(
            "daily-report",
            pattern: .daily(offset: "PT9H"),          // 09:00 UTC every day
            workflowType: DailyReportWorkflow.self,
            input: ReportInput()
        ),
        .workflow(
            "market-open",
            pattern: .cron("30 8 * * 1-5",
                           timezone: TimeZone(identifier: "America/New_York")!),
            workflowType: MarketOpenWorkflow.self,
            input: StrandVoid()
        ),
    ]
)

let group = ServiceGroup(configuration: .init(
    services: [
        .init(service: postgres),
        .init(service: worker),
        .init(service: scheduler),
    ],
    gracefulShutdownSignals: [.sigterm, .sigint]
))
try await group.run()
```

For schedules created at runtime (e.g. from an HTTP API), call
`client.schedule(name:pattern:workflowType:input:)` directly — it is always a
live database write.

See **[Scheduling](Sources/Strand/Strand.docc/Scheduling.md)** for patterns,
catch-up behaviour, time zones, and runtime management.

## Examples

See [`Examples/`](Examples/) for complete runnable examples:

| Example | What it shows |
|---|---|
| `Greeting` | Minimal activity + workflow |
| `MultipleActivities` | Sequential and parallel activities |
| `Schedule` | Cron and interval scheduling |
| `ChildWorkflows` | Fan-out orchestration |

## Requirements

- Swift 6.3+
- PostgreSQL 15+

## Dependencies

| Package | Version |
|---|---|
| [PostgresNIO](https://github.com/vapor/postgres-nio) | 1.32.2 |
| [Hummingbird](https://github.com/hummingbird-project/hummingbird) | 2.22.0 |
| [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) | 2.11.0 |
| [swift-log](https://github.com/apple/swift-log) | 1.12.0 |
| [swift-metrics](https://github.com/apple/swift-metrics) | 2.10.1 |
| [swift-distributed-tracing](https://github.com/apple/swift-distributed-tracing) | 1.4.1 |
| [swift-collections](https://github.com/apple/swift-collections) | 1.0.0+ |
| [swift-nio](https://github.com/apple/swift-nio) | 2.77+ |

## License

Apache 2.0
