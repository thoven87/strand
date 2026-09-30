#if canImport(FoundationEssentials)
public import FoundationEssentials
import Foundation  // CharacterSet (trimmingCharacters) not in FoundationEssentials on Linux
#else
public import Foundation
#endif

// MARK: - Partition Offset Support

/// ISO 8601 Duration parser for partition offsets
/// Supports durations like: P1D, PT1H, P1DT2H, PT30M, P1Y2M3DT4H5M6S
public struct ISO8601Duration: Codable, Sendable, Equatable, Hashable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let years: Int
    public let months: Int
    public let days: Int
    public let hours: Int
    public let minutes: Int
    public let seconds: Int

    public init(
        years: Int = 0,
        months: Int = 0,
        days: Int = 0,
        hours: Int = 0,
        minutes: Int = 0,
        seconds: Int = 0
    ) {
        self.years = years
        self.months = months
        self.days = days
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
    }

    /// Parses an ISO 8601 duration string (e.g. `"P1DT2H"`, `"PT1H"`, `"P1D"`).
    ///
    /// Use this for **runtime-provided** strings (user input, config files, DB values).
    /// For compile-time string literals use `ExpressibleByStringLiteral` coercion:
    ///
    /// ```swift
    /// // Runtime string — throws on invalid input:
    /// let d = try ISO8601Duration(parsing: userInput)
    ///
    /// // Compile-time literal — traps on invalid input (acceptable for constants):
    /// let offset: ISO8601Duration = "P1DT2H"
    /// ```
    public init(parsing string: String) throws {
        let duration = try Self.parse(string)
        self.years = duration.years
        self.months = duration.months
        self.days = duration.days
        self.hours = duration.hours
        self.minutes = duration.minutes
        self.seconds = duration.seconds
    }

    /// Parse ISO 8601 duration string into components
    private static func parse(_ string: String) throws -> ISO8601Duration {
        let input = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Must start with P
        guard input.hasPrefix("P") else {
            throw PartitionOffsetError.invalidDuration("Duration must start with 'P': \(string)")
        }

        var years = 0
        var months = 0
        var days = 0
        var hours = 0
        var minutes = 0
        var seconds = 0
        var currentNumber = ""
        var inTimePart = false

        for char in input.dropFirst() {  // Skip the 'P'
            if char.isNumber {
                currentNumber += String(char)
            } else if char == "T" {
                inTimePart = true
                if !currentNumber.isEmpty {
                    throw PartitionOffsetError.invalidDuration(
                        "Unexpected number before T: \(string)"
                    )
                }
            } else {
                guard !currentNumber.isEmpty else {
                    throw PartitionOffsetError.invalidDuration(
                        "Missing number before unit '\(char)': \(string)"
                    )
                }

                guard let value = Int(currentNumber) else {
                    throw PartitionOffsetError.invalidDuration(
                        "Invalid number '\(currentNumber)': \(string)"
                    )
                }

                switch char {
                case "Y":
                    guard !inTimePart else {
                        throw PartitionOffsetError.invalidDuration(
                            "Years cannot be in time part: \(string)"
                        )
                    }
                    years = value
                case "M":
                    if inTimePart {
                        minutes = value
                    } else {
                        months = value
                    }
                case "D":
                    guard !inTimePart else {
                        throw PartitionOffsetError.invalidDuration(
                            "Days cannot be in time part: \(string)"
                        )
                    }
                    days = value
                case "H":
                    guard inTimePart else {
                        throw PartitionOffsetError.invalidDuration(
                            "Hours must be in time part after T: \(string)"
                        )
                    }
                    hours = value
                case "S":
                    guard inTimePart else {
                        throw PartitionOffsetError.invalidDuration(
                            "Seconds must be in time part after T: \(string)"
                        )
                    }
                    seconds = value
                default:
                    throw PartitionOffsetError.invalidDuration("Unknown unit '\(char)': \(string)")
                }

                currentNumber = ""
            }
        }

        // Check for leftover number
        if !currentNumber.isEmpty {
            throw PartitionOffsetError.invalidDuration(
                "Incomplete duration, missing unit: \(string)"
            )
        }

        return ISO8601Duration(
            years: years,
            months: months,
            days: days,
            hours: hours,
            minutes: minutes,
            seconds: seconds
        )
    }

    /// Convert to TimeInterval approximation (useful for simple offsets)
    public var timeInterval: TimeInterval {
        TimeInterval(
            years * 365 * 24 * 3600 + months * 30 * 24 * 3600 + days * 24 * 3600 + hours * 3600
                + minutes * 60 + seconds
        )
    }

    /// Apply duration offset to a date using Calendar for accurate date arithmetic
    public func apply(to date: Date, calendar: Calendar = Self.utcGregorian) -> Date {
        var components = DateComponents()
        components.year = years
        components.month = months
        components.day = days
        components.hour = hours
        components.minute = minutes
        components.second = seconds

        return calendar.date(byAdding: components, to: date) ?? date
    }

    /// Subtract duration from a date using Calendar for accurate date arithmetic
    public func subtract(from date: Date, calendar: Calendar = Self.utcGregorian) -> Date {
        var components = DateComponents()
        components.year = -years
        components.month = -months
        components.day = -days
        components.hour = -hours
        components.minute = -minutes
        components.second = -seconds

        return calendar.date(byAdding: components, to: date) ?? date
    }

    // MARK: - CustomStringConvertible

    /// ISO 8601 representation (e.g. `"P1DT2H"`, `"PT30M"`).
    /// Zero duration serialises as `"P0D"`.
    public var description: String {
        var parts: [String] = []

        if years > 0 { parts.append("\(years)Y") }
        if months > 0 { parts.append("\(months)M") }
        if days > 0 { parts.append("\(days)D") }

        var timeParts: [String] = []
        if hours > 0 { timeParts.append("\(hours)H") }
        if minutes > 0 { timeParts.append("\(minutes)M") }
        if seconds > 0 { timeParts.append("\(seconds)S") }

        var result = "P" + parts.joined()
        if !timeParts.isEmpty {
            result += "T" + timeParts.joined()
        }

        return result == "P" ? "P0D" : result
    }

    /// UTC Gregorian calendar used as the default for date arithmetic.
    /// Avoids silently inheriting the server's system timezone/locale from
    /// `Calendar(identifier: .gregorian)` when no explicit calendar is provided by the caller.
    @usableFromInline static let utcGregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // MARK: - ExpressibleByStringLiteral

    /// Initialises from a compile-time ISO 8601 string literal.
    ///
    /// Traps on invalid input — string literals are compile-time constants, so a
    /// bad value is caught immediately in development or CI, not silently in
    /// production with user data.
    ///
    /// ```swift
    /// let offset: ISO8601Duration = "P1DT2H"   // ✓
    /// let bad:    ISO8601Duration = "P1DX"     // ✗ fatal error at launch
    /// ```
    ///
    /// For runtime strings use `init(parsing:)` which throws instead.
    public init(stringLiteral value: StringLiteralType) {
        // Using `init(parsing:)` instead of `init(_ string:)` avoids the
        // overload-resolution ambiguity that caused Swift to silently pick this
        // non-throwing path even when the call site wrote `try ISO8601Duration("...")`.
        self = try! ISO8601Duration(parsing: value)  // swiftlint:disable:this force_try
    }

    // MARK: - Zero and helpers

    /// A duration of zero (identity element for `+`).
    public static let zero = ISO8601Duration()

    /// `true` when all components are 0.
    public var isZero: Bool {
        years == 0 && months == 0 && days == 0
            && hours == 0 && minutes == 0 && seconds == 0
    }

    // MARK: - Convenience factories

    public static func years(_ n: Int) -> ISO8601Duration { ISO8601Duration(years: n) }
    public static func months(_ n: Int) -> ISO8601Duration { ISO8601Duration(months: n) }
    public static func days(_ n: Int) -> ISO8601Duration { ISO8601Duration(days: n) }
    public static func hours(_ n: Int) -> ISO8601Duration { ISO8601Duration(hours: n) }
    public static func minutes(_ n: Int) -> ISO8601Duration { ISO8601Duration(minutes: n) }
    public static func seconds(_ n: Int) -> ISO8601Duration { ISO8601Duration(seconds: n) }

    // MARK: - Arithmetic

    /// Combines two durations by summing each component.
    public static func + (lhs: ISO8601Duration, rhs: ISO8601Duration) -> ISO8601Duration {
        ISO8601Duration(
            years: lhs.years + rhs.years,
            months: lhs.months + rhs.months,
            days: lhs.days + rhs.days,
            hours: lhs.hours + rhs.hours,
            minutes: lhs.minutes + rhs.minutes,
            seconds: lhs.seconds + rhs.seconds
        )
    }

    // MARK: - Common shortcuts

    public static let oneHour = ISO8601Duration(hours: 1)
    public static let oneDay = ISO8601Duration(days: 1)
    public static let oneWeek = ISO8601Duration(days: 7)
    public static let oneMonth = ISO8601Duration(months: 1)
}
