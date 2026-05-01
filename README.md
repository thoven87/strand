# Stand

**Postgres-native durable workflow engine for Swift 6.3.** No Cassandra, no Redis, no separate coordination service — just your Swift workers and a Postgres database.

If the process crashes mid-workflow, the next worker that picks it up resumes from the last checkpoint. No work is duplicated, no state is lost.

```swift
struct OrderWorkflow: Workflow {
    typealias Input  = OrderInput
    typealias Output = ShipResult

    mutating func run(context: WorkflowContext<Self>, input: OrderInput) async throws -> ShipResult {
        let charge = try await context.runActivity(ChargeCardActivity.self,
            input: .init(amount: input.amount))
        return try await context.runActivity(ShipOrderActivity.self,
            input: .init(paymentID: charge.paymentID))
    }
}
```

## How it works

Workflows are value-type structs that orchestrate activities. When `run()` calls `context.runActivity(...)`:

1. The activity is enqueued as an independent task in Postgres
2. The workflow suspends, freeing its worker slot
3. An activity worker claims the task, executes the I/O, and stores the result
4. The workflow re-activates and continues from where it left off

The handler function replays from the top on each activation. Already-completed activities return immediately from the checkpoint cache — they never re-execute.

---

## Quick Start

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
```

### 2. Apply the schema

```bash
psql "postgresql://strand:strand@localhost:5499/strand_dev" -f strand.sql
```

### 3. Add Strand to your package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/thoven87/strand.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Strand", package: "strand"),
    ]),
]
```

### 4. Define an activity and a workflow

```swift
import Strand

// Activity — all I/O lives here
struct ChargeCardActivity: ActivityDefinition {
    typealias Input  = ChargeInput
    typealias Output = ChargeResult

    let stripe: StripeClient

    func run(input: ChargeInput, context: ActivityContext) async throws -> ChargeResult {
        ChargeResult(paymentID: try await stripe.charge(input.amount))
    }
}

// Workflow — pure orchestration, no I/O
struct OrderWorkflow: Workflow {
    typealias Input  = OrderInput
    typealias Output = ShipResult

    mutating func run(context: WorkflowContext<Self>, input: OrderInput) async throws -> ShipResult {
        let charge = try await context.runActivity(ChargeCardActivity.self,
            input: .init(amount: input.amount))
        return try await context.runActivity(ShipOrderActivity.self,
            input: .init(paymentID: charge.paymentID))
    }
}
```

### 5. Bootstrap a worker and start a workflow

```swift
import Strand
import PostgresNIO
import Logging
import ServiceLifecycle

@main struct MyApp {
    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput(label:))
        let logger = Logger(label: "myapp")

        let postgres = PostgresClient(
            configuration: .init(
                host: "localhost", port: 5499,
                username: "strand", password: "strand", database: "strand_dev",
                tls: .disable
            ),
            backgroundLogger: logger
        )

        let client = StrandClient(postgres: postgres, queue: "orders", logger: logger)

        let worker = StrandWorker(
            postgres: postgres,
            options: WorkerOptions(queue: "orders", workflowConcurrency: 10, activityConcurrency: 20),
            workflows: [OrderWorkflow.self],
            activityContainers: [PaymentActivities(stripe: StripeClient())],
            activities: [ShipOrderActivity()],
            logger: logger
        )

        Task {
            try? await Task.sleep(for: .milliseconds(500))
            let handle = try await client.startWorkflow(
                OrderWorkflow.self,
                options: .init(id: "order-\(orderID)"),
                input: OrderInput(amount: 99.99)
            )
            let result: ShipResult = try await handle.result(timeout: .seconds(60))
            print("Shipped:", result.trackingNumber)
        }

        let group = ServiceGroup(
            configuration: .init(
                services: [postgres, worker],
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: logger
            )
        )
        try await group.run()
    }
}
```

---

## Core Concepts

### Workflow

A `Workflow` is a `Codable`, `Sendable` struct that contains **orchestration logic only** — no network calls, no DB queries, no `Date()`, no `UUID()`. All I/O belongs in `ActivityDefinition` implementations.

