#if canImport(FoundationEssentials)
public import FoundationEssentials
import Foundation  // String(format:) not in FoundationEssentials on Linux
#else
public import Foundation
#endif

/// Core schedule enumeration supporting various scheduling patterns
public enum SchedulePattern: Sendable, Codable, Equatable, Hashable {
    case cron(String, offset: ISO8601Duration = .zero, timezone: TimeZone = TimeZone(identifier: "UTC")!)
    case interval(
        Duration,
        offset: ISO8601Duration = .zero,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    )
    case daily(offset: ISO8601Duration = .zero, timezone: TimeZone = TimeZone(identifier: "UTC")!)
    case weekly(offset: ISO8601Duration = .zero, timezone: TimeZone = TimeZone(identifier: "UTC")!)
    case monthly(offset: ISO8601Duration = .zero, timezone: TimeZone = TimeZone(identifier: "UTC")!)
    case yearly(offset: ISO8601Duration = .zero, timezone: TimeZone = TimeZone(identifier: "UTC")!)
    case once(at: Date, offset: ISO8601Duration = .zero, timezone: TimeZone = TimeZone(identifier: "UTC")!)
    /// A fully custom schedule driven by a ``StrandTimeTable`` implementation.
    ///
    /// The `description` string is stored in the database and shown in the
    /// Loom schedule list.  The actual timetable logic lives in memory inside
    /// the ``StrandScheduler`` — only the scheduler's registered
    /// ``StrandTimeTable`` instance determines when the next fire time is.
    case timetable(description: String)

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

        case .interval(let duration, let scheduleOffset, let scheduleTimezone):
            // For intervals, align to calendar boundaries then apply the schedule offset.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = scheduleTimezone

            let seconds = duration.components.seconds

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

        case .timetable:
            // Timetable next-run computation requires the in-memory StrandTimeTable
            // instance held by StrandScheduler — it cannot be derived from the
            // serialised pattern alone.  Return nil here; the scheduler detects
            // the .timetable case and delegates to the registered instance.
            return nil
        }
    }

    /// Helper methods for offset-based schedule calculations
    private func calculateDailyNextRunTime(
        offset: ISO8601Duration,
        after date: Date,
        timezone: TimeZone
    )
        throws -> Date?
    {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let totalMinutes = offset.days * 24 * 60 + offset.hours * 60 + offset.minutes
        var comps = DateComponents()
        comps.hour = (totalMinutes / 60) % 24
        comps.minute = totalMinutes % 60
        comps.second = 0
        return cal.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
    }

    private func calculateWeeklyNextRunTime(
        offset: ISO8601Duration,
        after date: Date,
        timezone: TimeZone
    )
        throws -> Date?
    {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let totalMinutes = offset.days * 24 * 60 + offset.hours * 60 + offset.minutes
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
        offset: ISO8601Duration,
        after date: Date,
        timezone: TimeZone
    )
        throws -> Date?
    {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        var comps = DateComponents()
        comps.day = offset.days + 1  // P0D → day 1, P14D → day 15
        comps.hour = offset.hours
        comps.minute = offset.minutes
        comps.second = 0
        return cal.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
    }

    private func calculateYearlyNextRunTime(
        offset: ISO8601Duration,
        after date: Date,
        timezone: TimeZone
    ) throws -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let month = offset.months + 1  // 0-indexed → 1-indexed Calendar month
        let day = offset.days + 1  // 0-indexed → 1-indexed Calendar day
        var comps = DateComponents()
        comps.month = month
        comps.day = day
        comps.hour = offset.hours
        comps.minute = offset.minutes
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
            let offsetDesc = offset.isZero ? "" : " offset \(offset)"
            return "Cron \(expression)\(offsetDesc)\(tzSuffix(timezone))"

        case .interval(let duration, let offset, let timezone):
            let offsetDesc = offset.isZero ? "" : " offset \(offset)"
            return "Every \(duration.humanReadable)\(offsetDesc)\(tzSuffix(timezone))"

        case .daily(let offset, let timezone):
            // offset encodes the time-of-day: hours=9, minutes=0 → 09:00.
            let totalMin = offset.hours * 60 + offset.minutes
            return "Daily at \(hhmm(totalMin / 60, totalMin % 60))\(tzSuffix(timezone))"

        case .weekly(let offset, let timezone):
            // offset encodes weekday + time: days=5 (Friday), hours=9 → Friday 09:00.
            let totalMin = offset.days * 24 * 60 + offset.hours * 60 + offset.minutes
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
            // offset encodes day-of-month + time: days=0 → day 1, days=14 → day 15.
            let dayOfMonth = offset.days + 1  // 1-indexed
            let timeMin = offset.hours * 60 + offset.minutes
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
            let monthNames = [
                "January", "February", "March", "April", "May", "June",
                "July", "August", "September", "October", "November", "December",
            ]
            let monthIdx = max(0, min(offset.months, 11))
            let dayOfMonth = offset.days + 1
            let timeMin = offset.hours * 60 + offset.minutes
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

        case .timetable(let desc):
            return "Timetable: \(desc)"

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
            return offset.isZero ? nil : offset.description
        case .timetable:
            return nil
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
        case .timetable:
            return TimeZone(identifier: "UTC")!
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

        case (.timetable(let d1), .timetable(let d2)):
            return d1 == d2
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
        case .timetable(let description):
            hasher.combine(7)
            hasher.combine(description)
        }
    }

    /// Check if this schedule type supports partition offsets
    public var supportsPartitionOffset: Bool {
        if case .timetable = self { return false }
        return true
    }
}

