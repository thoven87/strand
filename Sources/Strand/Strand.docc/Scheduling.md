# Scheduling recurring tasks

``StrandScheduler`` fires workflow or activity tasks on a repeating pattern and
runs as a `Service` in your `ServiceGroup`.

## Two modes: static declarations vs. runtime calls

| Mode | When to use | API |
|---|---|---|
| **Static declaration** | Schedules known at compile time | `StrandService.addSchedule` / `StrandScheduler(schedules:)` |
| **Runtime call** | Schedules created from an HTTP handler, a workflow, or a user action | ``StrandClient/schedule(name:pattern:workflowType:input:queue:startsAt:endsAt:options:)`` |

## Static declarations (boot-time)

The example below is drawn from the **HackerNewsSummary** example in the public
repository. It schedules a weekday briefing at 09:00 US Eastern time using
``StrandService``:

```swift
// HackerNewsSummaryExample.swift
var strand = StrandService(
    postgres: postgres,
    options: .init(
        queues: [
            // Orchestrator — top-level workflow + story fetch
            .init(
                name: "hn-orchestrator",
                namespace: "hn-summary",
                workflows: [HackerNewsSummaryWorkflow.self],
                activities: [FetchTopStoriesActivity()],
                workflowConcurrency: 4,
                activityConcurrency: 8
            ),
            // Summariser — child workflows; cap Ollama concurrency at 3
            .init(
                name: "hn-summarizer",
                namespace: "hn-summary",
                workflows: [SummarizeStoryWorkflow.self],
                activities: [FetchStoryActivity(), OllamaSummarizeActivity()],
                workflowConcurrency: 3,
                activityConcurrency: 3
            ),
        ],
        scheduler: .init(
            options: .init(sleepCap: .seconds(30)),
            queue: "hn-orchestrator",
            namespace: "hn-summary"
        ),
        logger: logger
    )
)

// Nine AM Eastern, weekdays only, starting May 2026.
// ScheduleOptions(accuracy: .last(3)) recovers the three most-recent
// missed slots if the process was down over a long weekend.
var estCal = Calendar(identifier: .gregorian)
estCal.timeZone = TimeZone(identifier: "America/New_York")!
let may2026 = estCal.date(
    from: DateComponents(year: 2026, month: 5, day: 1, hour: 0, minute: 0)
)!

strand.addSchedule(
    .workflow(
        "hn-daily-briefing",
        pattern: .cron("0 9 * * 1-5",
                       timezone: TimeZone(identifier: "America/New_York")!),
        workflowType: HackerNewsSummaryWorkflow.self,
        input: HNInput(storyCount: 5, jobID: "daily"),
        startsAt: may2026,
        options: ScheduleOptions(accuracy: .last(3))
    )
)

let group = ServiceGroup(
    services: [postgres, strand],
    gracefulShutdownSignals: [.sigterm, .sigint],
    logger: logger
)
try await group.run()
```

Registering the same `name` twice upserts the pattern — existing in-flight
tasks are unaffected.

## Runtime calls (dynamic)

For schedules created in response to an external event (an HTTP request, a user
action, or from within a workflow activity), call
``StrandClient/schedule(name:pattern:workflowType:input:queue:startsAt:endsAt:options:)``
wherever the event is handled:

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

### Typed constructors (recommended)

The preferred API uses named parameters and the ``Weekday`` and ``Month`` enums
— no ISO 8601 string arithmetic, and the compiler catches day/month out-of-range
values that a raw string cannot:

```swift
// Daily — fire every day at the given hour and minute
.daily(hour: 9)                          // 09:00 UTC every day
.daily(hour: 14, minute: 30)             // 14:30 UTC every day
.daily(hour: 9, timezone: nyTZ)          // 09:00 Eastern, DST-aware

// Weekdays (Mon–Fri)
.weekdays(hour: 9)                        // 09:00 UTC every weekday
.weekdays(hours: 9, 16, timezone: nyTZ)   // 09:00 and 16:00 Eastern every weekday

// Specific weekday selection
.onDays(.monday, .wednesday, .friday, hour: 9)        // MWF at 09:00
.onDays(.tuesday, .thursday, hour: 8, minute: 30)     // TuTh at 08:30
.onDays(.monday, .wednesday, .friday, hours: 8, 14)   // MWF at 08:00 and 14:00

// Multiple hours per day
.onHours(8, 12, 17)                       // 08:00, 12:00, 17:00 UTC every day
.onHours(9, 14, minute: 30)               // 09:30 and 14:30 UTC every day

// Sub-hourly
.onMinutes(0, 15, 30, 45)                 // every 15 minutes
.onMinutes(0, 30)                         // every 30 minutes

// Weekly — fire once per week on a specific weekday
.weekly(on: .monday, hour: 9)            // Monday 09:00 UTC
.weekly(on: .friday, hour: 17, minute: 30, timezone: nyTZ)

// Specific dates of the month
.onDates(1, 15, hour: 9)                // 1st and 15th at 09:00
.onDates(1, 8, 15, 22, hour: 0)         // four Mondays-ish at midnight

// Monthly — fire on a specific day-of-month
.monthly(day: 1,  hour: 0)              // 1st of each month at midnight
.monthly(day: 15, hour: 10, minute: 30)

// Yearly — fire on a specific month and day
.yearly(month: .january,  day: 1,  hour: 0)          // New Year's Day midnight
.yearly(month: .march,    day: 15, hour: 10, minute: 30)
.yearly(month: .december, day: 25, hour: 8, timezone: nyTZ)

// Cron — standard 5-field expression for anything else
.cron("0 9 * * 1-5")                    // weekdays 09:00 UTC (same as .weekdays)
.cron("0 9 * * 1-5", timezone: nyTZ)

// Interval — fixed interval from epoch-aligned boundaries
.interval(.hours(1))                    // every hour on the hour
.interval(.minutes(15))

// Once — fire exactly once
.once(at: someDate)
```

### Pattern summary

| Pattern | `partitionTime` |
|---|---|
| `.daily(hour:minute:)` | Midnight of that day |
| `.weekdays(hour:)` / `.weekdays(hours:)` | Midnight of that day |
| `.onDays([Weekday], hour:)` / `.onDays([Weekday], hours:)` | Midnight of that day |
| `.onHours([Int], minute:)` | The epoch-aligned hour boundary |
| `.onMinutes([Int])` | The current hour (minute = 0) |
| `.weekly(on:hour:minute:)` | Saturday 00:00 of that week |
| `.onDates([Int], hour:minute:)` | 1st of that month at 00:00 |
| `.monthly(day:hour:minute:)` | 1st of that month at 00:00 |
| `.yearly(month:day:hour:minute:)` | January 1st 00:00 of that year |
| `.interval(duration)` | Epoch-aligned interval boundary just before fire |
| `.cron(expr)` | The cron tick itself |
| `.once(at:)` | The fire date |