```swift
struct FulfillOrderWorkflow: Workflow {
    typealias Input  = OrderInput
    typealias Output = FulfillmentResult

    // Stored properties are Codable and persisted between activations.
    // Mutate them in handleSignal; read them in run().
    var priority: ShippingPriority = .standard

    mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
        // Called before run() on each activation that has pending signals.
        // Use name to dispatch; decode payload for typed data.
        switch name {
        case "upgrade": priority = .overnight
        case "downgrade": priority = .standard
        default: break
        }
    }

    mutating func run(
        context: WorkflowContext<Self>, input: OrderInput
    ) async throws -> FulfillmentResult {
        let charge   = try await context.runActivity(ChargeCardActivity.self,
            input: .init(amount: input.amount))
        let shipment = try await context.runActivity(ShipOrderActivity.self,
            input: .init(paymentID: charge.paymentID, priority: priority))
        return FulfillmentResult(trackingNumber: shipment.trackingNumber)
    }
}
```

| Rule | Why |
|---|---|
| No I/O in `run()` | Non-determinism breaks replay |
| No `Date()` or `UUID()` directly in `run()` | Use `context.now`, `context.uuid()`, `context.random(in:)` |
| Handler replays from the top each activation | Completed activities return instantly from cache |

### Activity

An `ActivityDefinition` is where real work happens. It holds dependencies as stored properties and is registered on the worker at startup.

```swift
struct ChargeCardActivity: ActivityDefinition {
    typealias Input  = ChargeInput
    typealias Output = ChargeResult

    let stripe: StripeClient  // injected at worker boot

    func run(input: ChargeInput, context: ActivityContext) async throws -> ChargeResult {
        ChargeResult(paymentID: try await stripe.charge(input.amount))
    }
}
```

Use `StrandEmpty` when an activity returns no meaningful value:

```swift
struct SendEmailActivity: ActivityDefinition {
    typealias Input  = EmailInput
    typealias Output = StrandEmpty

    let smtp: SMTPClient

    func run(input: EmailInput, context: ActivityContext) async throws -> StrandEmpty {
        try await smtp.send(to: input.address, body: input.body)
        return .done
    }
}
```

Group related activities that share a dependency with `ActivityContainerProtocol`:

```swift
struct PaymentActivities: ActivityContainerProtocol {
    let stripe: StripeClient

    var activities: [any ActivityBox] {
        [ChargeCardActivity(stripe: stripe),
         RefundCardActivity(stripe: stripe)]
    }
}
```

### Worker

Pass workflow metatypes and activity instances to `StrandWorker`:

```swift
let worker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(
        queue: "orders",
        workflowConcurrency: 10,    // max concurrent workflow activations
        activityConcurrency: 20,    // max concurrent activity executions
        claimTimeout: .seconds(120) // lease duration per claimed task
    ),
    workflows: [OrderWorkflow.self, RefundWorkflow.self],
    activityContainers: [PaymentActivities(stripe: stripe)],
    activities: [ShipOrderActivity(), SendEmailActivity()],
    logger: logger
)
```

The worker's `queue` must match the queue used by `StrandClient`. Multiple workers on the same queue compete safely via `FOR UPDATE SKIP LOCKED` — each claims a non-overlapping set of tasks.

### Client

```swift
let client = StrandClient(
    postgres: postgres,
    queue: "orders",
    logger: logger
)

// Start a workflow — returns a typed handle immediately
let handle = try await client.startWorkflow(
    OrderWorkflow.self,
    options: .init(
        id: "order-\(orderID)",    // stable deduplication key; idempotent restarts
        priority: .high,
        maxAttempts: 5,
        retryPolicy: .exponential(baseSeconds: 1, factor: 2, maxSeconds: 30)
    ),
    input: OrderInput(amount: 99.99)
)

// Poll for the final result
let result: ShipResult = try await handle.result(timeout: .seconds(60))
```

---

## WorkflowContext Primitives

Every primitive is checkpointed. On replay, completed checkpoints are skipped instantly.

### Run an activity

```swift
let result = try await context.runActivity(ChargeCardActivity.self,
    input: ChargeInput(amount: input.amount))
```

With per-call options:

```swift
let result = try await context.runActivity(
    ChargeCardActivity.self,
    input: ChargeInput(amount: input.amount),
    options: ActivityOptions(
        maxAttempts: 5,
        retryPolicy: .exponential(baseSeconds: 1, factor: 2, maxSeconds: 60),
        queue: "payments",    // route to a dedicated worker pool
        priority: .high,
        timeout: .seconds(30)
    )
)
```

