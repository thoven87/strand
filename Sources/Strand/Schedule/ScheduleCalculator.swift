#if canImport(FoundationEssentials)
public import FoundationEssentials
import Foundation  // needed for (FormatStyle, Calendar)
// + (String(format:), CharacterSet) not in FoundationEssentials
// TODO: revisit this in the future
#else
public import Foundation
#endif

/// Centralized calculator for all schedule-related time calculations
/// This consolidates all scheduling logic into one authoritative place
public struct ScheduleCalculator {

    // MARK: - Core Schedule Calculation

    /// Calculate the next run time for a schedule after a given date
    public static func nextRunTime(
        for schedule: SchedulePattern,
        after date: Date,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) throws -> Date? {
        try schedule.nextRunTime(after: date, timezone: timezone)
    }

    /// Calculate the previous/current scheduled time for a given execution time
    /// This finds the scheduled time that corresponds to when a job should execute
    public static func scheduledTime(
        for schedule: SchedulePattern,
        at executionTime: Date
    ) throws
        -> Date?
    {
        switch schedule {
        case .cron(let expression, _, _):
            return try calculateCronScheduledTime(
                expression: expression,
                executionTime: executionTime
            )
        case .interval(let interval, _, _):
            // Use epoch-aligned boundaries so the result is deterministic
            // regardless of when the schedule was created or what time it is now.
            // e.g. a 90-minute interval snaps to 00:00, 01:30, 03:00 UTC…
            let secs = Double(interval.components.seconds)
            let epochBoundary = (executionTime.timeIntervalSince1970 / secs).rounded(.down) * secs
            return Date(timeIntervalSince1970: epochBoundary)
        case .once(let runDate, _, _):
            return runDate <= executionTime ? runDate : nil
        case .timetable:
            return nil
        case .daily(let offset, let tz):
            // offset is already a parsed ISO8601Duration — extract hour/minute directly.
            let totalMinutes = offset.hours * 60 + offset.minutes
            return calculateDailyScheduledTime(
                hour: (totalMinutes / 60) % 24,
                minute: totalMinutes % 60,
                executionTime: executionTime,
                timezone: tz
            )
        case .weekly(let offset, let tz):
            let totalMinutes = offset.days * 24 * 60 + offset.hours * 60 + offset.minutes
            let dayOfWeek = (totalMinutes / (24 * 60)) % 7
            let remainingMinutes = totalMinutes % (24 * 60)
            return calculateWeeklyScheduledTime(
                dayOfWeek: dayOfWeek,
                hour: remainingMinutes / 60,
                minute: remainingMinutes % 60,
                executionTime: executionTime,
                timezone: tz
            )
        case .monthly(let offset, let tz):
            return calculateMonthlyScheduledTime(
                day: offset.days + 1,  // 1-indexed
                hour: offset.hours,
                minute: offset.minutes,
                executionTime: executionTime,
                timezone: tz
            )
        case .yearly(let offset, let tz):
            return calculateYearlyScheduledTime(
                month: offset.months + 1,
                day: offset.days + 1,
                hour: offset.hours,
                minute: offset.minutes,
                executionTime: executionTime,
                timezone: tz
            )
        }
    }

    /// Calculate both current scheduled time and next run time for a job execution
    public static func calculateExecutionTimes(
        for schedule: SchedulePattern,
        executingAt executionTime: Date,
        createdAt: Date? = nil,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) throws -> (scheduledTime: Date, nextRunTime: Date)? {

        // Find the scheduled time that this execution represents
        guard let scheduledTime = try scheduledTime(for: schedule, at: executionTime) else {
            return nil
        }

        // Calculate the next run time after the current execution time
        guard
            let nextRunTime = try nextRunTime(
                for: schedule,
                after: executionTime,
                timezone: timezone
            )
        else {
            return nil
        }

        return (scheduledTime: scheduledTime, nextRunTime: nextRunTime)
    }

    // MARK: - Schedule Type Specific Calculations

    private static func calculateCronScheduledTime(
        expression: String,
        executionTime: Date
    ) throws
        -> Date?
    {
        let cronExpr = try CronExpression(expression)

        // For cron expressions, we need to find the scheduled time that corresponds to this execution
        // We look for the most recent scheduled time that would trigger at or before the execution time

        // Strategy: Look for the scheduled time within a reasonable window
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let searchWindow: TimeInterval = 3600  // 1 hour window for frequent schedules

        // Find the previous run time, but add a small buffer to include the current time
        // This handles the case where executionTime is exactly on a scheduled boundary
        let searchTime =
            calendar.date(byAdding: .second, value: 1, to: executionTime) ?? executionTime

        if let previousTime = try cronExpr.previousRunTime(before: searchTime) {
            // Check if this previous time is within our reasonable window
            let timeDiff = abs(executionTime.timeIntervalSince(previousTime))

            // For frequent schedules (every few minutes), allow up to 5 minutes tolerance
            // For less frequent schedules, allow more tolerance
            let tolerance: TimeInterval = min(300, searchWindow / 12)  // 5 minutes or 1/12 of search window

            if timeDiff <= tolerance {
                return previousTime
            }
        }

        // Fallback: if no recent scheduled time found, look further back
        return try cronExpr.previousRunTime(before: executionTime)
    }

