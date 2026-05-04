import DequeModule

#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

/// High-performance Cron expression parser and evaluator
public struct CronExpression: Sendable, CustomStringConvertible, Codable {
    public let expression: String

    // Parsed components for fast evaluation
    internal let minute: CronField
    internal let hour: CronField
    internal let dayOfMonth: CronField
    internal let month: CronField
    internal let dayOfWeek: CronField
    internal let year: CronField?

    // MARK: - Codable Implementation

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let expressionString = try container.decode(String.self)
        try self.init(expressionString)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(expression)
    }

    public init(_ expression: String) throws {
        let trimmedExpression = expression.trimmingCharacters(in: .whitespaces)
        self.expression = trimmedExpression

        // Parse cron expression directly using Swift 6.1 pure concurrency
        let parsed = try Self.parseCronExpression(trimmedExpression)

        self.minute = parsed.minute
        self.hour = parsed.hour
        self.dayOfMonth = parsed.dayOfMonth
        self.month = parsed.month
        self.dayOfWeek = parsed.dayOfWeek
        self.year = parsed.year
    }

    public var description: String {
        expression
    }

    /// Calculate the next run time after the given date
    public func nextRunTime(after date: Date, in timeZone: TimeZone = TimeZone(identifier: "UTC")!)
        throws -> Date?
    {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        // Sorted concrete values; nil element means "wildcard – don't constrain this component"
        let minuteVals: [Int?] =
            minute.isWildcard ? [nil] : minute.values.sorted().map(Optional.init)
        let hourVals: [Int?] = hour.isWildcard ? [nil] : hour.values.sorted().map(Optional.init)
        let monthVals: [Int?] = month.isWildcard ? [nil] : month.values.sorted().map(Optional.init)

        var best: Date? = nil

        func consider(_ d: Date?) {
            guard let d else { return }
            if let b = best { if d < b { best = d } } else { best = d }
        }

        /// Build DateComponents from the candidate values and fire `calendar.nextDate`.
        func tryComponents(m: Int?, h: Int?, mo: Int?, day: Int?, weekday: Int?) {
            var comps = DateComponents()
            comps.second = 0
            comps.minute = m
            comps.hour = h
            comps.month = mo
            comps.day = day
            comps.weekday = weekday
            consider(cal.nextDate(after: date, matching: comps, matchingPolicy: .nextTime))
        }

        // day/weekday candidate sets (only populated when the field is NOT wildcard)
        let domVals: [Int] = dayOfMonth.isWildcard ? [] : dayOfMonth.values.sorted()
        let dowCalVals: [Int] =
            dayOfWeek.isWildcard
            ? []
            : dayOfWeek.values.sorted().map {
                $0 == 0 ? 1 : $0 + 1  // cron 0=Sun → Calendar 1=Sun; cron 6=Sat → Calendar 7
            }

        for m in minuteVals {
            for h in hourVals {
                for mo in monthVals {
                    if dayOfMonth.isWildcard && dayOfWeek.isWildcard {
                        // No day constraint at all
                        tryComponents(m: m, h: h, mo: mo, day: nil, weekday: nil)
                    } else {
                        for d in domVals {
                            tryComponents(m: m, h: h, mo: mo, day: d, weekday: nil)
                        }
                        for w in dowCalVals {
                            tryComponents(m: m, h: h, mo: mo, day: nil, weekday: w)
                        }
                    }
                }
            }
        }

        // Honour optional year field (6-field cron): if result year doesn't match, iterate years
        if let yearField = year, let candidate = best {
            let resultYear = cal.component(.year, from: candidate)
            if !yearField.matches(resultYear) {
                // Advance to the first January 1 of a valid year and recurse (bounded to 10 years)
                let sortedYears = yearField.values.filter { $0 > resultYear }.sorted()
                for yr in sortedYears.prefix(10) {
                    var ycomps = DateComponents()
                    ycomps.year = yr
                    ycomps.month = 1
                    ycomps.day = 1
                    ycomps.hour = 0
                    ycomps.minute = 0
                    ycomps.second = 0
                    guard let startOfYear = cal.date(from: ycomps) else { continue }
                    // Find first matching slot in that year; we already know the year is valid
                    let searchFrom = cal.date(byAdding: .second, value: -1, to: startOfYear)!
                    if let hit = try nextRunTime(after: searchFrom, in: timeZone) {
                        if cal.component(.year, from: hit) == yr { return hit }
                    }
                }
                return nil
            }
        }

        return best
    }

    /// Find the next valid value in a cron field
    internal func findNextValue(current: Int, in field: CronField) -> Int? {
        field.nextValue(after: current - 1)
    }

    /// Check if the current date matches the cron expression
    public func matches(_ date: Date, in timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> Bool
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .weekday], from: date)

        guard let year = components.year,
            let month = components.month,
            let day = components.day,
            let hour = components.hour,
            let minute = components.minute,
            let weekday = components.weekday
        else {
            return false
        }

        return self.minute.matches(minute) && self.hour.matches(hour) && self.month.matches(month)
            && (self.year?.matches(year) ?? true)
            && matchesDayFields(day: day, weekday: weekday, month: month, year: year)
    }

    /// Handle the special logic for day of month vs day of week
    internal func matchesDayFields(day: Int, weekday: Int, month: Int, year: Int) -> Bool {
        let dayOfMonthMatches = dayOfMonth.matches(day)
        // Convert Foundation weekday (1=Sunday, 2=Monday, ..., 7=Saturday)
        // to cron weekday (0=Sunday, 1=Monday, ..., 6=Saturday, 7=Sunday)
        let cronWeekday = weekday == 1 ? 0 : weekday - 1
        let dayOfWeekMatches =
            dayOfWeek.matches(cronWeekday) || (weekday == 1 && dayOfWeek.matches(7))

        // If both day fields are specified (not *), both must match (AND logic)
        // If only one is specified, only that one needs to match (OR logic)
        if dayOfMonth.isWildcard && dayOfWeek.isWildcard {
            return true
        } else if dayOfMonth.isWildcard {
            return dayOfWeekMatches
        } else if dayOfWeek.isWildcard {
            return dayOfMonthMatches
        } else {
            // When both are specified, use OR logic (standard cron behavior)
            return dayOfMonthMatches || dayOfWeekMatches
        }
    }

    // MARK: - Parsing Implementation

    fileprivate struct ParsedCron {
        let minute: CronField
        let hour: CronField
        let dayOfMonth: CronField
        let month: CronField
        let dayOfWeek: CronField
        let year: CronField?
    }

    private static func parseCronExpression(_ expression: String) throws -> ParsedCron {
        let fields = expression.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        // Support both 5-field and 6-field cron expressions
        guard fields.count == 5 || fields.count == 6 else {
            throw CronParseError.invalidFieldCount(fields.count)
        }

        let minute = try CronField.parse(fields[0], range: 0...59, fieldName: "minute")
        let hour = try CronField.parse(fields[1], range: 0...23, fieldName: "hour")
        let dayOfMonth = try CronField.parse(fields[2], range: 1...31, fieldName: "day")
        let month = try CronField.parse(fields[3], range: 1...12, fieldName: "month")
        let dayOfWeek = try CronField.parse(fields[4], range: 0...7, fieldName: "weekday")  // 0 and 7 = Sunday
        let year =
            fields.count == 6
            ? try CronField.parse(fields[5], range: 1970...3000, fieldName: "year") : nil

        return ParsedCron(
            minute: minute,
            hour: hour,
            dayOfMonth: dayOfMonth,
            month: month,
            dayOfWeek: dayOfWeek,
            year: year
        )
    }
}

