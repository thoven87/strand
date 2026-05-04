# Scheduling recurring tasks

``StrandScheduler`` fires workflow or activity tasks on a repeating pattern.

## Start the scheduler

Add ``StrandScheduler`` alongside your worker in the `ServiceGroup`:

```swift
let scheduler = StrandScheduler(client: client)

let group = ServiceGroup(configuration: .init(
    services: [
        .init(service: postgres),
        .init(service: worker),
        .init(service: scheduler),
    ],
    gracefulShutdownSignals: [.sigterm, .sigint]
))
```

## Register schedules

Schedules are registered at startup (or any time). Registering the same name
twice upserts the pattern — existing in-flight tasks are unaffected.

```swift
// Every hour on the hour
try await client.schedule(
    name: "hourly-sync",
    pattern: .interval(.hours(1)),
    workflowType: DataSyncWorkflow.self,
    input: SyncInput()
)

// Daily at 09:00 UTC
try await client.schedule(
    name: "daily-report",
    pattern: .daily(offset: "PT9H"),
    workflowType: DailyReportWorkflow.self,
    input: ReportInput()
)

// Every weekday at 08:30 UTC via cron
try await client.schedule(
    name: "market-open",
    pattern: .cron("30 8 * * 1-5"),
    workflowType: MarketOpenWorkflow.self,
    input: StrandVoid()
)

// One-time future execution
try await client.schedule(
    name: "launch-day",
    pattern: .once(at: launchDate),
    workflowType: LaunchWorkflow.self,
    input: LaunchInput()
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

## Scheduling activities directly

For fire-and-forget work that doesn't need durable orchestration history:

```swift
try await client.schedule(
    name: "cleanup-old-files",
    pattern: .daily(offset: "PT2H"),
    activityType: CleanupActivity.self,
    input: CleanupInput(olderThanDays: 30)
)
```

## Catch-up behaviour

``ScheduleAccuracy`` controls what happens when the scheduler starts after being
offline:

```swift
// Default: fire only the most-recent missed slot (avoids flooding the queue)
options: ScheduleOptions(accuracy: .latest)

// Fire all missed slots in order (for financial reconciliation etc.)
options: ScheduleOptions(accuracy: .all)

// Fire only the last 3 missed slots
options: ScheduleOptions(accuracy: .last(3))
```

## Time zones

```swift
try await client.schedule(
    name: "new-york-open",
    pattern: .cron("30 9 * * 1-5",
                   timezone: TimeZone(identifier: "America/New_York")!),
    workflowType: MarketOpenWorkflow.self,
    input: StrandVoid()
)
```

## Manage schedules at runtime

```swift
// List all schedules in the default queue
let schedules = try await client.listSchedules()

// Pause / resume / delete by ID
try await client.pauseSchedule(id: scheduleID)
try await client.resumeSchedule(id: scheduleID)
try await client.deleteSchedule(id: scheduleID)
```

## Reading schedule metadata inside a workflow

When a workflow is triggered by a schedule, ``SchedulingMetadata`` is available
in the context:

```swift
mutating func run(context: WorkflowContext<Self>, input: ReportInput) async throws -> ReportResult {
    if let meta = context.schedulingMetadata {
        // meta.scheduleName  — e.g. "daily-report"
        // meta.scheduledAt   — wall-clock time the slot was due
        // meta.executionTime — time the task was actually dispatched
    }
    // ...
}
```