### Deterministic values

Capture non-deterministic values exactly once and cache them across replays:

```swift
let id     = try context.uuid()            // UUID.v7() — stable across replays
let n      = try context.random(in: 1...100) // Int — same value every replay
let weight = try context.random(in: 0.0...1.0) // Double
let ts     = context.now                   // Date — activation timestamp
```

Each call is keyed by its position in the call sequence, not by a user-supplied name.
The Nth call to `uuid()` always returns the same UUID as long as the call order is stable.

> **Never put I/O inside these helpers.** HTTP calls, database queries, and `Task.sleep`
> belong in `ActivityDefinition.run(input:context:)`, not in the workflow handler.

### Sleep

```swift
try await context.sleep(for: .hours(24))                              // relative duration
try await context.sleep(until: context.now.addingTimeInterval(3600)) // absolute time
```

The workflow enters `SLEEPING` state. Its worker slot is freed for the duration.

### Child workflows

```swift
let report = try await context.runChildWorkflow(
    GenerateReportWorkflow.self,
    options: ChildWorkflowOptions(queue: "reports"),
    input: ReportRequest(datasetID: input.datasetID)
)
```

### Context properties

```swift
context.workflowID          // UUID — stable task identifier
context.attempt             // Int  — current activation number (1-based)
context.logger              // Logger scoped to this activation
context.now                 // Date — wall-clock time at activation start
context.schedulingMetadata  // SchedulingMetadata? — set when triggered by a schedule
```

---

## Parallel Activities

`async let` composes correctly with `runActivity` — each suspension and re-activation is independent:

```swift
mutating func run(context: WorkflowContext<Self>, input: OrderInput) async throws -> OrderResult {
    // Both activities are dispatched immediately and run in parallel
    async let charge  = context.runActivity(ChargeCardActivity.self,
        input: .init(amount: input.amount))
    async let reserve = context.runActivity(InventoryActivity.self,
        input: .init(sku: input.sku))

    let (c, r) = try await (charge, reserve)

    return try await context.runActivity(ShipOrderActivity.self,
        input: .init(paymentID: c.paymentID, reservationID: r.reservationID))
}
```

Fan-out over a dynamic list with `withThrowingTaskGroup`:

```swift
let analyses = try await withThrowingTaskGroup(of: Analysis.self) { group in
    for item in input.items {
        group.addTask {
            try await context.runActivity(AnalyseItemActivity.self,
                input: .init(item: item))
        }
    }
    return try await group.reduce(into: []) { $0.append($1) }
}
```

---

## Signals and Condition

Signals let external code mutate the workflow's `Codable` state between activations. The workflow re-runs from the top after signals are applied.

### Handle signals in the workflow

```swift
struct OrderWorkflow: Workflow {
    typealias Input  = OrderInput
    typealias Output = ShipResult

    var isPaused = false

    mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
        switch name {
        case "pause":  isPaused = true
        case "resume": isPaused = false
        default: break
        }
    }

    mutating func run(context: WorkflowContext<Self>, input: OrderInput) async throws -> ShipResult {
        // Block until isPaused is false — re-evaluated after every signal
        try await context.condition { !$0.isPaused }

        let charge = try await context.runActivity(ChargeCardActivity.self,
            input: .init(amount: input.amount))
        return try await context.runActivity(ShipOrderActivity.self,
            input: .init(paymentID: charge.paymentID))
    }
}
```

### Send signals from the client

```swift
let handle = try await client.startWorkflow(OrderWorkflow.self,
    options: .init(id: "order-42"), input: input)

try await handle.signal(name: "pause")
// ... later
try await handle.signal(name: "resume")

// With a typed payload
try await handle.signal(name: "set-priority", payload: ShippingPriority.overnight)
```

### condition

`context.condition { predicate }` suspends the workflow until the predicate returns `true`. The predicate receives the current workflow struct (after any pending signals have been applied).

```swift
// Wait until both payment and inventory are confirmed via signals
try await context.condition { $0.paymentReceived && $0.inventoryReserved }
```

---

## Events

