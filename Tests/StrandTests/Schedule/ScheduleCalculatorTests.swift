import Foundation
import NIOCore
import Testing

@testable import Strand

@Suite("Schedule Calculator Tests")
struct ScheduleCalculatorTests {

    @Test("Calculate next execution time for intervals")
    func testIntervalScheduleNextExecution() async throws {
        let pattern = SchedulePattern.interval(.hours(2))

        let baseTime = Date()
        let nextExecution = try pattern.nextRunTime(after: baseTime)

        #expect(nextExecution != nil)
        #expect(nextExecution! > baseTime)

        // Should be approximately 2 hours from now
        let timeDiff = nextExecution!.timeIntervalSince(baseTime)
        #expect(abs(timeDiff - 7200) < 60)  // Within 1 minute tolerance
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
            [.hour, .minute, .weekday], from: nextExecution!)
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
            [.hour, .minute, .day], from: nextExecution!)
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
