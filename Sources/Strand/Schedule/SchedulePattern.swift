#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

/// Core schedule enumeration supporting various scheduling patterns
public enum SchedulePattern: Sendable, Codable, Equatable, Hashable {
    case cron(String, offset: String = "PT0M", timezone: TimeZone = TimeZone(identifier: "UTC")!)
    case interval(
        Duration, offset: String = "PT0M", timezone: TimeZone = TimeZone(identifier: "UTC")!)
    case daily(offset: String = "PT0H", timezone: TimeZone = TimeZone(identifier: "UTC")!)
    case weekly(offset: String = "PT0H", timezone: TimeZone = TimeZone(identifier: "UTC")!)
    case monthly(offset: String = "PT0H", timezone: TimeZone = TimeZone(identifier: "UTC")!)
    case once(at: Date, offset: String = "PT0M", timezone: TimeZone = TimeZone(identifier: "UTC")!)

    /// Calculate the next run time after the given date
    ///
    /// **Timezone-Aware Scheduling:**
    /// - All calculations use UTC internally for consistency across distributed systems
    /// - The `timezone` parameter interprets schedule times in the user's timezone
    /// - Return value is always in UTC for storage and execution
    /// - This prevents ambiguity in distributed environments and DST issues
    ///
    /// **Example:**
    /// ```swift
    /// let schedule = Schedule.daily(hour: 9, minute: 0) // 9 AM daily
    /// let nyTimezone = TimeZone(identifier: "America/New_York")!
    /// let nextRun = try schedule.nextRunTime(after: Date(), timezone: nyTimezone)
    /// // nextRun will be 9 AM New York time, but returned as UTC Date
    /// ```
    ///
    /// - Parameters:
    ///   - date: Reference date (preferably in UTC)
    ///   - timezone: User's timezone for schedule interpretation (defaults to UTC)
    /// - Returns: Next run time in UTC, or nil if no future runs
    public func nextRunTime(after date: Date, timezone: TimeZone = TimeZone(identifier: "UTC")!)
        throws -> Date?
    {
        switch self {
        case .cron(let expression, _, let scheduleTimezone):
            let cronExpr = try CronExpression(expression)
            return try cronExpr.nextRunTime(after: date, in: scheduleTimezone)

        case .interval(let duration, let offset, let scheduleTimezone):
            // For intervals, align to calendar boundaries then apply the schedule offset.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = scheduleTimezone

            let seconds = duration.components.seconds

            // Parse the schedule offset
            let scheduleOffset = try ISO8601Duration(offset)

            // For common intervals, align to natural boundaries in the specified timezone
            if seconds == 3600 {  // 1 hour
                let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
                var nextHour = components
                nextHour.hour = (components.hour ?? 0) + 1
                nextHour.minute = 0
                nextHour.second = 0
                guard let boundaryTime = calendar.date(from: nextHour) else { return nil }
                return scheduleOffset.apply(to: boundaryTime, calendar: calendar)
            } else if seconds == 86400 {  // 1 day
                let components = calendar.dateComponents([.year, .month, .day], from: date)
                var nextDay = components
                nextDay.day = (components.day ?? 0) + 1
                nextDay.hour = 0
                nextDay.minute = 0
                nextDay.second = 0
                guard let boundaryTime = calendar.date(from: nextDay) else { return nil }
                return scheduleOffset.apply(to: boundaryTime, calendar: calendar)
            } else {
                // For other intervals, check if we have a default offset (PT0M)
                // If so, use simple addition; otherwise use boundary alignment
                if offset == "PT0M" {
                    // Simple interval: just add the duration to the current time
                    let nextTime = date.addingTimeInterval(TimeInterval(seconds))
                    return scheduleOffset.apply(to: nextTime, calendar: calendar)
                } else {
                    // Custom intervals with specific offsets, align to boundaries
                    // Convert to timezone-aware calculation using Unix epoch alignment
                    let intervalSeconds = Double(seconds)

                    // Get timezone offset to ensure boundaries align correctly in local time
                    let timezoneOffset = Double(scheduleTimezone.secondsFromGMT(for: date))
                    let adjustedTime = date.timeIntervalSince1970 + timezoneOffset

                    // Add a small epsilon to ensure we go to NEXT boundary if exactly on current one
                    let epsilon = 0.001  // 1ms to handle floating point precision
                    let nextBoundary =
                        ceil((adjustedTime + epsilon) / intervalSeconds) * intervalSeconds
                    let boundaryTime = Date(timeIntervalSince1970: nextBoundary - timezoneOffset)
                    return scheduleOffset.apply(to: boundaryTime, calendar: calendar)
                }
            }

        case .daily(let offset, let scheduleTimezone):
            return try calculateDailyNextRunTime(
                offset: offset, after: date, timezone: scheduleTimezone)

        case .weekly(let offset, let scheduleTimezone):
            return try calculateWeeklyNextRunTime(
                offset: offset, after: date, timezone: scheduleTimezone)

        case .monthly(let offset, let scheduleTimezone):
            return try calculateMonthlyNextRunTime(
                offset: offset, after: date, timezone: scheduleTimezone)

        case .once(let scheduledDate, _, _):
            return scheduledDate > date ? scheduledDate : nil
        }
    }