/// Represents a parsed cron field with optimized matching
internal struct CronField: Sendable {
    internal let values: Set<Int>
    let isWildcard: Bool

    private init(values: Set<Int>, isWildcard: Bool = false) {
        self.values = values
        self.isWildcard = isWildcard
    }

    internal func matches(_ value: Int) -> Bool {
        values.contains(value)
    }

    internal func nextValue(after value: Int) -> Int? {
        values.filter { $0 > value }.min()
    }

    internal var valueCount: Int {
        values.count
    }

    internal static func parse(_ field: String, range: ClosedRange<Int>, fieldName: String) throws
        -> CronField
    {
        let trimmed = field.trimmingCharacters(in: .whitespaces)

        // Handle wildcard
        if trimmed == "*" {
            return CronField(values: Set(range), isWildcard: true)
        }

        var values = Set<Int>()

        // Split by commas for multiple values
        let parts = trimmed.components(separatedBy: ",")

        for part in parts {
            let cleanPart = part.trimmingCharacters(in: .whitespaces)
            try values.formUnion(parseFieldPart(cleanPart, range: range, fieldName: fieldName))
        }

        return CronField(values: values)
    }

    private static func parseFieldPart(_ part: String, range: ClosedRange<Int>, fieldName: String)
        throws -> Set<Int>
    {
        // Handle step values (e.g., */5, 10-20/2)
        if part.contains("/") {
            return try parseStepValue(part, range: range, fieldName: fieldName)
        }

        // Handle ranges (e.g., 10-15)
        if part.contains("-") {
            return try parseRange(part, range: range, fieldName: fieldName)
        }

        // Handle single value
        guard let value = Int(part) else {
            throw CronParseError.invalidValue(part, fieldName)
        }

        // Special handling for day of week (0 and 7 both mean Sunday)
        let normalizedValue = fieldName == "weekday" && value == 7 ? 0 : value

        guard range.contains(normalizedValue) else {
            throw CronParseError.valueOutOfRange(value, range, fieldName)
        }

        return Set([normalizedValue])
    }