See [Partition time](#Partition-time) for why `partitionTime` matters.

### Foundation `Calendar` and holiday awareness

Foundation's `Calendar` already powers Strand's date arithmetic (`calendar.nextDate(after:matching:matchingPolicy:)` drives every typed constructor internally). It handles DST, leap years, and different calendar systems — but it does **not** know about national holidays, NYSE closures, UK bank holidays, or any other region-specific non-working days. That data does not exist in any OS framework.

For patterns that should skip certain dates, two approaches work today:

**1. Use `.cron` to encode the rule directly** when the pattern is expressible in cron:
```swift
// First business day of the month (approximately — doesn't handle holidays)
.cron("0 9 1-7 * 1")   // Monday at 09:00 in the first 7 days of the month
```

**2. Exclude dates in the workflow handler** when the rule is too complex for cron:
```swift
struct DailyTradeWorkflow: Workflow {
    mutating func run(context: WorkflowContext<Self>, input: TradeInput) async throws -> TradeResult {
        guard let meta = context.schedulingMetadata else { return .skipped }
        let day = meta.partitionTime ?? meta.executionTime

        // Skip if today is a known holiday — return early rather than failing.
        // The next scheduled slot fires tomorrow as normal.
        if isNYSEHoliday(day) { return .skipped }

        return try await processTradeDay(day)
    }
}
```

This keeps the schedule running on its normal cadence; the workflow simply
detects the holiday and exits cleanly. The `partitionTime` anchor makes the
check stable across retries.

**Future: `BusinessCalendar` protocol**

A first-class holiday protocol is planned. The design will follow the same
registration pattern as workflows — the calendar name is serializable (stored
in `strand.schedules`), the implementation is application code:

```swift
// Application registers a named calendar at startup (not yet implemented)
scheduler.registerCalendar("NYSE", NYSECalendar())

// Schedule references it by name
strand.addSchedule(
    .workflow(
        "daily-trade",
        pattern: .weekdays(hour: 9, minute: 30, timezone: nyTZ),
        options: ScheduleOptions(
            businessCalendar: "NYSE",  // skip NYSE holidays automatically
            onHoliday: .skipToNext    // or .skip, .fireAnyway
        )
    )
)
```

Until then, the early-return pattern in the workflow handler is the recommended
approach for production systems with known holiday calendars.

### Raw offset form (advanced)

Every pattern also has a lower-level form that takes an ISO 8601 duration string
for the `offset:` parameter. Strand uses this internally and it gives fine-grained
control over sub-minute timing or staggered firing:

```swift
// Stagger a daily midnight job by 15 minutes to avoid thundering herd
// partitionTime stays 00:00; executionTime becomes 00:15
.cron("0 0 * * *", offset: "PT15M")

// Fire at 00:45, 01:45, 02:45 … (epoch-aligned hourly, shifted 45 min)
.interval(.hours(1), offset: "PT45M")

// Raw forms of the typed constructors above:
// .daily(hour: 9)          ≡ .daily(offset: "PT9H")
// .weekly(on: .monday, hour: 9) ≡ .weekly(offset: "P2DT9H")
// .monthly(day: 15, hour: 9)    ≡ .monthly(offset: "P14DT9H")
// .yearly(month: .march, day: 15, hour: 9) ≡ .yearly(offset: "P2MT14DT9H")
```

Weekly offset origin is **Saturday** (`P0D`): Sun=`P1D`, Mon=`P2D`, … Fri=`P6D`.
Monthly `P0D` maps to day 1. Yearly `P0M P0D` maps to January 1st.

## Catch-up behaviour

``ScheduleAccuracy`` controls what happens when the scheduler restarts after an
outage and there are missed slots:

| Accuracy | Behaviour |
|---|---|
| `.latest` | Fire only the single most-recent missed slot. **Default.** Avoids flooding the queue after a long outage. |
| `.all` | Fire every missed slot in chronological order. Use for financial reconciliation or any process where every execution must happen. |
| `.last(n)` | Fire only the last `n` missed slots in chronological order. Useful when you want bounded catch-up after an outage. |

```swift
// Fire the 3 most-recent missed briefings after a long weekend outage
options: ScheduleOptions(accuracy: .last(3))

// Re-run every missed slot since deployment (financial pipelines)
options: ScheduleOptions(accuracy: .all)
```

A past `startsAt` date triggers catch-up automatically:

```swift
strand.addSchedule(
    .workflow(
        "iss-telemetry",
        pattern: .interval(.minutes(90)),
        workflowType: TelemetryWorkflow.self,
        input: TelemetryInput(),
        startsAt: Date(timeIntervalSince1970: 0),    // active since epoch
        options: ScheduleOptions(accuracy: .last(3)) // recover last 3 slots
    )
)
```

## Time zones

Pass `timezone:` to `.cron` or any pattern that accepts one:

```swift
.workflow(
    "market-open",
    // Typed constructor is clearer than cron for a simple weekday+time pattern
    pattern: .weekly(on: .monday,    hour: 9, timezone: nyTZ),  // one line per day
    workflowType: MarketOpenWorkflow.self,
    input: StrandVoid()
)

// Or use cron when the schedule has complex day-of-week logic:
.workflow(
    "market-open",
    pattern: .cron("30 9 * * 1-5",
                   timezone: TimeZone(identifier: "America/New_York")!),
    workflowType: MarketOpenWorkflow.self,
    input: StrandVoid()
)
```

Civil-day patterns (`.daily`, `.weekly`, `.monthly`) are DST-aware when a
timezone is provided — a "09:00 daily" schedule fires at 09:00 local time
regardless of whether the clock has moved forward or back.

## Partition time

Every task fired by a schedule carries three timestamps inside
``SchedulingMetadata``:

| Field | What it is | Example for `.daily(offset: "PT9H")` at 09:00 ET |
|---|---|---|
| `partitionTime` | Start of the **period** the task covers (offset stripped) | May 13 00:00 ET (midnight) |
| `executionTime` | Wall-clock time the **scheduler actually fired** the task | May 13 09:00:00.123 ET |
| `scheduleOffset` | The raw offset string from the pattern | `"PT9H"` |

The relationship is: `partitionTime + scheduleOffset ≈ executionTime`.

### Why `partitionTime` is the right anchor

Always use `partitionTime` — not `executionTime` — as the canonical date for:

- **Fetching data**: "which day's HN stories should I fetch?" → `partitionTime`
  is May 13 midnight, consistently, whether this is a live run or a backfill
  re-running that slot weeks later.
- **Idempotency keys**: a retry of the same slot has the same `partitionTime`
  but a different `executionTime`.
- **Backfills**: when the scheduler fires a historical slot, `executionTime` is
  now (the actual firing time) but `partitionTime` is the historical period
  being re-processed.

`executionTime` is useful for **SLA monitoring** ("did this job run on time?") and
logging, but not for data logic.

```swift
mutating func run(
    context: WorkflowContext<Self>,
    input: HNInput
) async throws -> HNDailySummary {
    guard let meta = context.schedulingMetadata else {
        // Directly enqueued (e.g. `startWorkflow`) — use activationTime.
        return try await runBriefing(for: context.activationTime)
    }

    // ✓ Correct: partitionTime is the day boundary regardless of when we run.
    // Works for live runs, retries, and backfill re-runs alike.
    let briefingDay = meta.partitionTime ?? meta.executionTime

    // ✗ Wrong: executionTime drifts with poll latency and is "now" for backfills.
    // let briefingDay = meta.executionTime

    // ✓ Detect backfill runs
    let isBackfill = meta.backfillId != nil

    return try await runBriefing(for: briefingDay, isBackfill: isBackfill)
}
```

### Partition time by pattern

| Pattern | `partitionTime` |
|---|---|
| `.daily(offset: "PT9H")` — fires 09:00 | Midnight of that day |
| `.weekly(offset: "P6DT9H")` — fires Friday 09:00 | Saturday 00:00 of that week |
| `.monthly(offset: "P14DT9H")` — fires 15th 09:00 | 1st of that month at 00:00 |
| `.yearly(offset: "P2MT14DT9H")` — fires Mar 15 | January 1st 00:00 of that year |
| `.interval(.minutes(90))` — fires 01:45 | 01:30 (the 90-min boundary) |
| `.cron("0 0 * * *", offset: "PT15M")` — fires 00:15 | 00:00 (the cron tick) |
| `.cron("0 9 * * 1-5")` (no offset) | 09:00 (the cron tick itself) |

## Manage schedules at runtime

```swift
// List all schedules for this namespace
let schedules = try await client.listSchedules()

// Pause / resume / delete by UUID
try await client.pauseSchedule(id: scheduleID)
try await client.resumeSchedule(id: scheduleID)
try await client.deleteSchedule(id: scheduleID)
```

## Backfill

A **backfill** retroactively executes a scheduled workflow or activity for every
slot in a historical date range. Use it when:

- The scheduler was not running during a period and `.all` catch-up is too
  aggressive (e.g. thousands of hourly slots — you want controlled, concurrent
  execution, not a queue flood).
- You deployed a new scheduled workflow and need to populate historical data.
- A bug corrupted a range of executions and you need to re-run them.

For the HN briefing example: if the service was down for two weeks you missed
ten weekday briefings. Rather than recovering them through the normal scheduler
(which would serialise them one by one), a backfill enqueues them with
configurable concurrency:

```swift
let client = strand.client(queue: "hn-orchestrator", namespace: "hn-summary")

let cal = Calendar(identifier: .gregorian)
let rangeStart = cal.date(from: DateComponents(year: 2026, month: 5, day: 5))!
let rangeEnd   = cal.date(from: DateComponents(year: 2026, month: 5, day: 19))!

let handle = try await client.createBackfill(
    HackerNewsSummaryWorkflow.self,
    input: HNInput(storyCount: 5, jobID: "backfill"),
    schedule: .cron("0 9 * * 1-5",
                    timezone: TimeZone(identifier: "America/New_York")!),
    range: rangeStart ..< rangeEnd,
    options: BackfillOptions(
        concurrency: 3,           // at most 3 slots executing simultaneously
        allowOverwrite: false,    // skip slots that already completed successfully
        description: "Re-run missed briefings May 5–18"
    )
)
print("Backfill started:", handle.id)
```

### BackfillOptions

| Property | Default | Description |
|---|---|---|
| `concurrency` | `1` | Maximum number of slots executing at the same time. Increase carefully — each slot enqueues its own child activities. |
| `allowOverwrite` | `false` | When `false`, slots that already have a completed task with the matching idempotency key are skipped. Set `true` to force re-execution. |
| `description` | `nil` | Human-readable note shown in the Loom dashboard explaining why this backfill was created. |

### Monitoring progress

`createBackfill` returns a ``BackfillHandle``. Call `status()` to poll progress:

```swift
let status = try await handle.status()
print("\(status.completedSlots) / \(status.totalSlots) slots done")
print("Progress:", status.progressFraction)  // 0.0 – 1.0
```

``BackfillStatus`` fields:

| Field | Description |
|---|---|
| `state` | `.running`, `.halted`, `.completed`, or `.failed` |
| `totalSlots` | Total number of slots in the requested range |
| `completedSlots` | Slots dispatched so far |
| `progressFraction` | `completedSlots / totalSlots` (0.0 – 1.0) |
| `nextSlotTime` | Wall-clock time of the next slot to be dispatched |
| `completedAt` | Set when `state == .completed` |

### Pausing and resuming a backfill

```swift
// Pause — stops the scheduler from dispatching more slots.
// Already-running slots complete normally.
try await handle.halt()

// Resume from where it stopped.
try await handle.resume()
```

### Tying a backfill to an existing schedule

Pass the schedule's UUID to `scheduleId:` so the Loom dashboard links the
backfill to the schedule:

```swift
let schedules = try await client.listSchedules()
let hnSchedule = schedules.first { $0.name == "hn-daily-briefing" }!

let handle = try await client.createBackfill(
    HackerNewsSummaryWorkflow.self,
    input: HNInput(storyCount: 5, jobID: "backfill"),
    schedule: .cron("0 9 * * 1-5",
                    timezone: TimeZone(identifier: "America/New_York")!),
    range: rangeStart ..< rangeEnd,
    scheduleId: hnSchedule.id,          // ← links to the schedule in Loom
    options: BackfillOptions(concurrency: 3)
)
```

### Running a single historical slot

To fire exactly one past slot — for example, to replay a specific date's
briefing — use ``StrandClient/runScheduleSlot(scheduleID:partitionTime:allowOverwrite:namespaceID:)``:

```swift
// Replay the May 12th briefing
let may12 = cal.date(from: DateComponents(
    year: 2026, month: 5, day: 12, hour: 9, minute: 0
))!

let (taskID, _) = try await client.runScheduleSlot(
    scheduleID: hnSchedule.id,
    partitionTime: may12,
    allowOverwrite: true   // re-run even if it previously completed
)
```

## Scheduler options

```swift
let scheduler = StrandScheduler(
    client: client,
    options: SchedulerOptions(
        sleepCap:        .seconds(30), // max sleep between polls; default 60 s
        maxCatchupSlots: 500,           // slots per fire() call during catch-up; default 1 000
        pollLimit:       50             // schedules claimed per poll cycle; default 100
    ),
    schedules: [ ... ]
)
```

| Option | Default | Description |
|---|---|---|
| `sleepCap` | `60 s` | Maximum sleep between polls. The scheduler sleeps precisely until the next fire time, but wakes at least this often to detect newly-added schedules and backfills. Lower values mean faster detection of runtime `schedule(...)` calls; higher values reduce DB load. |
| `maxCatchupSlots` | `1 000` | Maximum missed slots enqueued in a single `fire()` invocation when `accuracy` is `.all` or `.last(n)`. After this limit the remaining slots are picked up on the next poll cycle, bounding per-call latency regardless of backlog size. |
| `pollLimit` | `100` | Maximum due schedules claimed per poll cycle. When more schedules fire simultaneously than this limit (e.g. after a long outage), the remainder are left for the next cycle, preventing burst overload. |

## Topics

### Reference
- ``StrandScheduler``

### Related
- <doc:Timetables>
- ``ScheduleOptions``
- ``ScheduleAccuracy``
- ``SchedulingMetadata``
- ``BackfillOptions``
- ``StrandClient/createBackfill(_:input:schedule:range:queue:scheduleId:options:)``
- ``StrandClient/runScheduleSlot(scheduleID:partitionTime:allowOverwrite:namespaceID:)``