    /// Helper methods for offset-based schedule calculations
    private func calculateDailyNextRunTime(offset: String, after date: Date, timezone: TimeZone)
        throws -> Date?
    {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let duration = try ISO8601Duration(offset)
        let totalMinutes = duration.days * 24 * 60 + duration.hours * 60 + duration.minutes
        var comps = DateComponents()
        comps.hour = (totalMinutes / 60) % 24
        comps.minute = totalMinutes % 60
        comps.second = 0
        return cal.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
    }

    private func calculateWeeklyNextRunTime(offset: String, after date: Date, timezone: TimeZone)
        throws -> Date?
    {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let duration = try ISO8601Duration(offset)
        let totalMinutes = duration.days * 24 * 60 + duration.hours * 60 + duration.minutes
        let dayIndex = (totalMinutes / (24 * 60)) % 7
        let calWeekday = dayIndex == 0 ? 7 : dayIndex  // 0→Sat(7), 1→Sun(1) … 6→Fri(6)
        let remainingMins = totalMinutes % (24 * 60)
        var comps = DateComponents()
        comps.weekday = calWeekday
        comps.hour = remainingMins / 60
        comps.minute = remainingMins % 60
        comps.second = 0
        return cal.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
    }

    private func calculateMonthlyNextRunTime(offset: String, after date: Date, timezone: TimeZone)
        throws -> Date?
    {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let duration = try ISO8601Duration(offset)
        var comps = DateComponents()
        comps.day = duration.days + 1  // P0D → day 1, P14D → day 15
        comps.hour = duration.hours
        comps.minute = duration.minutes
        comps.second = 0
        return cal.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
    }