    private static func parseRange(_ part: String, range: ClosedRange<Int>, fieldName: String)
        throws -> Set<Int>
    {
        let components = part.components(separatedBy: "-")
        guard components.count == 2 else {
            throw CronParseError.invalidRange(part, fieldName)
        }

        guard let startValue = Int(components[0].trimmingCharacters(in: .whitespaces)),
            let endValue = Int(components[1].trimmingCharacters(in: .whitespaces))
        else {
            throw CronParseError.invalidRange(part, fieldName)
        }

        // Special handling for day of week (7 = Sunday = 0)
        let start = fieldName == "weekday" && startValue == 7 ? 0 : startValue
        let end = fieldName == "weekday" && endValue == 7 ? 0 : endValue

        guard range.contains(start) && range.contains(end) else {
            throw CronParseError.rangeOutOfBounds(start...end, range, fieldName)
        }

        guard start <= end else {
            throw CronParseError.invalidRange(part, fieldName)
        }

        return Set(start...end)
    }

    private static func parseStepValue(_ part: String, range: ClosedRange<Int>, fieldName: String)
        throws -> Set<Int>
    {
        let components = part.components(separatedBy: "/")
        guard components.count == 2 else {
            throw CronParseError.invalidStepValue(part, fieldName)
        }

        let baseRange: Set<Int>
        let baseString = components[0].trimmingCharacters(in: .whitespaces)

        if baseString == "*" {
            baseRange = Set(range)
        } else if baseString.contains("-") {
            baseRange = try parseRange(baseString, range: range, fieldName: fieldName)
        } else {
            guard let value = Int(baseString) else {
                throw CronParseError.invalidStepValue(part, fieldName)
            }
            guard range.contains(value) else {
                throw CronParseError.valueOutOfRange(value, range, fieldName)
            }
            baseRange = Set([value])
        }

        guard let step = Int(components[1].trimmingCharacters(in: .whitespaces)), step > 0 else {
            throw CronParseError.invalidStepValue(part, fieldName)
        }

        var result = Set<Int>()
        let sortedValues = baseRange.sorted()

        if let first = sortedValues.first {
            var current = first
            while current <= range.upperBound && baseRange.contains(current) {
                result.insert(current)
                current += step
            }
        }

        return result
    }
}

/// Errors that can occur during cron parsing
public enum CronParseError: Error, Sendable, LocalizedError {
    case invalidFieldCount(Int)
    case invalidValue(String, String)
    case valueOutOfRange(Int, ClosedRange<Int>, String)
    case invalidRange(String, String)
    case rangeOutOfBounds(ClosedRange<Int>, ClosedRange<Int>, String)
    case invalidStepValue(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidFieldCount(let count):
            return "Invalid cron expression: expected 5 or 6 fields, got \(count)"
        case .invalidValue(let value, let field):
            return "Invalid value '\(value)' for \(field) field"
        case .valueOutOfRange(let value, let range, let field):
            return "Value \(value) is out of range \(range) for \(field) field"
        case .invalidRange(let range, let field):
            return "Invalid range '\(range)' for \(field) field"
        case .rangeOutOfBounds(let range, let validRange, let field):
            return "Range \(range) is outside valid range \(validRange) for \(field) field"
        case .invalidStepValue(let step, let field):
            return "Invalid step value '\(step)' for \(field) field"
        }
    }
}

/// Common cron expression patterns
// These string literals are statically verified by their own unit tests and
// will never change — `try!` is safe because parsing cannot fail for known-good
// expressions. A crash here would be a compile-time regression, not a runtime one.
extension CronExpression {
    /// Every minute: "* * * * *"
    public static let everyMinute = try! CronExpression("* * * * *")

    /// Every hour: "0 * * * *"
    public static let hourly = try! CronExpression("0 * * * *")

    /// Daily at midnight: "0 0 * * *"
    public static let daily = try! CronExpression("0 0 * * *")

    /// Weekly on Sunday at midnight: "0 0 * * 0"
    public static let weekly = try! CronExpression("0 0 * * 0")

    /// Monthly on the 1st at midnight: "0 0 1 * *"
    public static let monthly = try! CronExpression("0 0 1 * *")

    /// Yearly on January 1st at midnight: "0 0 1 1 *"
    public static let yearly = try! CronExpression("0 0 1 1 *")

    /// Every 15 minutes: "*/15 * * * *"
    public static let every15Minutes = try! CronExpression("*/15 * * * *")

    /// Every 30 minutes: "*/30 * * * *"
    public static let every30Minutes = try! CronExpression("*/30 * * * *")