Named events let external systems wake a specific `waitForEvent` call inside a running workflow. Unlike signals (which mutate state), events deliver a payload directly to a waiting call site.

### String-keyed events

```swift
// In the workflow — suspends until the event arrives (or the timeout expires)
let approval = try await context.waitForEvent(
    "order.approved:\(input.orderID)",
    as: ApprovalInfo.self,
    timeout: .seconds(60 * 60 * 24)  // throws StrandError after 24 h
)

// From outside — first emit wins, safe to call from any service
try await client.emitEvent(
    "order.approved:\(orderID)",
    payload: ApprovalInfo(approvedBy: "alice", approved: true)
)
```

### Typed events

Define a shared type to make the name and payload a compile-time contract:

```swift
struct OrderApprovedEvent: WorkflowEvent {
    typealias Payload = ApprovalInfo
    static let name   = "order.approved"
}

// In the workflow:
let info = try await context.waitForEvent(OrderApprovedEvent.self)

// From the client:
try await client.emit(OrderApprovedEvent.self,
    payload: ApprovalInfo(approvedBy: "alice"),
    queue: "orders")
```

A typo in the event name or a payload mismatch becomes a compile error.

### Non-blocking check

Pass a 1 ms timeout to poll without blocking — useful for optional signals:

```swift
do {
    let priority = try await context.waitForEvent(
        "order.priority:\(input.orderID)", as: PriorityUpdate.self,
        timeout: .milliseconds(1))
    // Priority was already emitted before we reached this point
} catch is StrandError {
    // No priority update — proceed with default
}
```

---

## Scheduling

Schedule recurring workflows with `StrandScheduler`.

### Register schedules

```swift
// Cron expression
try await client.schedule(
    name: "daily-report",
    pattern: .cron("0 9 * * *"),          // 9 AM UTC every day
    workflowType: GenerateReportWorkflow.self,
    input: ReportInput(type: .daily)
)

// Fixed interval
try await client.schedule(
    name: "health-check",
    pattern: .interval(.seconds(60)),
    workflowType: SystemHealthWorkflow.self,
    input: HealthInput()
)

// Named shorthand (offset from midnight as ISO 8601 duration)
try await client.schedule(
    name: "morning-summary",
    pattern: .daily(offset: "PT9H"),      // 9 AM UTC
    workflowType: SummaryWorkflow.self,
    input: SummaryInput()
)
```

### Run the scheduler

Add `StrandScheduler` to your service group alongside the worker:

```swift
let scheduler = StrandScheduler(client: client,
    options: SchedulerOptions(pollInterval: .seconds(5)))

let group = ServiceGroup(
    configuration: .init(
        services: [
            postgres,
            worker,
            scheduler,
        ],
        gracefulShutdownSignals: [.sigterm, .sigint],
        logger: logger
    )
)
try await group.run()
```

### Read scheduling metadata in the workflow

```swift
mutating func run(context: WorkflowContext<Self>, input: ReportInput) async throws -> ReportResult {
    if let meta = context.schedulingMetadata {
        context.logger.info("Fired by schedule \(meta.scheduleId ?? "?")",
            metadata: ["execution_time": "\(meta.executionTime)"])
    }
    ...
}
```

### Manage schedules

```swift
let id = try await client.schedule(name: "daily-report", ...)
try await client.pauseSchedule(id: id)
try await client.resumeSchedule(id: id)
try await client.deleteSchedule(id: id)
let schedules: [ScheduleSummary] = try await client.listSchedules()
```

---

## Query Handlers

Inspect the current workflow state without interrupting it:

```swift
struct OrderWorkflow: Workflow {
    var isPaused = false
    var processedItems: [String] = []
    ...
}

// From the client — reads the last persisted state synchronously
let isPaused = try await handle.query { $0.isPaused }
let count    = try await handle.query { $0.processedItems.count }
```

`query` decodes the persisted workflow struct and calls the closure without creating a new activation. It is read-only and non-blocking.

---

## Activity Heartbeat

Long-running activities must periodically extend their lease to prevent the watchdog from marking them as failed:

```swift
struct ProcessLargeFileActivity: ActivityDefinition {
    typealias Input  = FileInput
    typealias Output = ProcessResult

    func run(input: FileInput, context: ActivityContext) async throws -> ProcessResult {
        var processed = 0
        for chunk in input.chunks {
            try await context.heartbeat()  // extend the claim lease
            processed += process(chunk)
        }
        return ProcessResult(rowsProcessed: processed)
    }
}
```

