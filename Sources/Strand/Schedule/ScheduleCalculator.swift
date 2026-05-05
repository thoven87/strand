#if canImport(FoundationEssentials)
public import FoundationEssentials
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
        case .daily(let offset, let tz):
            // Parse offset to extract hour and minute; forward the pattern timezone
            // so day-boundary extraction uses UTC (or whatever the schedule specifies)
            // rather than the server's local system timezone.
            do {
                let duration = try ISO8601Duration(offset)
                let totalMinutes = duration.hours * 60 + duration.minutes
                let hour = (totalMinutes / 60) % 24
                let minute = totalMinutes % 60
                return calculateDailyScheduledTime(
                    hour: hour,
                    minute: minute,
                    executionTime: executionTime,
                    timezone: tz
                )
            } catch {
                return calculateDailyScheduledTime(
                    hour: 0,
                    minute: 0,
                    executionTime: executionTime,
                    timezone: tz
                )
            }
        case .weekly(let offset, let tz):
            do {
                let duration = try ISO8601Duration(offset)
                let totalMinutes = duration.days * 24 * 60 + duration.hours * 60 + duration.minutes
                let dayOfWeek = (totalMinutes / (24 * 60)) % 7
                let remainingMinutes = totalMinutes % (24 * 60)
                let hour = remainingMinutes / 60
                let minute = remainingMinutes % 60
                return calculateWeeklyScheduledTime(
                    dayOfWeek: dayOfWeek,
                    hour: hour,
                    minute: minute,
                    executionTime: executionTime,
                    timezone: tz
                )
            } catch {
                return calculateWeeklyScheduledTime(
                    dayOfWeek: 0,
                    hour: 0,
                    minute: 0,
                    executionTime: executionTime,
                    timezone: tz
                )
            }
        case .monthly(let offset, let tz):
            do {
                let duration = try ISO8601Duration(offset)
                let day = duration.days + 1  // 1-indexed
                let hour = duration.hours
                let minute = duration.minutes
                return calculateMonthlyScheduledTime(
                    day: day,
                    hour: hour,
                    minute: minute,
                    executionTime: executionTime,
                    timezone: tz
                )
            } catch {
                return calculateMonthlyScheduledTime(
                    day: 1,
                    hour: 0,
                    minute: 0,
                    executionTime: executionTime,
                    timezone: tz
                )
            }
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

            if components.weekday == dayOfWeek + 1 {  // Calendar weekday is 1-based
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

    // MARK: - Job State Management

    /// Calculate the initial nextRunAt time for a new recurring job
    public static func initialNextRunTime(
        for schedule: SchedulePattern,
        createdAt: Date = Date(),
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) throws -> Date? {
        try nextRunTime(for: schedule, after: createdAt, timezone: timezone)
    }

    // MARK: - Validation and Utilities

    /// Validate that a schedule configuration is valid
    public static func validateSchedule(_ schedule: SchedulePattern) throws {
        switch schedule {
        case .cron(let expression, let offset, _):
            guard !expression.isEmpty else {
                throw SchedulingError.invalidSchedule("Cron expression cannot be empty")
            }
            try validateOffset(offset)
            // Try to parse the cron expression to ensure it's valid
            _ = try CronExpression(expression)
        case .daily(let offset, _):
            try validateOffset(offset)
        case .weekly(let offset, _):
            try validateOffset(offset)
        case .monthly(let offset, _):
            try validateOffset(offset)
        case .interval(let duration, let offset, _):
            guard duration.components.seconds > 0 else {
                throw SchedulingError.invalidSchedule("Interval must be greater than 0 seconds")
            }
            try validateOffset(offset)
        case .once(let date, let offset, _):
            guard date > Date() else {
                throw SchedulingError.invalidSchedule("One-time schedule must be in the future")
            }
            try validateOffset(offset)
        }

        // Try to calculate a next run time to validate the schedule works
        let testDate = Date()
        _ = try nextRunTime(for: schedule, after: testDate, timezone: TimeZone(identifier: "UTC")!)
    }

    /// Validate that an offset string is valid
    private static func validateOffset(_ offset: String) throws {
        guard !offset.isEmpty else {
            throw SchedulingError.invalidSchedule("Offset cannot be empty")
        }

        // Basic ISO 8601 duration format validation
        guard offset.hasPrefix("P") || offset.hasPrefix("PT") else {
            throw SchedulingError.invalidSchedule(
                "Offset must be in ISO 8601 duration format (e.g., PT2H, P1D)"
            )
        }

        // Try to parse the offset to ensure it's valid
        do {
            _ = try ISO8601Duration(offset)
        } catch {
            throw SchedulingError.invalidSchedule("Invalid offset format: \(offset)")
        }
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

    /// Calculate partition time for a given execution time and schedule
    ///
    /// **Partition Time Logic:**
    /// - Daily jobs process previous day's data (midnight to midnight)
    /// - Hourly jobs process previous hour's data
    /// - Weekly jobs process previous week's data
    /// - Monthly jobs process previous month's data
    ///
    /// **Example:**
    /// ```swift
    /// let config = PartitionOffsetConfig(offset: ISO8601Duration(days: 1, hours: 2))
    /// let partitionTime = try scheduler.calculatePartitionTime(
    ///     executionTime: Date(), // 2017-06-30T02:00
    ///     schedule: .daily(hour: 2, minute: 0),
    ///     partitionOffset: config
    /// )
    /// // Result: 2017-06-29T00:00 (midnight of previous day)
    /// ```
    public static func calculatePartitionTime(
        executionTime: Date,
        schedule: SchedulePattern,
        partitionOffset: PartitionOffsetConfig
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = partitionOffset.timezone

        // Calculate partition time based on schedule type and offset
        let partitionTime = try calculatePartitionTime(
            executionTime: executionTime,
            schedule: schedule,
            partitionOffset: partitionOffset,
            calendar: calendar
        )

        return partitionTime
    }

    /// Calculate partition time for a given execution time
    /// This determines the data period that the job should process
    private static func calculatePartitionTime(
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
            // Example: Job runs 2017-06-30T02:00 with PT0M -> partition time is 2017-06-29T00:00
            // Example: Job runs 2017-06-30T02:00 with P1D -> partition time is 2017-06-28T00:00
            let basePartitionTime = partitionOffset.offset.subtract(
                from: executionTime,
                calendar: utcCalendar
            )
            let dayComponents = utcCalendar.dateComponents(
                [.year, .month, .day],
                from: basePartitionTime
            )
            guard let result = utcCalendar.date(from: dayComponents) else {
                throw SchedulingError.invalidSchedule(
                    "could not construct date from calendar components"
                )
            }
            return result

        case .weekly(_, _):
            // For weekly schedules, apply partition offset then get start of that week
            let basePartitionTime = partitionOffset.offset.subtract(
                from: executionTime,
                calendar: utcCalendar
            )
            let weekComponents = utcCalendar.dateComponents(
                [.yearForWeekOfYear, .weekOfYear],
                from: basePartitionTime
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
            let basePartitionTime = partitionOffset.offset.subtract(
                from: executionTime,
                calendar: utcCalendar
            )
            let monthComponents = utcCalendar.dateComponents(
                [.year, .month],
                from: basePartitionTime
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
            let basePartitionTime = partitionOffset.offset.subtract(
                from: executionTime,
                calendar: utcCalendar
            )
            let intervalSeconds = duration.components.seconds
            // Round down to the nearest interval boundary
            let intervalsSinceEpoch = Int(
                basePartitionTime.timeIntervalSince1970 / Double(intervalSeconds)
            )
            return Date(timeIntervalSince1970: Double(intervalsSinceEpoch * Int(intervalSeconds)))

        case .cron(_, _, _), .once(_, _, _):
            // For cron and once schedules, use simple offset subtraction if available
            return partitionOffset.offset.subtract(from: executionTime, calendar: utcCalendar)
        }
    }

    /// Get default partition offset for well-known schedules
    /// These offsets determine the data period that recurring jobs should process
    /// - Daily jobs process previous day's data (midnight to midnight)
    /// - Hourly jobs process previous hour's data
    /// - Weekly jobs process previous week's data
    /// - Monthly jobs process previous month's data
    public static func getDefaultPartitionOffset(for schedule: SchedulePattern) -> ISO8601Duration? {
        switch schedule {
        case .daily(_, _):
            return .oneDay  // P1D - daily jobs process previous day's data
        case .weekly(_, _):
            return ISO8601Duration(days: 7)  // P7D - weekly jobs process previous week's data
        case .monthly(_, _):
            return .oneMonth  // P1M - monthly jobs process previous month's data
        case .interval(let duration, _, _):
            // For intervals, offset by one interval period to process previous period's data
            let seconds = duration.components.seconds
            if seconds >= 3600 {
                return ISO8601Duration(hours: Int(seconds / 3600))
            } else if seconds >= 60 {
                return ISO8601Duration(minutes: Int(seconds / 60))
            } else {
                return ISO8601Duration(seconds: Int(seconds))
            }
        case .cron(_, _, _), .once(_, _, _):
            return nil  // No default offset for cron/once schedules
        // All schedules now have built-in offset support
        }
    }
}
