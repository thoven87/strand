# Custom timetables

Schedule workflows on calendars that can't be expressed as a cron or interval.

## Overview

``StrandScheduler`` supports two kinds of schedules:

| Kind | When to use |
|---|---|
| **Pattern** (cron / interval / daily / weekly / …) | The cadence is fixed and expressible as a rule |
| **Timetable** | The cadence depends on a calendar outside the built-in patterns |

Timetables are the right tool when the schedule is driven by data — bank
holidays, quarter-end dates, business calendars, booking-slot availability —
rather than a static rule.

## The protocol

```swift
public protocol StrandTimeTable: Sendable {
    func nextRunTime(after lastScheduledAt: Date?, earliest: Date) -> Date?
    var description: String { get }
}
```

`nextRunTime` is called by the scheduler at two points:

1. **At startup** — to seed `next_run_at` when a new schedule is first
   registered (`lastScheduledAt` will be `nil`).
2. **After each fire** — to advance `next_run_at` past the slot that just ran.

**The function must return immediately.** The scheduler calls it on its hot poll
path. Do not perform I/O here — pre-load all data at `init` time or keep it
warm in a background-refreshed cache (see patterns below).

Return `nil` to permanently stop the schedule. Once `nil` is returned the
schedule row is deactivated and will not fire again unless manually updated.

### Choosing between `lastScheduledAt` and `earliest`

| Parameter | What it is | When to use it |
|---|---|---|
| `earliest` | Physical lower bound — `max(now, startsAt)` | **Always** — your returned date must be ≥ this value |
| `lastScheduledAt` | Logical slot time of the previous fire | Only when the **spacing** between runs depends on the previous slot (rolling windows, cooldowns) |

For calendar-driven timetables ("next working day", "next quarter-end") `earliest`
is all you need — it already encodes the "don't fire before this" constraint.
Use `lastScheduledAt` only when the gap itself is what you're computing, as in
the rolling-window pattern below. Implementations that don't need it should
mark it `_` to make the intent explicit.

## Data loading patterns

### Pattern 1 — Pre-load at init

Best for data that is fixed at process start time (hardcoded dates, a static
fiscal calendar, a holiday list passed in from configuration). `nextRunTime`
is a pure in-memory computation with no I/O.

```swift
struct FiscalCalendarTimetable: StrandTimeTable {
    /// Quarter-end dates, sorted ascending. Pass them in from configuration.
    private let quarterEnds: [Date]

    var description: String { "Quarter-end dates (fiscal calendar)" }

    init(quarterEnds: [Date]) {
        self.quarterEnds = quarterEnds.sorted()
    }

    func nextRunTime(after _: Date?, earliest: Date) -> Date? {
        // lastScheduledAt unused — earliest already encodes the lower bound.
        // Returns nil when the series is exhausted — schedule deactivates.
        quarterEnds.first { $0 >= earliest }
    }
}
```

### Pattern 2 — Service with background refresh

Best for data that must be loaded from a database or external API at startup,
or refreshed periodically while the process runs. Make the timetable a
`final class` that conforms to both `StrandTimeTable` **and** `Service`:

- `run()` loads data and (optionally) refreshes it on a timer.
- `nextRunTime` reads from a `Mutex`-protected cache — no I/O, always fast.
- The `ServiceGroup` manages lifecycle: cancellation of `run()` propagates
  cleanly on shutdown without needing manual `start()`/`stop()` calls.

#### Example — UK working-day settlement

```swift
import Synchronization

struct UKWorkingDayTimetable: StrandTimeTable, Service {
    private let holidayStore: Mutex<Set<DateComponents>> = Mutex([])
    private let postgres: PostgresClient
    private let londonTZ = TimeZone(identifier: "Europe/London")!

    var description: String { "UK working days, 09:00 London time" }

    init(postgres: PostgresClient) {
        self.postgres = postgres
    }

    // MARK: - Service

    func run() async throws {
        while !Task.isCancelled && !Task.isShuttingDownGracefully {
            try await Task.sleep(for: .hours(24))
            // Load holidays once at startup. postgres is already running because
            // ServiceGroup starts all services concurrently and PostgresClient
            // connects lazily — this query will succeed once the pool is ready.
            let loaded = try await loadHolidays(from: postgres)
            holidayStore.withLock { $0 = loaded }
        }
    }

    // MARK: - StrandTimeTable

    func nextRunTime(after _: Date?, earliest: Date) -> Date? {
        // lastScheduledAt unused — earliest already encodes the lower bound.
        holidayStore.withLock { holidays in
            // holidays may be empty if the scheduler seeds before run() finishes
            // its first load. An empty set means every non-weekend day is treated
            // as a working day — a reasonable degraded mode for the first seed.
            var greg = Calendar(identifier: .gregorian)
            greg.timeZone = londonTZ
            var candidate = greg.startOfDay(for: earliest)
            while !isWorkingDay(candidate, holidays: holidays, calendar: greg) {
                guard let next = greg.date(byAdding: .day, value: 1, to: candidate)
                else { return nil }
                candidate = next
            }
            // Fire at 09:00 London time.
            var comps = greg.dateComponents(in: londonTZ, from: candidate)
            comps.hour = 9; comps.minute = 0; comps.second = 0
            return greg.date(from: comps)
        }
    }

    // MARK: - Helpers

    private func isWorkingDay(
        _ date: Date,
        holidays: Set<DateComponents>,
        calendar: Calendar
    ) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        guard weekday != 1 && weekday != 7 else { return false }   // Sun / Sat
        let comps = calendar.dateComponents([.month, .day], from: date)
        return !holidays.contains(comps)
    }

    private func loadHolidays(from postgres: PostgresClient) async throws -> Set<DateComponents> {
        // Query your holidays table and return a Set<DateComponents>.
        // ...
        return []
    }
}
```

