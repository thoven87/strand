#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// MARK: - Partition Offset Support

/// ISO 8601 Duration parser for partition offsets
/// Supports durations like: P1D, PT1H, P1DT2H, PT30M, P1Y2M3DT4H5M6S
public struct ISO8601Duration: Codable, Sendable, Equatable {
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

    /// Parse ISO 8601 duration string (e.g., "P1DT2H", "PT1H", "P1D")
    public init(_ string: String) throws {
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

    /// Get human-readable description
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
    /// `Calendar.current` when no explicit calendar is provided by the caller.
    @usableFromInline static let utcGregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Common duration shortcuts
    public static let oneHour = ISO8601Duration(hours: 1)
    public static let oneDay = ISO8601Duration(days: 1)
    public static let oneWeek = ISO8601Duration(days: 7)
    public static let oneMonth = ISO8601Duration(months: 1)
}
