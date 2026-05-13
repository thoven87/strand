#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// Core schedule enumeration supporting various scheduling patterns
public enum SchedulePattern: Sendable, Codable, Equatable, Hashable {
    case cron(String, offset: String = "PT0M", timezone: TimeZone = TimeZone(identifier: "UTC")!)
    case interval(
        Duration,
        offset: String = "PT0M",
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    )
    case daily(offset: String = "PT0H", timezone: TimeZone = TimeZone(identifier: "UTC")!)
    case weekly(offset: String = "PT0H", timezone: TimeZone = TimeZone(identifier: "UTC")!)
    case monthly(offset: String = "PT0H", timezone: TimeZone = TimeZone(identifier: "UTC")!)
    case yearly(offset: String = "PT0H", timezone: TimeZone = TimeZone(identifier: "UTC")!)
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
    public func nextRunTime(
        after date: Date,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    )
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
            } else if seconds > 0 && seconds % 86400 == 0 {
                // N whole-day intervals (1 day, 7 days, 14 days, …).
                //
                // calendar.date(byAdding: .day, value: N, to: startOfDay) resolves the
                // correct UTC instant for “same wall-clock time N calendar days later” in
                // the schedule’s timezone, correctly handling DST transitions:
                //   • Fall-back  (e.g. Nov 3 US): a 7-day gap spans 25 h in UTC, yet
                //     the next fire time stays at 00:00 local.
                //   • Spring-forward (e.g. Mar 9 US): a 7-day gap spans 23 h in UTC,
                //     yet the next fire time stays at 00:00 local.
                //
                // No epsilon needed: startOfDay ≤ date, so startOfDay + N days > date
                // for any N ≥ 1.
                let nDays = Int(seconds / 86400)
                let startOfCurrentDay = calendar.startOfDay(for: date)
                guard
                    let boundaryTime = calendar.date(
                        byAdding: .day,
                        value: nDays,
                        to: startOfCurrentDay
                    )
                else { return nil }
                return scheduleOffset.apply(to: boundaryTime, calendar: calendar)
            } else {
                // All non-standard intervals snap to epoch-aligned boundaries.
                //
                //   .interval(.hours(1))                   → 00:00, 01:00, 02:00 …
                //   .interval(.seconds(5400))              → 00:00, 01:30, 03:00 …  (90 min)
                //   .interval(.hours(1), offset: "PT45M")  → 00:45, 01:45, 02:45 …
                //   .interval(.seconds(5400), offset: "PT5M") → 00:05, 01:35, 03:05 …
                //
                // A schedule registered at 3:10 fires first at the next grid boundary,
                // not at 3:10 + interval.
                let intervalSeconds = Double(seconds)
                let timezoneOffset = Double(scheduleTimezone.secondsFromGMT(for: date))
                let adjustedTime = date.timeIntervalSince1970 + timezoneOffset
                // Small epsilon so a time that falls exactly ON a boundary advances to
                // the NEXT one rather than staying at the current one.
                let epsilon = 0.001
                // Shift the reference time back by the offset before computing the
                // epoch boundary.  Slot times are (offsetSecs + n*intervalSecs), so
                // subtracting offsetSecs here maps the problem onto the plain
                // epoch-grid, and the subsequent scheduleOffset.apply() adds it back.
                //
                // Without this, from 0:10 with offset PT45M and a 90-min interval the
                // code found the epoch boundary at 1:30 then added 45 min → 2:15,
                // skipping the 0:45 slot entirely.
                let offsetSecs = scheduleOffset.timeInterval
                let adjustedTimeForBoundary = adjustedTime - offsetSecs
                let nextBoundary =
                    ((adjustedTimeForBoundary + epsilon) / intervalSeconds).rounded(.up)
                    * intervalSeconds
                let boundaryTime = Date(timeIntervalSince1970: nextBoundary - timezoneOffset)
                return scheduleOffset.apply(to: boundaryTime, calendar: calendar)
            }

        case .daily(let offset, let scheduleTimezone):
            return try calculateDailyNextRunTime(
                offset: offset,
                after: date,
                timezone: scheduleTimezone
            )

        case .weekly(let offset, let scheduleTimezone):
            return try calculateWeeklyNextRunTime(
                offset: offset,
                after: date,
                timezone: scheduleTimezone
            )

        case .monthly(let offset, let scheduleTimezone):
            return try calculateMonthlyNextRunTime(
                offset: offset,
                after: date,
                timezone: scheduleTimezone
            )

        case .yearly(let offset, let scheduleTimezone):
            return try calculateYearlyNextRunTime(
                offset: offset,
                after: date,
                timezone: scheduleTimezone
            )

        case .once(let scheduledDate, _, _):
            return scheduledDate > date ? scheduledDate : nil
        }
    }

    /// Helper methods for offset-based schedule calculations
    private func calculateDailyNextRunTime(
        offset: String,
        after date: Date,
        timezone: TimeZone
    )
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

    private func calculateWeeklyNextRunTime(
        offset: String,
        after date: Date,
        timezone: TimeZone
    )
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

    private func calculateMonthlyNextRunTime(
        offset: String,
        after date: Date,
        timezone: TimeZone
    )
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

    private func calculateYearlyNextRunTime(
        offset: String,
        after date: Date,
        timezone: TimeZone
    ) throws -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let duration = try ISO8601Duration(offset)
        let month = duration.months + 1  // 0-indexed → 1-indexed Calendar month
        let day = duration.days + 1  // 0-indexed → 1-indexed Calendar day
        var comps = DateComponents()
        comps.month = month
        comps.day = day
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

        case .yearly(let offset, let timezone):
            guard let d = try? ISO8601Duration(offset) else {
                return "Yearly (offset: \(offset))\(tzSuffix(timezone))"
            }
            let monthNames = [
                "January", "February", "March", "April", "May", "June",
                "July", "August", "September", "October", "November", "December",
            ]
            let monthIdx = max(0, min(d.months, 11))
            let dayOfMonth = d.days + 1
            let timeMin = d.hours * 60 + d.minutes
            let suffix: String
            switch dayOfMonth {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
            return
                "Yearly on \(monthNames[monthIdx]) \(dayOfMonth)\(suffix)"
                + " at \(hhmm(timeMin / 60, timeMin % 60))\(tzSuffix(timezone))"

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
                y,
                mo,
                dy,
                h,
                m,
                tzSuffix(timezone)
            )
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
            .yearly(let offset, _),
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
            .yearly(_, let timezone),
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

        case (
            .yearly(let lhsOffset, let lhsTimezone),
            .yearly(let rhsOffset, let rhsTimezone)
        ):
            return lhsOffset == rhsOffset && lhsTimezone == rhsTimezone

        default:
            return false
        }
    }

    // MARK: - Hashable
    public func hash(into hasher: inout Hasher) {
        // Standard per-case combine — Swift's Hasher already produces good
        // distribution and is the correct tool for Hashable conformance.
        // (Cross-process stability is NOT a goal of Hashable; use a separate
        // explicit function when a stable routing key is needed.)
        switch self {
        case .cron(let expression, let offset, let timezone):
            hasher.combine(0)
            hasher.combine(expression)
            hasher.combine(offset)
            hasher.combine(timezone.identifier)
        case .interval(let duration, let offset, let timezone):
            hasher.combine(1)
            hasher.combine(duration.components.seconds)
            hasher.combine(duration.components.attoseconds)
            hasher.combine(offset)
            hasher.combine(timezone.identifier)
        case .daily(let offset, let timezone):
            hasher.combine(2)
            hasher.combine(offset)
            hasher.combine(timezone.identifier)
        case .weekly(let offset, let timezone):
            hasher.combine(3)
            hasher.combine(offset)
            hasher.combine(timezone.identifier)
        case .monthly(let offset, let timezone):
            hasher.combine(4)
            hasher.combine(offset)
            hasher.combine(timezone.identifier)
        case .once(let date, let offset, let timezone):
            hasher.combine(5)
            hasher.combine(date.timeIntervalSince1970)
            hasher.combine(offset)
            hasher.combine(timezone.identifier)
        case .yearly(let offset, let timezone):
            hasher.combine(6)
            hasher.combine(offset)
            hasher.combine(timezone.identifier)
        }
    }

    /// Check if this schedule type supports partition offsets
    public var supportsPartitionOffset: Bool { true }
}