The heartbeat extends the lease by `WorkerOptions.claimTimeout`. Call it at least once per `claimTimeout` interval or your task will be marked failed by the lease watchdog.

---

## Dashboard Server

`StarndServer` exposes a JSON REST API for the Strand dashboard UI and optionally serves the built React app.

### Standalone

```swift
import StrandServer

let server = StrandServer(strand: client, postgres: postgres)
try await server.run()  // blocks; handles SIGTERM / SIGINT
```

### Embedded alongside workers

Use `buildRouter` to mount the Strand API on your own Hummingbird `Application`:

```swift
let router = StrandServer.buildRouter(strand: client, postgres: postgres)
var app    = Application(
    router: router,
    configuration: .init(address: .hostname("0.0.0.0", port: 8080)),
    logger: logger
)
app.addServices(postgres, worker)
app.beforeServerStarts { try await client.verifySchema() }
try await app.runService()
```

### API endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/queues` | List queues with task counts |
| `GET` | `/api/queues/:queue/tasks` | Paginated task list (cursor-based) |
| `GET` | `/api/queues/:queue/tasks/:id` | Task detail with params and result |
| `POST` | `/api/queues/:queue/tasks/:id/cancel` | Cancel a task |
| `POST` | `/api/queues/:queue/tasks/:id/retry` | Retry a failed task |
| `GET` | `/api/tasks` | Cross-queue task list (filter by state, name) |
| `GET` | `/api/queues/:queue/tasks/:id/runs` | Run history for a task |
| `GET` | `/api/workers` | Active worker registrations |
| `GET` | `/api/schedules` | Active schedules |
| `POST` | `/api/queues/:queue/cleanup` | Delete old terminal tasks |

### Dashboard UI (development)

```bash
# Start the API server + workers
cd Examples && swift run DevServer

# Start the UI dev server (proxies /api to :8080)
cd strand-ui && npm run dev

# Build UI for production (outputs to Sources/StrandServer/Resources/ui/)
cd strand-ui && npm run build
```

---

## Schema Setup

Apply `strand.sql` once to a fresh database:

```bash
psql "postgresql://starnd:starnd@localhost:5499/starnd_dev" -f starnd.sql
```

Create queues before enqueuing work:

```swift
try await client.createQueue("orders")
try await client.createQueue("payments")
```

Or in SQL:

```sql
INSERT INTO strand.queues (name) VALUES ('orders') ON CONFLICT DO NOTHING;
```

Verify the schema at startup:

```swift
try await client.verifySchema()
```

### Retention

Completed tasks accumulate unless cleaned up. Schedule a periodic cleanup:

```swift
let deleted = try await client.cleanup(
    queue: "orders",
    olderThan: .seconds(30 * 24 * 3600),  // tasks older than 30 days
    limit: 1000
)
```

Or via the dashboard API: `POST /api/queues/orders/cleanup?olderThan=2592000`.

---

## Requirements

| Requirement | Value |
|---|---|
| Swift | 6.3+ |
| macOS (development) | 26+ |
| Linux (production) | Ubuntu 22.04 LTS or equivalent |
| PostgreSQL | 15+ |
| Package platform | `.macOS(.v26)` |
| Swift language mode | `.v6` |

Swift settings enabled: `NonIsolatedNonSendingByDefault` ([SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)), `InternalImportsByDefault` ([SE-0409](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md)).

---

## Dependencies

| Package | Version | Used by |
|---|---|---|
| [`postgres-nio`](https://github.com/vapor/postgres-nio) | 1.32.2 | `Strand` |
| [`swift-nio`](https://github.com/apple/swift-nio) | 2.99+ | `Strand` |
| [`swift-log`](https://github.com/apple/swift-log) | 1.12.0 | `Strand`, `StrandServer` |
| [`swift-service-lifecycle`](https://github.com/swift-server/swift-service-lifecycle) | 2.11.0 | `Strand`, `StrandServer` |
| [`hummingbird`](https://github.com/hummingbird-project/hummingbird) | 2.22.0 | `StrandServer` only |