#### Example — Next available booking slot

```swift
import Synchronization

struct BookingSlotTimetable: StrandTimeTable, Service {
    // nil  = not yet loaded (initial state)
    // .some(nil)  = loaded, no slots available
    // .some(date) = next available slot
    private let store: Mutex<Date??> = Mutex(nil)
    private let postgres: PostgresClient

    var description: String { "Next available booking slot" }

    init(postgres: PostgresClient) {
        self.postgres = postgres
    }

    // MARK: - Service

    func run() async throws {
        // Populate the cache immediately, then refresh every 5 minutes.
        await refresh()
        while !Task.isCancelled && !Task.isShuttingDownGracefully {
            try await Task.sleep(for: .minutes(5))
            await refresh()
        }
    }

    // MARK: - StrandTimeTable

    func nextRunTime(after _: Date?, earliest: Date) -> Date? {
        // lastScheduledAt unused — next slot is always the freshest available.
        store.withLock { stored in
            guard let loaded = stored else {
                // run() hasn't completed its first refresh yet. Return a
                // near-future probe so the schedule is seeded rather than
                // deactivated — by the time this date arrives the cache will
                // be warm and fire() will advance to the real next slot.
                return earliest.addingTimeInterval(60)
            }
            guard let slot = loaded, slot >= earliest else { return nil }
            return slot
        }
    }

    // MARK: - Helpers

    private func refresh() async {
        do {
            var found: Date? = nil
            let stream = try await postgres.query(
                "SELECT slot_at FROM open_slots WHERE slot_at >= NOW() ORDER BY slot_at LIMIT 1",
                logger: .init(label: "timetable.booking")
            )
            for try await row in stream {
                found = try row.makeIterator().next()!.decode(Date.self, context: .default)
                break
            }
            store.withLock { $0 = .some(found) }
        } catch {
            // Keep the previous cached value on transient errors.
        }
    }
}
```

## Irregular cadences — hardcoded dates

For a finite series of irregular dates, store them sorted and find the first
date ≥ `earliest`. Returning `nil` when the list is exhausted permanently
deactivates the schedule:

```swift
struct EventSeriesTimetable: StrandTimeTable {
    private let dates: [Date]   // sorted ascending, passed at init

    var description: String { "Event series (\(dates.count) dates)" }

    init(dates: [Date]) { self.dates = dates.sorted() }

    func nextRunTime(after _: Date?, earliest: Date) -> Date? {
        // lastScheduledAt unused — earliest already encodes the lower bound.
        dates.first { $0 >= earliest }
    }
}
```

## Rolling windows — fire N days after the previous run

When the gap between runs is measured from when the last run completed rather
than a fixed slot, use `lastScheduledAt`:

```swift
struct CooldownTimetable: StrandTimeTable {
    let cooldown: TimeInterval

    var description: String { "Every \(Int(cooldown / 86400)) days after last run" }

    func nextRunTime(after lastScheduledAt: Date?, earliest: Date) -> Date? {
        let base = lastScheduledAt ?? earliest
        let candidate = base.addingTimeInterval(cooldown)
        return max(candidate, earliest)
    }
}
```

## Returning nil to stop a schedule

Return `nil` from `nextRunTime` to permanently deactivate the schedule. The
scheduler sets `is_active = false` and will not call `nextRunTime` again unless
the schedule row is manually reactivated.

Typical reasons:

- The event series is exhausted (last date in the list was consumed).
- No slots are available and the schedule should wait for an operator to
  re-activate it.
- A hard `endsAt` deadline computed inside the timetable has passed.

```swift
func nextRunTime(after lastScheduledAt: Date?, earliest: Date) -> Date? {
    guard earliest < fiscalYearEnd else { return nil }   // series complete
    return nextWorkingDay(from: earliest)
}
```

## Registering timetable schedules

Timetable schedules use the `timetable:` overloads on ``StrandSchedule``.
When the timetable also conforms to `Service`, add it to the `ServiceGroup`
alongside `postgres` and `strand` so its `run()` is managed by the same
lifecycle:

```swift
let holidayTimetable = UKWorkingDayTimetable(postgres: postgres)
let bookingTimetable = BookingSlotTimetable(postgres: postgres)

strand.addSchedule(
    .workflow(
        "daily-settlement",
        timetable: holidayTimetable,
        workflowType: SettlementWorkflow.self,
        input: SettlementInput(),
        queue: "settlement",
        options: ScheduleOptions(accuracy: .latest)
    )
)
strand.addSchedule(
    .workflow(
        "next-booking",
        timetable: bookingTimetable,
        workflowType: BookingWorkflow.self,
        input: BookingInput(),
        queue: "bookings"
    )
)

let group = ServiceGroup(
    services: [postgres, holidayTimetable, bookingTimetable, strand],
    gracefulShutdownSignals: [.sigterm, .sigint],
    logger: logger
)
try await group.run()
```

The timetable instance lives entirely in memory — only its `description` string
is stored in the database and shown in the Loom schedule list. Re-register the
same timetable implementation on every process restart, just as you re-register
workflow and activity types.

## The `description` property

`description` is a short human-readable label shown in the Loom schedule list.
A default implementation returns the Swift type name; override it to produce
something meaningful to operators:

```swift
struct UKWorkingDayTimetable: StrandTimeTable, Service {
    var description: String { "UK working days, 09:00 London" }
    // ...
}
```

## Topics

### Reference
- ``StrandTimeTable``
- ``StrandSchedule``
- ``ScheduleOptions``