// MARK: - Ergonomic schedule factories

extension SchedulePattern {

    // MARK: - Private helpers

    /// Maps a ``Weekday`` to its standard cron day-of-week number.
    /// Cron convention: Sun=0, Mon=1, Tue=2, Wed=3, Thu=4, Fri=5, Sat=6.
    private static func cronDay(_ day: Weekday) -> Int {
        switch day {
        case .sunday: return 0
        case .monday: return 1
        case .tuesday: return 2
        case .wednesday: return 3
        case .thursday: return 4
        case .friday: return 5
        case .saturday: return 6
        }
    }

    // MARK: - Weekdays (Mon–Fri)

    /// Fires every weekday (Monday through Friday) at the specified hour and minute.
    ///
    /// ```swift
    /// .weekdays(hour: 9)                    // 09:00 UTC every weekday
    /// .weekdays(hour: 9, timezone: nyTZ)    // 09:00 Eastern every weekday
    /// ```
    public static func weekdays(
        hour: Int,
        minute: Int = 0,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        .cron("\(minute) \(hour) * * 1-5", timezone: timezone)
    }

    /// Fires every weekday (Monday through Friday) at each of the specified hours.
    ///
    /// ```swift
    /// .weekdays(hours: 9, 16)                  // 09:00 and 16:00 UTC every weekday
    /// .weekdays(hours: 8, 12, 17, minute: 30)  // 08:30, 12:30, 17:30 every weekday
    /// ```
    public static func weekdays(
        hours: Int...,
        minute: Int = 0,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        let h = hours.sorted().map { String($0) }.joined(separator: ",")
        return .cron("\(minute) \(h) * * 1-5", timezone: timezone)
    }

    // MARK: - Specific weekday selection

    /// Fires on the selected weekdays at the specified hour and minute.
    ///
    /// ```swift
    /// .onDays(.monday, .wednesday, .friday, hour: 9)      // MWF at 09:00 UTC
    /// .onDays(.tuesday, .thursday, hour: 8, minute: 30)   // TuTh at 08:30
    /// ```
    public static func onDays(
        _ days: Weekday...,
        hour: Int,
        minute: Int = 0,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        let d = days.map { cronDay($0) }.sorted().map { String($0) }.joined(separator: ",")
        return .cron("\(minute) \(hour) * * \(d)", timezone: timezone)
    }