// MARK: - Ergonomic schedule factories

extension SchedulePattern {

    // MARK: Daily

    /// Fires every day at the specified hour and minute.
    ///
    /// ```swift
    /// .daily(hour: 9, minute: 30)    // 09:30 UTC every day
    /// .daily(hour: 0, timezone: .init(identifier: "America/New_York")!)
    /// ```
    public static func daily(
        hour: Int,
        minute: Int = 0,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        let offset = minute == 0 ? "PT\(hour)H" : "PT\(hour)H\(minute)M"
        return .daily(offset: offset, timezone: timezone)
    }

    // MARK: Weekly

    /// Fires once per week on the specified day at the specified hour and minute.
    ///
    /// ```swift
    /// .weekly(on: .monday, hour: 9)             // Monday 09:00 UTC
    /// .weekly(on: .friday, hour: 17, minute: 30) // Friday 17:30 UTC
    /// ```
    public static func weekly(
        on day: Weekday,
        hour: Int,
        minute: Int = 0,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        let d = day.rawValue  // matches the internal P{n}D dayIndex encoding
        let offset = minute == 0 ? "P\(d)DT\(hour)H" : "P\(d)DT\(hour)H\(minute)M"
        return .weekly(offset: offset, timezone: timezone)
    }

    // MARK: Monthly