    private static func calculateIntervalScheduledTime(
        interval: TimeInterval,
        executionTime: Date,
        createdAt: Date
    ) -> Date? {
        let elapsed = executionTime.timeIntervalSince(createdAt)
        let intervals = (elapsed / interval).rounded(.down)
        return createdAt.addingTimeInterval(intervals * interval)
    }

    private static func calculateDailyScheduledTime(
        hour: Int,
        minute: Int,
        executionTime: Date,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let executionComponents = calendar.dateComponents(
            [.year, .month, .day],
            from: executionTime
        )

        var scheduledComponents = executionComponents
        scheduledComponents.hour = hour
        scheduledComponents.minute = minute
        scheduledComponents.second = 0

        guard let scheduledTime = calendar.date(from: scheduledComponents) else {
            return nil
        }

        // If the scheduled time is after execution time, it should be yesterday
        if scheduledTime > executionTime {
            return calendar.date(byAdding: .day, value: -1, to: scheduledTime)
        }

        return scheduledTime
    }

    private static func calculateWeeklyScheduledTime(
        dayOfWeek: Int,
        hour: Int,
        minute: Int,
        executionTime: Date,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone

        // Find the most recent occurrence of this day/time
        var searchDate = executionTime
        for _ in 0..<7 {
            let components = calendar.dateComponents(
                [.weekday, .year, .month, .day],
                from: searchDate
            )

            // Same mapping as calculateWeeklyNextRunTime: dayOfWeek 0 → Saturday (7),
            // dayOfWeek 1 → Sunday (1), ..., dayOfWeek 6 → Friday (6).
            let targetWeekday = dayOfWeek == 0 ? 7 : dayOfWeek
            if components.weekday == targetWeekday {
                var scheduledComponents = components
                scheduledComponents.hour = hour
                scheduledComponents.minute = minute
                scheduledComponents.second = 0

                if let scheduledTime = calendar.date(from: scheduledComponents),
                    scheduledTime <= executionTime
                {
                    return scheduledTime
                }
            }

            searchDate = calendar.date(byAdding: .day, value: -1, to: searchDate) ?? searchDate
        }

        return nil
    }

    private static func calculateMonthlyScheduledTime(
        day: Int,
        hour: Int,
        minute: Int,
        executionTime: Date,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let executionComponents = calendar.dateComponents([.year, .month], from: executionTime)

        // Try current month first
        var scheduledComponents = executionComponents
        scheduledComponents.day = day
        scheduledComponents.hour = hour
        scheduledComponents.minute = minute
        scheduledComponents.second = 0

        if let scheduledTime = calendar.date(from: scheduledComponents),
            scheduledTime <= executionTime
        {
            return scheduledTime
        }

        // Try previous month
        if let previousMonth = calendar.date(byAdding: .month, value: -1, to: executionTime) {
            let previousComponents = calendar.dateComponents([.year, .month], from: previousMonth)
            scheduledComponents = previousComponents
            scheduledComponents.day = day
            scheduledComponents.hour = hour
            scheduledComponents.minute = minute
            scheduledComponents.second = 0

            return calendar.date(from: scheduledComponents)
        }

        return nil
    }