    /// Fires on the selected weekdays at each of the specified hours.
    ///
    /// ```swift
    /// .onDays(.monday, .wednesday, .friday, hours: 8, 14)
    /// // 08:00 and 14:00 on Mon, Wed, Fri
    /// ```
    public static func onDays(
        _ days: Weekday...,
        hours: Int...,
        minute: Int = 0,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        let d = days.map { cronDay($0) }.sorted().map { String($0) }.joined(separator: ",")
        let h = hours.sorted().map { String($0) }.joined(separator: ",")
        return .cron("\(minute) \(h) * * \(d)", timezone: timezone)
    }

    // MARK: - Multiple hours per day

    /// Fires every day at each of the specified hours.
    ///
    /// ```swift
    /// .onHours(8, 12, 17)              // 08:00, 12:00, 17:00 UTC every day
    /// .onHours(9, 14, minute: 30)      // 09:30 and 14:30 UTC every day
    /// ```
    public static func onHours(
        _ hours: Int...,
        minute: Int = 0,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        let h = hours.sorted().map { String($0) }.joined(separator: ",")
        return .cron("\(minute) \(h) * * *", timezone: timezone)
    }

    // MARK: - Specific dates of the month

    /// Fires on the specified day-of-month values at the given hour and minute.
    ///
    /// Days are 1-indexed.
    ///
    /// ```swift
    /// .onDates(1, 15, hour: 9)         // 1st and 15th of each month at 09:00 UTC
    /// .onDates(1, 8, 15, 22, hour: 0)  // weekly-ish: every 7 days at midnight
    /// ```
    public static func onDates(
        _ dates: Int...,
        hour: Int,
        minute: Int = 0,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        let d = dates.sorted().map { String($0) }.joined(separator: ",")
        return .cron("\(minute) \(hour) \(d) * *", timezone: timezone)
    }

    // MARK: - Sub-hourly (multiple minutes)

    /// Fires at specific minutes past every hour.
    ///
    /// ```swift
    /// .onMinutes(0, 15, 30, 45)   // every 15 minutes
    /// .onMinutes(0, 30)           // every 30 minutes
    /// ```
    public static func onMinutes(
        _ minutes: Int...,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        let m = minutes.sorted().map { String($0) }.joined(separator: ",")
        return .cron("\(m) * * * *", timezone: timezone)
    }

    // MARK: - Hourly

    /// Fires once per hour at the specified minute past the hour.
    ///
    /// `logicalDate` is the **previous hour's UTC start** — the top of the hour
    /// that just completed.  Use it to scope queries to the last hour's data:
    ///
    /// ```swift
    /// // Fires at :00 of every hour (01:00, 02:00, …).
    /// // context.schedulingMetadata?.logicalDate == previous hour T:00:00Z
    /// .hourly()
    ///
    /// // Fires at :30 past every hour.
    /// .hourly(minute: 30)
    /// ```
    public static func hourly(
        minute: Int = 0,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        // PT1H (period default) + PT{minute}M (intra-hour fire time).
        // calculateDailyNextRunTime absorbs PT1H via (totalMinutes / 60) % 24
        // — but hourly schedules use .interval(.hours(1)) internally, not .daily.
        // Use a 1-hour interval so the partition offset machinery for .interval
        // correctly rounds to the previous hour boundary.
        .interval(.seconds(3600), offset: ISO8601Duration(hours: 1, minutes: minute), timezone: timezone)
    }

    // MARK: - Daily

