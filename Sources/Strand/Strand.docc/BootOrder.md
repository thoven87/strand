# Boot order and schedule registration

Why `client.schedule(...)` can race against Postgres startup, and what to do about it.

## The problem

`PostgresClient`, `StrandWorker`, and `StrandScheduler` all conform to
`Service`. When you add them to a `ServiceGroup` they start **concurrently** —
ServiceLifecycle does not impose a sequencing order by default.

`client.schedule(...)` issues SQL against Postgres. If that call runs before
`PostgresClient` has established its first connection, it fails with a
connection error and the schedule is never registered.

### What the examples do today

The current examples use an unstructured `Task` with an arbitrary sleep:

```swift
// ⚠️  This is a workaround, not a solution.
Task {
    try await Task.sleep(for: .milliseconds(500))   // hope Postgres is ready
    try await client.schedule(
        name: "hourly-sync",
        pattern: .hourly(),
        workflowType: SyncWorkflow.self,
        input: .done
    )
}
```

This is fragile in several ways:

- **Cold containers** — a container starting from scratch may take several
  seconds to establish a TCP connection to Postgres. 500 ms is not enough.
- **Slow networks** — cloud databases behind a proxy can have higher
  connection latency.
- **Silent failure** — if the sleep is too short, `client.schedule` throws and
  the error is swallowed inside the unstructured `Task`. The schedule is simply
  not registered. No log, no crash, no alert.
- **No lifecycle integration** — the unstructured `Task` is not tracked by
  `ServiceGroup` and does not participate in graceful shutdown.

### Why this does not affect workers

`StrandWorker.run()` calls `Queries.registerNamespace` and `Queries.createQueue`
at the top of its `run()` method, before the poll loop starts. If Postgres is
not ready, these queries wait for a connection automatically — PostgresNIO
retries internally. The worker therefore tolerates delayed Postgres availability
transparently.

`StrandScheduler.run()` behaves the same way: `pollDueSchedules` retries until
it gets a connection. The scheduler itself is fine; only the **registration
step** (`client.schedule(...)`) is called outside the lifecycle.

## Workaround for now

Until the long-term fix is implemented, call `client.schedule(...)` **before**
handing `postgres` to `ServiceGroup`. At that point you control when to start
the Postgres connection and can wait for it explicitly:

```swift
// 1. Start Postgres connection in the background.
let postgres = PostgresClient(configuration: ...)
let pgTask = Task { await postgres.run() }

// 2. Wait for the first successful query (retries internally — no sleep needed).
try await postgres.query("SELECT 1", logger: logger)

// 3. Register schedules — Postgres is definitely ready now.
let client = StrandClient(postgres: postgres, queue: "default")
try await client.verifySchema()
try await client.schedule(
    name: "hourly-sync",
    pattern: .hourly(),
    workflowType: SyncWorkflow.self,
    input: .done
)

// 4. Cancel the background task; ServiceGroup will restart postgres properly.
pgTask.cancel()

// 5. Hand everything to ServiceGroup.
let group = ServiceGroup(configuration: .init(
    services: [
        .init(service: postgres),
        .init(service: worker),
        .init(service: scheduler),
    ],
    gracefulShutdownSignals: [.sigterm, .sigint],
    logger: logger
))
try await group.run()
```

`postgres.query("SELECT 1")` blocks until the connection pool has at least one
live connection. This is the same mechanism the worker uses internally — no
arbitrary sleep required.

## The long-term fix (future work)

The root cause is that schedule registration lives outside the `Service`
lifecycle. The correct fix is to give `StrandScheduler` a registration closure
that it calls at the top of `run()`, **after** its first successful Postgres
interaction and **before** the poll loop starts:

```swift
// Proposed future API (not yet implemented)
let scheduler = StrandScheduler(client: client, options: .init()) {
    // Called inside scheduler.run(), after Postgres is confirmed ready.
    try await client.schedule(
        name: "hourly-sync",
        pattern: .hourly(),
        workflowType: SyncWorkflow.self,
        input: .done
    )
    try await client.schedule(
        name: "daily-report",
        pattern: .daily(offset: "PT9H"),
        workflowType: DailyReportWorkflow.self,
        input: ReportInput()
    )
}
```

With this design, the whole application can be expressed as a plain
`ServiceGroup` with no setup code outside it:

```swift
let group = ServiceGroup(configuration: .init(
    services: [
        .init(service: postgres),
        .init(service: worker),
        .init(service: scheduler),   // schedules registered here, inside run()
    ],
    gracefulShutdownSignals: [.sigterm, .sigint],
    logger: logger
))
try await group.run()
```

The implementation requires:
1. A registration closure on `StrandScheduler` (stored as a property)
2. Calling it inside `run()` after the first successful query to Postgres
3. Updating all examples to remove the `Task { Task.sleep; client.schedule }` pattern