    /// Fires once per month on the specified day-of-month at the specified hour and minute.
    ///
    /// `day` is 1-indexed (1 = first of month, 28 = 28th of month).
    ///
    /// ```swift
    /// .monthly(day: 1, hour: 0)          // 1st of each month at midnight UTC
    /// .monthly(day: 15, hour: 10, minute: 30) // 15th of each month at 10:30 UTC
    /// ```
    public static func monthly(
        day: Int,
        hour: Int,
        minute: Int = 0,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        let d = day - 1  // convert 1-indexed day to 0-indexed P{n}D offset
        let offset = minute == 0 ? "P\(d)DT\(hour)H" : "P\(d)DT\(hour)H\(minute)M"
        return .monthly(offset: offset, timezone: timezone)
    }

    // MARK: Yearly

    /// Fires once per year on the specified month and day at the specified time.
    ///
    /// Using the `Month` enum prevents off-by-one mistakes (no `month: 0` or
    /// `month: 13`) and makes the intent self-documenting at the call site.
    ///
    /// ```swift
    /// .yearly(month: .january,  day: 1,  hour: 0)         // New Year's Day midnight
    /// .yearly(month: .march,    day: 15, hour: 10, minute: 30)  // March 15th 10:30
    /// .yearly(month: .december, day: 25, hour: 8, timezone: nyTZ) // Christmas 8 AM NY
    /// ```
    ///
    /// - Parameters:
    ///   - month: The calendar month (`.january` – `.december`).
    ///   - day:   Day of month (1–31).
    public static func yearly(
        month: Month,
        day: Int,
        hour: Int,
        minute: Int = 0,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        let m = month.rawValue - 1  // Month.rawValue is 1-indexed; P{m}M is 0-indexed
        let d = day - 1  // day is 1-indexed; P{d}D is 0-indexed
        let offset = minute == 0 ? "P\(m)M\(d)DT\(hour)H" : "P\(m)M\(d)DT\(hour)H\(minute)M"
        return .yearly(offset: offset, timezone: timezone)
    }
}