    private static func calculateYearlyScheduledTime(
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        executionTime: Date,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone

        // Try in the current year first, then the previous year.
        for yearOffset in [0, -1] {
            let ref = calendar.date(byAdding: .year, value: yearOffset, to: executionTime) ?? executionTime
            let year = calendar.component(.year, from: ref)
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = day
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            if let candidate = calendar.date(from: comps), candidate <= executionTime {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Job State Management

    /// Calculate the initial nextRunAt time for a new recurring job
    public static func initialNextRunTime(
        for schedule: SchedulePattern,
        createdAt: Date = Date(),
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) throws -> Date? {
        try nextRunTime(for: schedule, after: createdAt, timezone: timezone)
    }

    /// Counts the number of schedule slots in `range` (start **inclusive**, end exclusive).
    ///
    /// The start is made inclusive by searching from `lowerBound - 1 s` so a slot
    /// that falls exactly on the range boundary is counted, matching standard
    /// backfill semantics where the lower bound is adjusted by -1 before evaluation.
    ///
    /// Capped at `cap` (default 100 000) to bound O(n) iteration for large ranges.
    public static func countSlots(
        for schedule: SchedulePattern,
        in range: Range<Date>,
        cap: Int = 100_000
    ) -> Int {
        var count = 0
        var cursor = range.lowerBound.addingTimeInterval(-1)
        while count < cap {
            guard
                let next = try? nextRunTime(for: schedule, after: cursor, timezone: schedule.timezone),
                next < range.upperBound
            else { break }
            count += 1
            cursor = next
        }
        return count
    }

    // MARK: - Validation and Utilities

    /// Validate that a schedule configuration is valid
    public static func validateSchedule(_ schedule: SchedulePattern, now: Date = .now) throws {
        switch schedule {
        case .cron(let expression, _, _):
            guard !expression.isEmpty else {
                throw SchedulingError.invalidSchedule("Cron expression cannot be empty")
            }
            // Try to parse the cron expression to ensure it's valid
            _ = try CronExpression(expression)
        case .daily, .weekly, .monthly, .yearly:
            break  // offset is already a validated ISO8601Duration
        case .interval(let duration, _, _):
            guard duration.components.seconds > 0 else {
                throw SchedulingError.invalidSchedule("Interval must be greater than 0 seconds")
            }
        case .once(let date, _, _):
            guard date > now else {
                throw SchedulingError.invalidSchedule("One-time schedule must be in the future")
            }
        case .timetable:
            break  // timetable schedules are always valid (logic lives in the StrandTimeTable instance)
        }

        // Try to calculate a next run time to validate the schedule works
        _ = try nextRunTime(for: schedule, after: now, timezone: TimeZone(identifier: "UTC")!)
    }

    /// Get a human-readable description of when a schedule will next run
    public static func scheduleDescription(
        for schedule: SchedulePattern,
        from date: Date = Date(),
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) throws -> String {
        guard let nextRun = try nextRunTime(for: schedule, after: date, timezone: timezone) else {
            return "Schedule will not run again"
        }

        let style = Date.FormatStyle(
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: timezone
        ).month(.abbreviated).day().year().hour().minute()

        let interval = nextRun.timeIntervalSince(date)
        if interval < 3600 {
            let minutes = Int(interval / 60)
            return "Next run in \(minutes) minutes at \(nextRun.formatted(style))"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "Next run in \(hours) hours at \(nextRun.formatted(style))"
        } else {
            return "Next run at \(nextRun.formatted(style))"
        }
    }

    /// Calculate logical date for a given execution time and schedule
    ///
    /// **Logical Date Logic:**
    /// - Daily jobs process previous day's data (midnight to midnight)
    /// - Hourly jobs process previous hour's data
    /// - Weekly jobs process previous week's data
    /// - Monthly jobs process previous month's data
    ///
    /// **Example:**
    /// ```swift
    /// let config = PartitionOffsetConfig(offset: ISO8601Duration(days: 1, hours: 2))
    /// let logicalDate = try ScheduleCalculator.calculateLogicalDate(
    ///     executionTime: Date(), // 2017-06-30T02:00
    ///     schedule: .daily(hour: 2, minute: 0),
    ///     partitionOffset: config
    /// )
    /// // Result: 2017-06-29T00:00 (midnight of previous day)
    /// ```
    public static func calculateLogicalDate(
        executionTime: Date,
        schedule: SchedulePattern,
        partitionOffset: PartitionOffsetConfig
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = partitionOffset.timezone

        // Calculate logical date based on schedule type and offset
        let logicalDate = try calculateLogicalDate(
            executionTime: executionTime,
            schedule: schedule,
            partitionOffset: partitionOffset,
            calendar: calendar
        )

        return logicalDate
    }

    /// Calculate logical date for a given execution time
    /// This determines the data period that the job should process
    private static func calculateLogicalDate(
        executionTime: Date,
        schedule: SchedulePattern,
        partitionOffset: PartitionOffsetConfig,
        calendar: Calendar
    ) throws -> Date {
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        switch schedule {
        case .daily(_, _):
            // For daily schedules, apply partition offset to get the data period
            // Example: Job runs 2017-06-30T02:00 with PT0M -> logical date is 2017-06-29T00:00
            // Example: Job runs 2017-06-30T02:00 with P1D -> logical date is 2017-06-28T00:00
            let baseLogicalDate = partitionOffset.offset.subtract(
                from: executionTime,
                calendar: utcCalendar
            )
            let dayComponents = utcCalendar.dateComponents(
                [.year, .month, .day],
                from: baseLogicalDate
            )
            guard let result = utcCalendar.date(from: dayComponents) else {
                throw SchedulingError.invalidSchedule(
                    "could not construct date from calendar components"
                )
            }
            return result

        case .weekly(_, _):
            // For weekly schedules, apply partition offset then get start of that week
            let baseLogicalDate = partitionOffset.offset.subtract(
                from: executionTime,
                calendar: utcCalendar
            )
            let weekComponents = utcCalendar.dateComponents(
                [.yearForWeekOfYear, .weekOfYear],
                from: baseLogicalDate
            )
            var startOfWeek = weekComponents
            startOfWeek.weekday = 1  // Sunday
            startOfWeek.hour = 0
            startOfWeek.minute = 0
            startOfWeek.second = 0
            guard let result = utcCalendar.date(from: startOfWeek) else {
                throw SchedulingError.invalidSchedule(
                    "could not construct date from calendar components"
                )
            }
            return result

        case .monthly(_, _):
            // For monthly schedules, apply partition offset then get start of that month
            let baseLogicalDate = partitionOffset.offset.subtract(
                from: executionTime,
                calendar: utcCalendar
            )
            let monthComponents = utcCalendar.dateComponents(
                [.year, .month],
                from: baseLogicalDate
            )
            var startOfMonth = monthComponents
            startOfMonth.day = 1
            startOfMonth.hour = 0
            startOfMonth.minute = 0
            startOfMonth.second = 0
            guard let result = utcCalendar.date(from: startOfMonth) else {
                throw SchedulingError.invalidSchedule(
                    "could not construct date from calendar components"
                )
            }
            return result

        case .interval(let duration, _, _):
            // For interval schedules, apply partition offset then round to interval boundary
            let baseLogicalDate = partitionOffset.offset.subtract(
                from: executionTime,
                calendar: utcCalendar
            )
            let intervalSeconds = duration.components.seconds
            // Round down to the nearest interval boundary
            let intervalsSinceEpoch = Int(
                baseLogicalDate.timeIntervalSince1970 / Double(intervalSeconds)
            )
            return Date(timeIntervalSince1970: Double(intervalsSinceEpoch * Int(intervalSeconds)))

        case .cron(let expression, let storedOffset, _):
            // For well-known aliases (@daily, @weekly, @monthly, @yearly, @hourly,
            // @quarterly) with no explicit stored offset, apply the alias's natural
            // period default so logicalDate equals the previous period's start.
            // An explicit stored offset always takes priority.
            let effectiveOffset: ISO8601Duration
            if storedOffset.isZero,
                let aliasDefault = CronExpression.defaultPartitionOffset(for: expression)
            {
                effectiveOffset = aliasDefault
            } else {
                effectiveOffset = partitionOffset.offset
            }
            return effectiveOffset.subtract(from: executionTime, calendar: utcCalendar)

        case .once(_, _, _), .yearly(_, _):
            return partitionOffset.offset.subtract(from: executionTime, calendar: utcCalendar)
        case .timetable:
            // Timetable schedules don't have partition offset support; return execution time as-is.
            return executionTime
        }
    }

    /// Returns the natural period-default partition offset for a well-known named schedule.
    ///
    /// The period default ensures `logicalDate` equals the **start of the completed
    /// period**, not the period the job fires in.  A daily job running at 2 AM sees
    /// yesterday's midnight; a weekly job on Monday sees the previous Sunday midnight.
    ///
    /// > Note: The static factory methods `SchedulePattern.daily(hour:)`,
    /// > `.weekly(on:hour:)`, `.monthly(day:hour:)`, `.yearly(month:day:hour:)`, and
    /// > `.hourly(minute:)` already bake this offset into the stored `offset` component.
    /// > This function is useful when inspecting a raw enum case whose offset was
    /// > supplied directly (e.g. from the database) and you need the period default.
    public static func getDefaultPartitionOffset(for schedule: SchedulePattern) -> ISO8601Duration? {
        switch schedule {
        case .daily: return ISO8601Duration(days: 1)  // P1D
        case .weekly: return ISO8601Duration(days: 7)  // P1W
        case .monthly: return ISO8601Duration(months: 1)  // P1M
        case .yearly: return ISO8601Duration(years: 1)  // P1Y
        case .interval(let duration, _, _):
            let seconds = duration.components.seconds
            if seconds >= 3600 {
                return ISO8601Duration(hours: Int(seconds / 3600))
            } else if seconds >= 60 {
                return ISO8601Duration(minutes: Int(seconds / 60))
            } else {
                return ISO8601Duration(seconds: Int(seconds))
            }
        case .cron, .once, .timetable:
            return nil  // Raw cron/once schedules carry no implicit period default.
        }
    }
}
