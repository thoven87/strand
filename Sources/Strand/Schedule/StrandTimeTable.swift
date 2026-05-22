#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// MARK: - StrandTimeTable

/// A custom schedule whose firing times cannot be expressed as a fixed cron
/// expression, interval, or built-in pattern.
///
/// Implement this protocol when you need scheduling logic that depends on a
/// calendar outside the built-in patterns — for example:
///
/// - **Bank-holiday-free working days** (skip national holidays and weekends)
/// - **Quarter-end dates** (last business day of each financial quarter)
/// - **Irregular cadences** (fire on specific hardcoded dates)
/// - **Rolling windows** (always fire N days after the previous run completes)
///
/// ## How it works
///
/// The ``StrandScheduler`` stores the timetable instance in memory and calls
/// `nextRunTime(after:earliest:)` at two points in the schedule lifecycle:
///
/// 1. **At startup** — to seed the initial `next_run_at` when a new schedule
///    is registered for the first time (`lastScheduledAt = nil`).
/// 2. **After each fire** — to advance `next_run_at` past the slot that just
///    executed.
///
/// The timetable instance is **never serialised to the database**. The DB only
/// stores the human-readable `description` property (shown in the Loom
/// schedule list). You must re-register the same timetable implementation
/// every time the scheduler restarts — the same requirement that already
/// applies to workflow and activity type registrations.
///
/// ## Example — UK bank-holiday-free working days
///
/// ```swift
/// struct UKWorkingDayTimetable: StrandTimeTable {
///     /// Fixed set of UK bank holidays for the current year.
///     private let holidays: Set<DateComponents>
///
///     var description: String { "UK working days, 09:00 London time" }
///
///     func nextRunTime(after lastScheduledAt: Date?, earliest: Date) async throws -> Date? {
///         // Start from the beginning of the earliest permitted day.
///         var candidate = Calendar.current.startOfDay(for: earliest)
///         // Walk forward until we land on a working day.
///         while !isWorkingDay(candidate) {
///             guard let next = Calendar.current.date(byAdding: .day, value: 1, to: candidate) else { return nil }
///             candidate = next
///         }
///         // Fire at 09:00 London time on that day.
///         var comps = Calendar.current.dateComponents(in: londonTZ, from: candidate)
///         comps.hour = 9; comps.minute = 0; comps.second = 0
///         return Calendar.current.date(from: comps)
///     }
///
///     private func isWorkingDay(_ date: Date) -> Bool {
///         let weekday = Calendar.current.component(.weekday, from: date)
///         guard weekday != 1 && weekday != 7 else { return false }       // Sun/Sat
///         let comps = Calendar.current.dateComponents([.month, .day], from: date)
///         return !holidays.contains(comps)
///     }
/// }
///
/// // Register with the scheduler:
/// let scheduler = StrandScheduler(
///     client: client,
///     schedules: [
///         .workflow(
///             "daily-settlement",
///             timetable: UKWorkingDayTimetable(year: 2026),
///             workflowType: SettlementWorkflow.self,
///             input: SettlementInput()
///         )
///     ]
/// )
/// ```
///
/// ## Contract for implementors
///
/// - The returned `Date` **must be ≥ `earliest`**.  The scheduler treats a date
///   earlier than `earliest` as a programming error and logs a warning.
/// - Return `nil` to permanently stop the schedule (e.g. the event series is
///   finished).  Once `nil` is returned, the schedule row is deactivated and
///   will not fire again unless manually updated.
/// - The implementation **must be deterministic across retries**: if the
///   scheduler crashes after calling `nextRunTime` but before writing the result,
///   the same call is made again on restart.  Idempotent reads are safe;
///   side-effectful writes inside `nextRunTime` may double-execute.
/// - `nextRunTime` is **synchronous** by design. The scheduler calls it on the
///   hot poll path and needs an immediate answer. Do not perform blocking I/O
///   here — pre-load all data you need at `init` time or maintain a
///   background-refreshed cache that this method reads from.
///
/// ### Data loading patterns
///
/// | Pattern | When to use | Example |
/// |---|---|---|
/// | Pre-load at `init` | Data changes rarely (year-level) | UK bank holiday list for 2026 |
/// | Background-refresh cache | Data changes often; a background `Task` or `Service` keeps a local copy warm | Government holiday API, live booking slots |
public protocol StrandTimeTable: Sendable {

    /// Returns the next time this schedule should fire, or `nil` to
    /// permanently stop the schedule.
    ///
    /// - Parameters:
    ///   - lastScheduledAt: The **slot time** of the most recent scheduled
    ///     execution, or `nil` if this is the first time the schedule has
    ///     run.  This is the logical slot time (e.g. "Monday 09:00"), not
    ///     the wall-clock time the task actually started.
    ///   - earliest: The earliest permissible fire time.
    ///     Always `max(now, schedule.startsAt)` — present or future.
    ///     Your implementation must return a date ≥ `earliest`.
    /// - Returns: The next fire date, or `nil` to permanently stop the schedule.
    func nextRunTime(after lastScheduledAt: Date?, earliest: Date) -> Date?

    /// Short human-readable description stored in the database and shown in
    /// the Loom schedule list (e.g. `"UK working days, 09:00 London time"`).
    ///
    /// Default: the Swift type name of the conforming type.
    var description: String { get }
}

extension StrandTimeTable {
    public var description: String {
        String(describing: type(of: self))
    }
}