    /// Human-readable description of the schedule
    public var description: String {
        // Helper function to check if timezone is UTC/GMT
        func isUTCTimezone(_ timezone: TimeZone) -> Bool {
            timezone.identifier == "UTC" || timezone.identifier == "GMT"
        }

        // Format HH:MM from hour and minute integers.
        func hhmm(_ h: Int, _ m: Int) -> String { String(format: "%02d:%02d", h, m) }

        // Timezone suffix — omit when UTC (the common case).
        func tzSuffix(_ tz: TimeZone) -> String {
            isUTCTimezone(tz) ? " UTC" : " (\(tz.identifier))"
        }

        switch self {
        case .cron(let expression, let offset, let timezone):
            let offsetDesc = (offset == "PT0M" || offset == "PT0H") ? "" : " offset \(offset)"
            return "Cron \(expression)\(offsetDesc)\(tzSuffix(timezone))"

        case .interval(let duration, let offset, let timezone):
            let offsetDesc = (offset == "PT0M" || offset == "PT0H") ? "" : " offset \(offset)"
            return "Every \(duration.humanReadable)\(offsetDesc)\(tzSuffix(timezone))"

        case .daily(let offset, let timezone):
            // offset encodes the time-of-day: PT15M = 00:15, PT9H = 09:00.
            guard let d = try? ISO8601Duration(offset) else { return "Daily (offset: \(offset))" }
            let totalMin = d.hours * 60 + d.minutes
            return "Daily at \(hhmm(totalMin / 60, totalMin % 60))\(tzSuffix(timezone))"

        case .weekly(let offset, let timezone):
            // offset encodes weekday + time: P6DT9H = Calendar weekday 6 (Friday) at 09:00.
            // days component is a Calendar weekday index (1=Sun … 7=Sat).
            guard let d = try? ISO8601Duration(offset) else { return "Weekly (offset: \(offset))" }
            let totalMin = d.days * 24 * 60 + d.hours * 60 + d.minutes
            let dayIndex = (totalMin / (24 * 60)) % 7  // 0–6
            let weekday = dayIndex == 0 ? 7 : dayIndex  // Calendar weekday 1–7
            let timeMin = totalMin % (24 * 60)
            let dayNames = [
                "", "Sunday", "Monday", "Tuesday", "Wednesday",
                "Thursday", "Friday", "Saturday",
            ]
            let day = weekday < dayNames.count ? dayNames[weekday] : "Day \(weekday)"
            return "Every \(day) at \(hhmm(timeMin / 60, timeMin % 60))\(tzSuffix(timezone))"

        case .monthly(let offset, let timezone):
            // offset encodes day-of-month + time: P0D = day 1, P14D = day 15.
            guard let d = try? ISO8601Duration(offset) else { return "Monthly (offset: \(offset))" }
            let dayOfMonth = d.days + 1  // 1-indexed
            let timeMin = d.hours * 60 + d.minutes
            let suffix: String
            switch dayOfMonth {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
            return
                "Monthly on the \(dayOfMonth)\(suffix) at \(hhmm(timeMin / 60, timeMin % 60))\(tzSuffix(timezone))"

        case .once(let date, _, let timezone):
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timezone
            let h = cal.component(.hour, from: date)
            let m = cal.component(.minute, from: date)
            let y = cal.component(.year, from: date)
            let mo = cal.component(.month, from: date)
            let dy = cal.component(.day, from: date)
            return String(
                format: "Once on %04d-%02d-%02d at %02d:%02d%@",
                y, mo, dy, h, m, tzSuffix(timezone))
        }
    }

    /// Get the partition offset string if this schedule has one
    public var partitionOffset: String? {
        switch self {
        case .cron(_, let offset, _),
            .interval(_, let offset, _),
            .daily(let offset, _),
            .weekly(let offset, _),
            .monthly(let offset, _),
            .once(_, let offset, _):
            return offset != "PT0M" && offset != "PT0H" ? offset : nil
        }
    }

    /// Get the timezone for this schedule pattern
    public var timezone: TimeZone {
        switch self {
        case .cron(_, _, let timezone),
            .interval(_, _, let timezone),
            .daily(_, let timezone),
            .weekly(_, let timezone),
            .monthly(_, let timezone),
            .once(_, _, let timezone):
            return timezone
        }
    }

    // MARK: - Equatable Implementation
    public static func == (lhs: SchedulePattern, rhs: SchedulePattern) -> Bool {
        switch (lhs, rhs) {
        case (
            .cron(let lhsExpr, let lhsOffset, let lhsTimezone),
            .cron(let rhsExpr, let rhsOffset, let rhsTimezone)
        ):
            return lhsExpr == rhsExpr && lhsOffset == rhsOffset && lhsTimezone == rhsTimezone

        case (
            .interval(let lhsDuration, let lhsOffset, let lhsTimezone),
            .interval(let rhsDuration, let rhsOffset, let rhsTimezone)
        ):
            return lhsDuration == rhsDuration && lhsOffset == rhsOffset
                && lhsTimezone == rhsTimezone

        case (
            .daily(let lhsOffset, let lhsTimezone),
            .daily(let rhsOffset, let rhsTimezone)
        ):
            return lhsOffset == rhsOffset && lhsTimezone == rhsTimezone

        case (
            .weekly(let lhsOffset, let lhsTimezone),
            .weekly(let rhsOffset, let rhsTimezone)
        ):
            return lhsOffset == rhsOffset && lhsTimezone == rhsTimezone

        case (
            .monthly(let lhsOffset, let lhsTimezone),
            .monthly(let rhsOffset, let rhsTimezone)
        ):
            return lhsOffset == rhsOffset && lhsTimezone == rhsTimezone

        case (
            .once(let lhsDate, let lhsOffset, let lhsTimezone),
            .once(let rhsDate, let rhsOffset, let rhsTimezone)
        ):
            return lhsDate == rhsDate && lhsOffset == rhsOffset && lhsTimezone == rhsTimezone

        default:
            return false
        }
    }

    // MARK: - Hashable Implementation
    public func hash(into hasher: inout Hasher) {
        // Use deterministic hashing for consistent shard placement and routing
        let deterministicHash =
            switch self {
            case .cron(let expression, let offset, let timezone):
                DeterministicHasher.hash("cron:\(expression):\(offset):\(timezone.identifier)")

            case .interval(let duration, let offset, let timezone):
                DeterministicHasher.hash("interval:\(duration):\(offset):\(timezone.identifier)")

            case .daily(let offset, let timezone):
                DeterministicHasher.hash("daily:\(offset):\(timezone.identifier)")

            case .weekly(let offset, let timezone):
                DeterministicHasher.hash("weekly:\(offset):\(timezone.identifier)")

            case .monthly(let offset, let timezone):
                DeterministicHasher.hash("monthly:\(offset):\(timezone.identifier)")

            case .once(let date, let offset, let timezone):
                DeterministicHasher.hash(
                    "once:\(date.timeIntervalSince1970):\(offset):\(timezone.identifier)")
            }

        hasher.combine(deterministicHash)
    }

    /// Check if this schedule type supports partition offsets
    public var supportsPartitionOffset: Bool { true }
}
