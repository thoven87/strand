# Scheduling recurring tasks

``StrandScheduler`` fires workflow or activity tasks on a repeating pattern and
runs as a `Service` in your `ServiceGroup`.

## Two modes: static declarations vs. runtime calls

Strand distinguishes between two kinds of schedule registration:

| Mode | When to use | API |
|---|---|---|
| **Static declaration** | Schedules known at compile time (boot-time setup) | `StrandScheduler(schedules:)` |
| **Runtime call** | Schedules created dynamically (HTTP API, user action) | `client.schedule(...)` |

## Static declarations (boot-time)

Pass schedule definitions directly to ``StrandScheduler`` at construction time.
The scheduler upserts them to the database as the very first step of `run()` —
Postgres is guaranteed to be live at that point because the `ServiceGroup` starts
``PostgresClient`` before any other service.

```swift
let scheduler = StrandScheduler(
    client: client,
    schedules: [
        // Workflow schedule — every hour on the hour
        .workflow(
            "hourly-sync",
            pattern: .interval(.hours(1)),
            workflowType: DataSyncWorkflow.self,
            input: SyncInput()
        ),

        // Daily at 09:00 UTC
        .workflow(
            "daily-report",
            pattern: .daily(offset: "PT9H"),
            workflowType: DailyReportWorkflow.self,
            input: ReportInput()
        ),

        // Weekdays at 08:30 US Eastern via cron
        .workflow(
            "market-open",
            pattern: .cron("30 8 * * 1-5",
                           timezone: TimeZone(identifier: "America/New_York")!),
            workflowType: MarketOpenWorkflow.self,
            input: StrandVoid()
        ),

        // Activity fired directly — no wrapping workflow
        .activity(
            "cleanup-old-files",
            pattern: .daily(offset: "PT2H"),
            activityType: CleanupActivity.self,
            input: CleanupInput(olderThanDays: 30)
        ),
    ]
)

let group = ServiceGroup(configuration: .init(
    services: [
        .init(service: postgres),
        .init(service: worker),
        .init(service: scheduler),   // ← schedules are upserted here
    ],
    gracefulShutdownSignals: [.sigterm, .sigint]
))
try await group.run()
```

Registering the same name twice upserts the pattern — existing in-flight tasks
are unaffected.

## Runtime calls (dynamic)

For schedules created in response to an external event (an HTTP request, a user
action, a Strand workflow itself), call ``StrandClient/schedule(name:pattern:workflowType:input:queue:startsAt:endsAt:options:)``
directly from wherever the event is handled.  Postgres is always live at that
point, so the call is a straightforward database write:

```swift
// Inside a Hummingbird route handler, a workflow activity, etc.
try await client.schedule(
    name: "send-invoice-\(orderID)",
    pattern: .once(at: invoiceDate),
    workflowType: InvoiceWorkflow.self,
    input: InvoiceInput(orderID: orderID)
)
```

## Schedule patterns

| Pattern | Example | Description |
|---|---|---|
| `.cron(expression)` | `.cron("0 9 * * 1-5")` | Standard 5-field cron |
| `.interval(duration)` | `.interval(.hours(1))` | Fixed interval from last fire |
| `.daily(offset:)` | `.daily(offset: "PT9H")` | Daily at a time-of-day (ISO 8601 duration offset from midnight) |
| `.weekly(offset:)` | `.weekly(offset: "P1DT9H")` | Weekly on a day + time |
| `.monthly(offset:)` | `.monthly(offset: "P14DT9H")` | Monthly on a day-of-month + time |
| `.once(at:)` | `.once(at: someDate)` | Fire exactly once at the given `Date` |

## Catch-up behaviour

``ScheduleAccuracy`` controls what happens when the scheduler restarts after an
outage:

```swift
// Default: fire only the most-recent missed slot (avoids flooding the queue)
options: ScheduleOptions(accuracy: .latest)

// Fire all missed slots in order (e.g. financial reconciliation)
options: ScheduleOptions(accuracy: .all)

// Fire only the last 3 missed slots
options: ScheduleOptions(accuracy: .last(3))
```

A past `startsAt` date triggers catch-up recovery automatically:

```swift
.workflow(
    "iss-telemetry",
    pattern: .interval(.seconds(90 * 60)),
    workflowType: TelemetryWorkflow.self,
    input: TelemetryInput(),
    startsAt: Date(timeIntervalSince1970: 0),   // active since epoch
    options: ScheduleOptions(accuracy: .last(3)) // recover last 3 slots
)
```

## Time zones

Pass a `timezone:` argument to `.cron` or any pattern that accepts one:

```swift
.workflow(
    "new-york-open",
    pattern: .cron("30 9 * * 1-5",
                   timezone: TimeZone(identifier: "America/New_York")!),
    workflowType: MarketOpenWorkflow.self,
    input: StrandVoid()
)
```

## Manage schedules at runtime

```swift
// List all schedules
let schedules = try await client.listSchedules()

// Pause / resume / delete by UUID
try await client.pauseSchedule(id: scheduleID)
try await client.resumeSchedule(id: scheduleID)
try await client.deleteSchedule(id: scheduleID)
```

## Reading schedule metadata inside a workflow

When a workflow is triggered by a schedule, ``SchedulingMetadata`` is available
via the context:

```swift
mutating func run(context: WorkflowContext<Self>, input: ReportInput) async throws -> ReportResult {
    if let meta = context.schedulingMetadata {
        // meta.scheduleName  — "daily-report"
        // meta.scheduledAt   — wall-clock time the slot was due
        // meta.executionTime — time the task was actually dispatched
    }
    // ...
}
```

## Scheduler options

```swift
let scheduler = StrandScheduler(
    client: client,
    options: SchedulerOptions(
        sleepCap: .seconds(60)   // max sleep between polls; default 60 s
    ),
    schedules: [ ... ]
)
```

The scheduler sleeps precisely until the next known fire time, but wakes at
least every `sleepCap` seconds to detect newly-added schedules.
