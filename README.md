<p align="center">
  <img src="logo.svg" width="128" alt="Strand">
</p>

<h1 align="center">Strand</h1>

<p align="center"><strong>Postgres-native durable workflow engine for Swift 6.3.</strong></p>

No separate coordination service. No Redis. No Cassandra. Just Swift workers and Postgres.

```swift
@Workflow
struct OrderWorkflow {
    struct Input:  Codable, Sendable { let amount: Int; let orderID: String }
    struct Output: Codable, Sendable { let trackingNumber: String }

    mutating func run(
        context: WorkflowContext<Self>,
        input: Input
    ) async throws -> Output {
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
import Logging
import PostgresNIO
import ServiceLifecycle
import Strand

var logger = Logger(label: "my-app")

let postgres = PostgresClient(
    configuration: .init(
        host: "localhost", port: 5499,
        username: "strand", password: "strand",
        database: "strand_dev", tls: .disable
    ),
    backgroundLogger: logger
)

var strand = StrandService(
    postgres: postgres,
    options: .init(
        queues: [
            .init(
                name: "default",
                workflows: [OrderWorkflow.self],
                activities: [ChargeCardActivity(), ShipOrderActivity()]
            )
        ]
    )
)

// Trigger a workflow from anywhere — returns a handle you can await:
let client = strand.client(queue: "default")
Task {
    let handle = try await client.startWorkflow(
        OrderWorkflow.self,
        input: OrderWorkflow.OrderInput(amount: 99_00, orderID: "ord-1")
    )
    let result = try await handle.result()
    print(result)
}

let group = ServiceGroup(
    services: [postgres, strand],
    gracefulShutdownSignals: [.sigterm, .sigint],
    logger: logger
)
try await group.run()
```

## Scheduling

Declare recurring schedules on `StrandService` — they are upserted to the database
when the service starts:

```swift
var strand = StrandService(
    postgres: postgres,
    options: .init(
        queues: [
            .init(
                name: "default",
                workflows: [DailyReportWorkflow.self, MarketOpenWorkflow.self]
            )
        ],
        scheduler: .init()
    )
)

strand.addSchedule(
    .workflow(
        "daily-report",
        pattern: .daily(offset: "PT9H"),          // 09:00 UTC every day
        workflowType: DailyReportWorkflow.self,
        input: ReportInput()
    )
)
strand.addSchedule(
    .workflow(
        "market-open",
        pattern: .cron("30 8 * * 1-5",
                       timezone: TimeZone(identifier: "America/New_York")!),
        workflowType: MarketOpenWorkflow.self,
        input: StrandVoid()
    )
)

// Custom timetable — fire on any calendar logic you can express in Swift
struct UKBankHolidayFreeSchedule: StrandTimeTable {
    let holidays: Set<DateComponents>   // loaded at init time
    var description: String { "UK working days, 09:00 London" }

    func nextRunTime(after _: Date?, earliest: Date) -> Date? {
        var greg = Calendar(identifier: .gregorian)
        greg.timeZone = TimeZone(identifier: "Europe/London")!
        var candidate = greg.startOfDay(for: earliest)
        while !isWorkingDay(candidate, calendar: greg) {
            candidate = greg.date(byAdding: .day, value: 1, to: candidate)!
        }
        var comps = greg.dateComponents(in: greg.timeZone, from: candidate)
        comps.hour = 9; comps.minute = 0; comps.second = 0
        return greg.date(from: comps)
    }
    // ...
}

strand.addSchedule(
    .workflow(
        "daily-settlement",
        timetable: UKBankHolidayFreeSchedule(holidays: holidays),
        workflowType: SettlementWorkflow.self,
        input: StrandVoid()
    )
)

let group = ServiceGroup(
    services: [postgres, strand],
    gracefulShutdownSignals: [.sigterm, .sigint],
    logger: logger
)
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
| [`HackerNewsSummary`](Examples/Sources/HackerNewsSummary) | Multi-child fan-out with Ollama summarisation; `@ActivityContainer` |
| [`GroundwaterPipeline`](Examples/Sources/GroundwaterPipeline) | 6.2 M-row data pipeline, parallel download, Ollama trend analysis |
| [`CIPipeline`](Examples/Sources/CIPipeline) | DAG-style CI workflow with human-in-the-loop approval signal |
| [`SmartBuilding`](Examples/Sources/SmartBuilding) | IoT sensor aggregation, multi-tenant, scheduled reports |
| [`DevServer`](Examples/Sources/DevServer) | Local dev server with seeded workflows and the Loom dashboard |

## Requirements

- Swift 6.3+
- PostgreSQL 17+
- Runs on Linux and macOS — any platform supported by [SwiftNIO](https://github.com/apple/swift-nio) and [PostgresNIO](https://github.com/vapor/postgres-nio)

## License

Apache 2.0
