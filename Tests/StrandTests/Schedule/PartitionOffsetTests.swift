import Foundation
import Logging
import NIOCore
import Testing

@testable import Strand

// MARK: - Database-Independent Tests

@Suite("Partition Offset Tests - Core Functionality")
struct PartitionOffsetCoreTests {

    @Test("Parse ISO8601 duration strings")
    func testISO8601DurationParsing() throws {

        // Simple durations
        let oneHour = try ISO8601Duration("PT1H")
        #expect(oneHour.hours == 1 && oneHour.minutes == 0)

        let oneDay = try ISO8601Duration("P1D")
        #expect(oneDay.days == 1 && oneDay.hours == 0)

        // Complex durations
        let complex = try ISO8601Duration("P1DT2H30M")
        #expect(complex.days == 1)
        #expect(complex.hours == 2)
        #expect(complex.minutes == 30)

        // Month and year durations
        let monthly = try ISO8601Duration("P1M")
        #expect(monthly.months == 1)

        let yearly = try ISO8601Duration("P1Y2M3DT4H5M6S")
        #expect(yearly.years == 1)
        #expect(yearly.months == 2)
        #expect(yearly.days == 3)
        #expect(yearly.hours == 4)
        #expect(yearly.minutes == 5)
        #expect(yearly.seconds == 6)
    }

    @Test("Handle invalid ISO8601 duration strings")
    func testInvalidISO8601DurationParsing() throws {

        #expect(throws: PartitionOffsetError.self) {
            try ISO8601Duration("invalid")
        }

