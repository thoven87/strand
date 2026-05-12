import Foundation
import NIOCore
import Testing

@testable import Strand

@Suite("Schedule Calculator Tests")
struct ScheduleCalculatorTests {

    @Test("Calculate next execution time for intervals")
    func testIntervalScheduleNextExecution() async throws {
        let intervalSecs = 7200.0  // 2 hours
        let pattern = SchedulePattern.interval(.hours(2))

        let baseTime = Date()
        let nextExecution = try pattern.nextRunTime(after: baseTime)

        #expect(nextExecution != nil)
        #expect(nextExecution! > baseTime)

        // Next execution must land on an epoch-aligned 2-hour boundary
        // (00:00, 02:00, 04:00 … UTC) regardless of registration time.
        let remainder = nextExecution!.timeIntervalSince1970
            .truncatingRemainder(dividingBy: intervalSecs)
        #expect(
            remainder < 0.01 || remainder > intervalSecs - 0.01,
            "next execution should be at a 2h epoch boundary"
        )

        // Must be strictly after base time and at most one interval ahead.
        let timeDiff = nextExecution!.timeIntervalSince(baseTime)
        #expect(timeDiff > 0)
        #expect(timeDiff <= intervalSecs + 1)
    }

    @Test("Calculate next execution time for cron expressions")
    func testCronScheduleNextExecution() async throws {
        let pattern = SchedulePattern.cron("0 9 * * 1-5")  // 9 AM on weekdays

        // Test from a Tuesday at 8 AM
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let baseTime = utcCalendar.date(
            from: DateComponents(
                year: 2024,
                month: 3,
                day: 12,  // Tuesday
                hour: 8,
                minute: 0
            )
        )!

        let nextExecution = try pattern.nextRunTime(after: baseTime)

        #expect(nextExecution != nil)

        let nextComponents = utcCalendar.dateComponents([.hour, .weekday], from: nextExecution!)
        #expect(nextComponents.hour == 9)
        #expect(nextComponents.weekday! >= 2 && nextComponents.weekday! <= 6)  // Monday-Friday
    }

    @Test("Calculate future execution times")
    func testFutureExecutionTimes() async throws {
        let pattern = SchedulePattern.interval(.hours(1))

        let baseTime = Date()
        var futureExecutions: [Date] = []
        var currentTime = baseTime

        // Calculate next 3 execution times
        for _ in 0..<3 {
            guard let nextTime = try pattern.nextRunTime(after: currentTime) else {
                break
            }
            futureExecutions.append(nextTime)
            currentTime = nextTime
        }

        #expect(futureExecutions.count == 3)

        // Each execution should be 1 hour apart
        for i in 0..<futureExecutions.count - 1 {
            let timeDiff = futureExecutions[i + 1].timeIntervalSince(futureExecutions[i])
            #expect(abs(timeDiff - 3600) < 60)  // Within 1 minute tolerance
        }
    }

    @Test("Handle daily schedule patterns")
    func testDailySchedulePattern() async throws {
        let pattern = SchedulePattern.daily(offset: "PT9H")  // 9:00 AM daily

        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let baseTime = utcCalendar.date(
            from: DateComponents(
                year: 2024,
                month: 3,
                day: 15,
                hour: 8,
                minute: 0
            )
        )!

        let nextExecution = try pattern.nextRunTime(after: baseTime)

        #expect(nextExecution != nil)

        let components = utcCalendar.dateComponents([.hour, .minute], from: nextExecution!)
        #expect(components.hour == 9)
        #expect(components.minute == 0)
    }

    @Test("Test weekly schedule pattern")
    func testWeeklySchedulePattern() async throws {
        let pattern = SchedulePattern.weekly(offset: "PT10H")  // Weekly at 10:00 AM

        // Start from a Friday
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let baseTime = utcCalendar.date(
            from: DateComponents(
                year: 2024,
                month: 3,
                day: 15,  // Friday
                hour: 10,
                minute: 0
            )
        )!

        let nextExecution = try pattern.nextRunTime(after: baseTime)

        #expect(nextExecution != nil)

        let nextComponents = utcCalendar.dateComponents(
            [.hour, .minute, .weekday],
            from: nextExecution!
        )
        #expect(nextComponents.hour == 10)
        #expect(nextComponents.minute == 0)
    }

    @Test("Test monthly schedule pattern")
    func testMonthlySchedulePattern() async throws {
        let pattern = SchedulePattern.monthly(offset: "PT12H")  // Monthly at noon

        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let baseTime = utcCalendar.date(
            from: DateComponents(
                year: 2024,
                month: 3,
                day: 15,  // Mid-month
                hour: 10,
                minute: 0
            )
        )!

        let nextExecution = try pattern.nextRunTime(after: baseTime)

        #expect(nextExecution != nil)

        let nextComponents = utcCalendar.dateComponents(
            [.hour, .minute, .day],
            from: nextExecution!
        )
        #expect(nextComponents.hour == 12)
        #expect(nextComponents.minute == 0)
    }

    @Test("Test schedule pattern validation")
    func testSchedulePatternValidation() async throws {
        // Valid patterns should not throw when calculating next run time
        let validCron = SchedulePattern.cron("0 9 * * 1-5")
        let cronNext = try validCron.nextRunTime(after: Date())
        #expect(cronNext != nil)

        let validInterval = SchedulePattern.interval(.hours(2))
        let intervalNext = try validInterval.nextRunTime(after: Date())
        #expect(intervalNext != nil)

        let validDaily = SchedulePattern.daily(offset: "PT9H")
        let dailyNext = try validDaily.nextRunTime(after: Date())
        #expect(dailyNext != nil)

        // Test that validation passes for all basic patterns
        #expect(Bool(true))  // If we get here, validation worked
    }

    @Test("Test timezone handling")
    func testTimezoneHandling() async throws {
        let nyTimezone = TimeZone(identifier: "America/New_York")!
        let pattern = SchedulePattern.daily(offset: "PT9H", timezone: nyTimezone)

        let utcDate = Date()
        let nextExecution = try pattern.nextRunTime(after: utcDate, timezone: nyTimezone)

        #expect(nextExecution != nil)
        #expect(nextExecution! > utcDate)
    }

    // MARK: - Epoch-boundary & offset tests

    // All tests below use fixed UTC epoch times so they are fully deterministic.
    //
    // Reference: Unix epoch day-zero boundaries (1970-01-01 UTC)
    //   0 s  = 00:00   420 s = 00:07   600 s = 00:10   900 s = 00:15
    //   1800 s = 00:30  2700 s = 00:45  5400 s = 01:30  6300 s = 01:45
    //   8100 s = 02:15  9900 s = 02:45

    @Test("5-min interval snaps to epoch boundary: from 0:07 → 0:10")
    func testInterval5MinEpochBoundary() throws {
        let from = Date(timeIntervalSince1970: 420)  // 00:07:00 UTC
        let pattern = SchedulePattern.interval(.seconds(300))
        let next = try pattern.nextRunTime(after: from)
        #expect(next?.timeIntervalSince1970 == 600, "expected 00:10:00 UTC (600 s)")
    }

    @Test("15-min interval snaps to epoch boundary: from 0:07 → 0:15")
    func testInterval15MinEpochBoundary() throws {
        let from = Date(timeIntervalSince1970: 420)  // 00:07:00 UTC
        let pattern = SchedulePattern.interval(.seconds(900))
        let next = try pattern.nextRunTime(after: from)
        #expect(next?.timeIntervalSince1970 == 900, "expected 00:15:00 UTC (900 s)")
    }

    @Test("30-min interval snaps to epoch boundary: from 0:07 → 0:30")
    func testInterval30MinEpochBoundary() throws {
        let from = Date(timeIntervalSince1970: 420)  // 00:07:00 UTC
        let pattern = SchedulePattern.interval(.seconds(1800))
        let next = try pattern.nextRunTime(after: from)
        #expect(next?.timeIntervalSince1970 == 1800, "expected 00:30:00 UTC (1800 s)")
    }

    @Test("45-min interval snaps to epoch boundary: from 0:07 → 0:45")
    func testInterval45MinEpochBoundary() throws {
        let from = Date(timeIntervalSince1970: 420)  // 00:07:00 UTC
        let pattern = SchedulePattern.interval(.seconds(2700))
        let next = try pattern.nextRunTime(after: from)
        #expect(next?.timeIntervalSince1970 == 2700, "expected 00:45:00 UTC (2700 s)")
    }

    // 90-min + PT45M offset  →  slot grid: 0:45, 2:15, 3:45, 5:15 …

    @Test("90-min interval + PT45M offset: from 0:10 → first slot is 0:45 (not 2:15)")
    func testInterval90MinOffset45FromBefore() throws {
        // Bug: old code found boundary 1:30 then applied +45 min → 2:15, skipping 0:45.
        let from = Date(timeIntervalSince1970: 600)  // 00:10:00 UTC
        let pattern = SchedulePattern.interval(.seconds(5400), offset: "PT45M")
        let next = try pattern.nextRunTime(after: from)
        #expect(next?.timeIntervalSince1970 == 2700, "expected 00:45:00 UTC (2700 s)")
    }

    @Test("90-min interval + PT45M offset: from 0:45 (on the slot) → next slot is 2:15")
    func testInterval90MinOffset45FromSlot() throws {
        // From exactly the slot time, epsilon ensures we advance to the next slot.
        let from = Date(timeIntervalSince1970: 2700)  // 00:45:00 UTC
        let pattern = SchedulePattern.interval(.seconds(5400), offset: "PT45M")
        let next = try pattern.nextRunTime(after: from)
        #expect(next?.timeIntervalSince1970 == 8100, "expected 02:15:00 UTC (8100 s)")
    }

    @Test("90-min interval no offset: from 0:10 → 1:30 (unchanged by fix)")
    func testInterval90MinNoOffset() throws {
        let from = Date(timeIntervalSince1970: 600)  // 00:10:00 UTC
        let pattern = SchedulePattern.interval(.seconds(5400))
        let next = try pattern.nextRunTime(after: from)
        #expect(next?.timeIntervalSince1970 == 5400, "expected 01:30:00 UTC (5400 s)")
    }

    // 1-hour special path + PT45M offset  →  slot grid: 1:45, 2:45, 3:45 …
    // (uses the if seconds == 3600 branch, which was already correct)

    @Test("1h interval + PT45M offset: from 0:10 → 1:45")
    func testInterval1HourOffset45FromBefore() throws {
        let from = Date(timeIntervalSince1970: 600)  // 00:10:00 UTC
        let pattern = SchedulePattern.interval(.seconds(3600), offset: "PT45M")
        let next = try pattern.nextRunTime(after: from)
        #expect(next?.timeIntervalSince1970 == 6300, "expected 01:45:00 UTC (6300 s)")
    }

    @Test("1h interval + PT45M offset: from 1:45 (on the slot) → 2:45")
    func testInterval1HourOffset45FromSlot() throws {
        let from = Date(timeIntervalSince1970: 6300)  // 01:45:00 UTC
        let pattern = SchedulePattern.interval(.seconds(3600), offset: "PT45M")
        let next = try pattern.nextRunTime(after: from)
        #expect(next?.timeIntervalSince1970 == 9900, "expected 02:45:00 UTC (9900 s)")
    }

    @Test("Test partition offset calculation")
    func testPartitionOffsetCalculation() async throws {
        let pattern = SchedulePattern.daily(offset: "PT9H")  // 9 AM daily

        let executionTime = Date()
        let partitionConfig = try PartitionOffsetConfig(offset: "PT0M")  // No partition offset

        let partitionTime = try ScheduleCalculator.calculatePartitionTime(
            executionTime: executionTime,
            schedule: pattern,
            partitionOffset: partitionConfig
        )

        #expect(partitionTime <= executionTime)

        // Test with 1-day partition offset (more significant difference)
        let offsetConfig = try PartitionOffsetConfig(offset: "P1D")
        let offsetPartitionTime = try ScheduleCalculator.calculatePartitionTime(
            executionTime: executionTime,
            schedule: pattern,
            partitionOffset: offsetConfig
        )

        #expect(offsetPartitionTime != partitionTime)
        #expect(offsetPartitionTime < partitionTime)  // Should be one day earlier
    }
}