    /// Fires every day at the specified hour and minute.
    ///
    /// `logicalDate` (available via ``WorkflowContext/schedulingMetadata``) is the
    /// **previous day's UTC midnight** — the start of the completed day, not the day
    /// the job runs on.  Use it to scope queries to yesterday's data without
    /// computing offsets inside the workflow:
    ///
    /// ```swift
    /// // Fires at 02:00 UTC every day.
    /// // context.schedulingMetadata?.logicalDate == yesterday T00:00:00Z
    /// .daily(hour: 2)
    ///
    /// // Same, but fires at 09:30 Eastern time.
    /// .daily(hour: 9, minute: 30, timezone: .et)
    /// ```
    public static func daily(
        hour: Int,
        minute: Int = 0,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        // P1D (period default) + PT{hour}H{minute}M (intra-day fire time).
        // calculateDailyNextRunTime absorbs P1D via (totalMinutes / 60) % 24 so
        // the fire time stays at `hour:minute`.  The full subtraction crosses into
        // the previous day before being truncated to midnight.
        .daily(offset: ISO8601Duration(days: 1, hours: hour, minutes: minute), timezone: timezone)
    }

    // MARK: Weekly

    /// Fires once per week on the specified day at the specified hour and minute.
    ///
    /// `logicalDate` is the **previous week's UTC Sunday midnight** — the start
    /// of the week that just completed.  Use it to scope queries to last week's
    /// data without computing offsets inside the workflow:
    ///
    /// ```swift
    /// // Fires every Monday at 09:00 UTC.
    /// // context.schedulingMetadata?.logicalDate == previous Sunday T00:00:00Z
    /// .weekly(on: .monday, hour: 9)
    ///
    /// // Same, but fires Friday at 17:30 Eastern.
    /// .weekly(on: .friday, hour: 17, minute: 30, timezone: .et)
    /// ```
    public static func weekly(
        on day: Weekday,
        hour: Int,
        minute: Int = 0,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        // P7D (period default) + P{day}DT{hour}H{minute}M (intra-week fire time).
        // calculateWeeklyNextRunTime absorbs P7D via dayIndex % 7, so the fire
        // weekday is unchanged.  The full offset crosses into the previous week
        // before truncating to its Sunday midnight.
        .weekly(
            offset: ISO8601Duration(days: 7 + day.rawValue, hours: hour, minutes: minute),
            timezone: timezone
        )
    }

    // MARK: Monthly

    /// Fires once per month on the specified day-of-month at the specified hour and minute.
    ///
    /// `day` is 1-indexed (1 = first of month, 28 = 28th of month).
    ///
    /// `logicalDate` is the **previous month's UTC first-of-month midnight** — the
    /// start of the month that just completed.  Use it to scope queries to last
    /// month's data:
    ///
    /// ```swift
    /// // Fires on the 1st at midnight UTC.
    /// // context.schedulingMetadata?.logicalDate == previous month's T00:00:00Z
    /// .monthly(day: 1, hour: 0)
    ///
    /// // Fires on the 15th at 10:30 UTC; same logicalDate convention.
    /// .monthly(day: 15, hour: 10, minute: 30)
    /// ```
    public static func monthly(
        day: Int,
        hour: Int,
        minute: Int = 0,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> SchedulePattern {
        // P1M (period default) + P{day-1}DT{hour}H{minute}M (intra-month fire time).
        // calculateMonthlyNextRunTime ignores the months component (uses offset.days + 1
        // for the calendar day), so the fire day is still `day`.  The full offset
        // crosses into the previous month before truncating to its first-of-month midnight.
        .monthly(
            offset: ISO8601Duration(months: 1, days: day - 1, hours: hour, minutes: minute),
            timezone: timezone
        )
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
        // P1Y (period default) + P{month-1}M{day-1}DT{hour}H{minute}M (within-year
        // fire time).  calculateYearlyNextRunTime ignores offset.years and uses
        // offset.months+1 / offset.days+1 for the calendar month/day, so the fire
        // date is unchanged.  The full offset crosses into the previous year before
        // the partition truncates to its start (Jan 1 T00:00:00Z).
        .yearly(
            offset: ISO8601Duration(years: 1, months: month.rawValue - 1, days: day - 1, hours: hour, minutes: minute),
            timezone: timezone
        )
    }
}