        #expect(throws: PartitionOffsetError.self) {
            try ISO8601Duration("1DT2H")  // Missing P prefix
        }

        #expect(throws: PartitionOffsetError.self) {
            try ISO8601Duration("PT1")  // Missing unit after number
        }

        #expect(throws: PartitionOffsetError.self) {
            try ISO8601Duration("P1XT2H")  // Invalid unit
        }
    }

    @Test("Apply duration to date with calendar arithmetic")
    func testDurationApplicationWithCalendar() async throws {
        let baseDate = try #require(
            Calendar.current.date(
                from: DateComponents(
                    timeZone: TimeZone(identifier: "UTC"),
                    year: 2024,
                    month: 2,
                    day: 15,
                    hour: 10,
                    minute: 30
                )
            )
        )

        // Test adding duration
        let duration = ISO8601Duration(days: 15, hours: 6, minutes: 30)

        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let resultDate = duration.apply(to: baseDate, calendar: calendar)

        let expectedDate = try #require(
            calendar.date(
                from: DateComponents(
                    timeZone: TimeZone(identifier: "UTC"),
                    year: 2024,
                    month: 3,
                    day: 1,
                    hour: 17,
                    minute: 0
                )
            )
        )

        #expect(resultDate == expectedDate)
    }

    @Test("Subtract duration from date with calendar arithmetic")
    func testDurationSubtractionWithCalendar() async throws {
        let baseDate = try #require(
            Calendar.current.date(
                from: DateComponents(
                    timeZone: TimeZone(identifier: "UTC"),
                    year: 2024,
                    month: 3,
                    day: 15,
                    hour: 14,
                    minute: 30
                )
            )
        )

        // Test subtracting duration
        let duration = ISO8601Duration(days: 1, hours: 2)

        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let resultDate = duration.subtract(from: baseDate, calendar: calendar)

        let expectedDate = try #require(
            calendar.date(
                from: DateComponents(
                    timeZone: TimeZone(identifier: "UTC"),
                    year: 2024,
                    month: 3,
                    day: 14,
                    hour: 12,
                    minute: 30
                )
            )
        )

        #expect(resultDate == expectedDate)
    }

    @Test("Test partition offset config encoding and decoding")
    func testPartitionOffsetConfigCodable() throws {
        let originalConfig = PartitionOffsetConfig(
            offset: ISO8601Duration(days: 1, hours: 2, minutes: 30),
            useDefaultOffsets: true,
            timezone: TimeZone(identifier: "America/Los_Angeles")!
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(originalConfig)

        // Decode from JSON
        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(PartitionOffsetConfig.self, from: jsonData)

        // Verify all properties are preserved
        #expect(decodedConfig.offset == originalConfig.offset)
        #expect(decodedConfig.useDefaultOffsets == originalConfig.useDefaultOffsets)
        #expect(decodedConfig.timezone.identifier == originalConfig.timezone.identifier)
    }

    @Test("Test edge cases and boundary conditions")
    func testEdgeCasesAndBoundaryConditions() async throws {
        // Test leap year calculations
        let leapYearDate = try #require(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(
                    timeZone: TimeZone(identifier: "UTC"),
                    year: 2024,
                    month: 2,
                    day: 29,
                    hour: 12,
                    minute: 0
                )
            )
        )

        let yearDuration = ISO8601Duration(years: 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let nextYear = yearDuration.apply(to: leapYearDate, calendar: calendar)

        // Should handle leap year properly (2024 -> 2025)
        let expectedNextYear = try #require(
            calendar.date(
                from: DateComponents(
                    timeZone: TimeZone(identifier: "UTC"),
                    year: 2025,
                    month: 2,
                    day: 28,  // Feb 28 since 2025 is not a leap year
                    hour: 12,
                    minute: 0
                )
            )
        )

        #expect(nextYear == expectedNextYear)

        // Test month boundary
        let endOfMonth = try #require(
            calendar.date(
                from: DateComponents(
                    timeZone: TimeZone(identifier: "UTC"),
                    year: 2024,
                    month: 1,
                    day: 31,
                    hour: 15,
                    minute: 30
                )
            )
        )

        let monthDuration = ISO8601Duration(months: 1)
        let nextMonth = monthDuration.apply(to: endOfMonth, calendar: calendar)

        // Should handle month boundaries correctly (Jan 31 -> Feb 29 in leap year)
        let expectedNextMonth = try #require(
            calendar.date(
                from: DateComponents(
                    timeZone: TimeZone(identifier: "UTC"),
                    year: 2024,
                    month: 2,
                    day: 29,
                    hour: 15,
                    minute: 30
                )
            )
        )

        #expect(nextMonth == expectedNextMonth)
    }

    @Test("Test default partition offset behavior")
    func testDefaultPartitionOffsetBehavior() async throws {
        // Test getting default offsets for well-known schedules

        let dailySchedule = SchedulePattern.daily(
            offset: "PT2H", timezone: TimeZone(identifier: "UTC")!)
        let dailyOffset = ScheduleCalculator.getDefaultPartitionOffset(for: dailySchedule)
        #expect(dailyOffset == .oneDay)

        let weeklySchedule = SchedulePattern.weekly(
            offset: "PT0H", timezone: TimeZone(identifier: "UTC")!)
        let weeklyOffset = ScheduleCalculator.getDefaultPartitionOffset(for: weeklySchedule)
        #expect(weeklyOffset == ISO8601Duration(days: 7))

        let monthlySchedule = SchedulePattern.monthly(
            offset: "PT0H", timezone: TimeZone(identifier: "UTC")!)
        let monthlyOffset = ScheduleCalculator.getDefaultPartitionOffset(for: monthlySchedule)
        #expect(monthlyOffset == .oneMonth)

        let intervalSchedule = SchedulePattern.interval(
            .hours(2),
            offset: "PT0H",
            timezone: TimeZone(identifier: "UTC")!
        )
        let intervalOffset = ScheduleCalculator.getDefaultPartitionOffset(for: intervalSchedule)
        #expect(intervalOffset == ISO8601Duration(hours: 2))
    }

    @Test("Test schedule partition offset support")
    func testSchedulePartitionOffsetSupport() async throws {
        // Test that all schedule patterns support partition offsets
        let schedules: [SchedulePattern] = [
            .daily(offset: "PT2H", timezone: TimeZone(identifier: "UTC")!),
            .weekly(offset: "PT0H", timezone: TimeZone(identifier: "UTC")!),
            .monthly(offset: "PT0H", timezone: TimeZone(identifier: "UTC")!),
            .interval(.hours(1), offset: "PT0H", timezone: TimeZone(identifier: "UTC")!),
            .cron("0 2 * * *", offset: "PT0H", timezone: TimeZone(identifier: "UTC")!),
            .once(at: Date(), offset: "PT0H", timezone: TimeZone(identifier: "UTC")!),
        ]

        for schedule in schedules {
            #expect(schedule.supportsPartitionOffset == true)
        }
    }

    @Test("Hourly job data partitioning - workflow runs at 02:00, processes 01:00 data")
    func testHourlyDataPartitioningExample() throws {
        // Example: Job workflow runs on hourly schedule 2025-07-29T01 with offset PT1H
        // Workflow will run at 2025-07-29T02, but data partition will be 2025-07-29T01

        let config = PartitionOffsetConfig(
            offset: ISO8601Duration(hours: 1),  // PT1H offset
            useDefaultOffsets: false,
            timezone: TimeZone(identifier: "UTC")!
        )

        // Execution time: 2025-07-29T02:00 (when the workflow actually runs)
        let executionTime = try #require(
            Calendar.current.date(
                from: DateComponents(
                    timeZone: TimeZone(identifier: "UTC"),
                    year: 2025,
                    month: 7,
                    day: 29,
                    hour: 2,
                    minute: 0
                )
            )
        )

        // Data partition time should be: 2025-07-29T01:00 (the data period being processed)
        let expectedPartitionTime = try #require(
            Calendar.current.date(
                from: DateComponents(
                    timeZone: TimeZone(identifier: "UTC"),
                    year: 2025,
                    month: 7,
                    day: 29,
                    hour: 1,
                    minute: 0
                )
            )
        )

        // Apply the offset: execution time - PT1H = partition time
        let partitionTime = config.offset.subtract(from: executionTime, calendar: Calendar.current)

        #expect(partitionTime == expectedPartitionTime)
    }
}