    /// Every weekday at 9 AM: "0 9 * * 1-5"
    public static let weekdaysAt9AM = try! CronExpression("0 9 * * 1-5")

    /// Every weekend at 10 AM: "0 10 * * 0,6"
    public static let weekendsAt10AM = try! CronExpression("0 10 * * 0,6")
}

/// Factory methods for common patterns
extension CronExpression {
    /// Create a cron expression for specific time daily
    public static func daily(hour: Int, minute: Int = 0) throws -> CronExpression {
        guard (0...23).contains(hour) && (0...59).contains(minute) else {
            throw CronParseError.valueOutOfRange(
                hour < 0 || hour > 23 ? hour : minute,
                hour < 0 || hour > 23 ? 0...23 : 0...59,
                hour < 0 || hour > 23 ? "hour" : "minute"
            )
        }
        return try CronExpression("\(minute) \(hour) * * *")
    }

    /// Create a cron expression for specific time on specific weekdays
    public static func weekdays(_ days: [Int], hour: Int, minute: Int = 0) throws -> CronExpression
    {
        let validDays = days.filter { (0...7).contains($0) }
        guard validDays.count == days.count else {
            throw CronParseError.valueOutOfRange(-1, 0...7, "weekday")
        }

        let dayString = validDays.map(String.init).joined(separator: ",")
        return try CronExpression("\(minute) \(hour) * * \(dayString)")
    }

    /// Create a cron expression for every N minutes
    public static func everyMinutes(_ minutes: Int) throws -> CronExpression {
        guard minutes > 0 && minutes <= 59 else {
            throw CronParseError.valueOutOfRange(minutes, 1...59, "minute")
        }
        return try CronExpression("*/\(minutes) * * * *")
    }

    /// Create a cron expression for every N hours
    public static func everyHours(_ hours: Int) throws -> CronExpression {
        guard hours > 0 && hours <= 23 else {
            throw CronParseError.valueOutOfRange(hours, 1...23, "hour")
        }
        return try CronExpression("0 */\(hours) * * *")
    }
}

/// Performance utilities
extension CronExpression {
    /// Calculate multiple future run times efficiently
    public func nextRunTimes(after date: Date, count: Int) throws -> [Date] {
        var results: [Date] = []
        var currentDate = date

        for _ in 0..<count {
            guard let nextDate = try nextRunTime(after: currentDate) else {
                break
            }
            results.append(nextDate)
            currentDate = nextDate
        }

        return results
    }

    /// Check if cron expression will execute within a time range
    public func willExecute(between start: Date, and end: Date) throws -> Bool {
        guard let nextRun = try nextRunTime(after: start) else {
            return false
        }
        return nextRun <= end
    }

    /// Get the previous run time before a given date
    public func previousRunTime(before date: Date) throws -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return try previousRunTimeBySearching(before: date, calendar: cal)
    }

    /// Returns the last `n` run times before `date` in chronological order (oldest first).
    ///
    /// Uses a `Deque<Date>` as a fixed-capacity sliding window so front-removal
    /// is O(1) instead of the O(n) cost of `Array.removeFirst()`.
    /// This powers ``ScheduleAccuracy/last(_:)`` catch-up without loading the
    /// entire history into memory — only `n + 1` entries are ever resident.
    internal func lastNRunTimes(
        before date: Date,
        n: Int,
        in timeZone: TimeZone = TimeZone(identifier: "UTC")!
    ) throws -> Deque<Date> {
        precondition(n > 0, "n must be positive")
        var window = Deque<Date>(minimumCapacity: n + 1)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let lo = cal.date(byAdding: .day, value: -366, to: date) ?? date
        var cur = lo
        while let next = try nextRunTime(after: cur, in: timeZone) {
            if next >= date { break }
            window.append(next)  // O(1) append to back
            if window.count > n { window.removeFirst() }  // O(1) evict from front
            cur = next
        }
        return window
    }

    /// Search backwards up to 366 days, walking forward with `nextRunTime` to find the last match.
    private func previousRunTimeBySearching(before date: Date, calendar: Calendar) throws -> Date? {
        // Search back up to 366 days — sufficient for any standard cron expression.
        let cal = calendar  // already UTC Gregorian
        let lo = cal.date(byAdding: .day, value: -366, to: date) ?? date
        var result: Date? = nil
        var cur = lo
        while let next = try? nextRunTime(after: cur, in: cal.timeZone) {
            if next >= date { break }
            result = next
            cur = next
        }
        return result
    }

    private func previousRunTimeByMinutes(before date: Date, calendar: Calendar) throws -> Date? {
        try previousRunTimeBySearching(before: date, calendar: calendar)
    }

    private func previousRunTimeByDays(before date: Date, calendar: Calendar) throws -> Date? {
        try previousRunTimeBySearching(before: date, calendar: calendar)
    }
}
