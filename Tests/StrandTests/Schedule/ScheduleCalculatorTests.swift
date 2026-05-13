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

    // MARK: - DST transition tests for N-day intervals
    //
    // N-day intervals must fire at the same wall-clock time regardless of DST transitions.
    // Raw UTC-second arithmetic (seconds + N×86400) drifts by one hour:
    //
    //   Fall-back  (Nov 3, 2024 US): 7-day UTC gap = 25 h → naive next = 23:00 EST  (wrong)
    //   Spring-forward (Mar 9, 2025 US): 7-day UTC gap = 23 h → naive next = 01:00 EDT (wrong)
    //
    // calendar.date(byAdding: .day, …) advances by calendar days in the timezone so
    // the wall-clock time stays stable across both transitions.

    /// Convenience: build a `Date` at midnight on `year-month-day` in `timeZone`.
    private func midnight(
        year: Int,
        month: Int,
        day: Int,
        timeZone: TimeZone
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: 0,
                minute: 0,
                second: 0
            )
        )!
    }

    @Test("7-day interval: fall-back (2024-11-03 America/New_York) fires at local midnight, not 23:00")
    func intervalSevenDayFallBack() throws {
        let tz = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        // Fire from Sunday Oct 27 00:00 EDT (UTC-4) = Oct 27 04:00 UTC.
        let oct27 = midnight(year: 2024, month: 10, day: 27, timeZone: tz)

        let pattern = SchedulePattern.interval(.seconds(86400 * 7), timezone: tz)
        let next = try #require(try pattern.nextRunTime(after: oct27))

        // Expected: Nov 3 00:00 EST (UTC-5) = Nov 3 05:00 UTC.
        // Raw arithmetic would give Nov 3 04:00 UTC = Nov 2 23:00 EST (one hour early).
        let nov3 = midnight(year: 2024, month: 11, day: 3, timeZone: tz)
        #expect(next == nov3)

        // Verify in components so the failure message is human-readable.
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        #expect(c.year == 2024)
        #expect(c.month == 11)
        #expect(c.day == 3)
        #expect(c.hour == 0)
        #expect(c.minute == 0)
    }

    @Test("7-day interval: spring-forward (2025-03-09 America/New_York) fires at local midnight, not 01:00")
    func intervalSevenDaySpringForward() throws {
        let tz = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        // Fire from Sunday Mar 2 00:00 EST (UTC-5) = Mar 2 05:00 UTC.
        let mar2 = midnight(year: 2025, month: 3, day: 2, timeZone: tz)

        let pattern = SchedulePattern.interval(.seconds(86400 * 7), timezone: tz)
        let next = try #require(try pattern.nextRunTime(after: mar2))

        // Expected: Mar 9 00:00 EDT (UTC-4) = Mar 9 04:00 UTC.
        // Raw arithmetic would give Mar 9 05:00 UTC = Mar 9 01:00 EDT (one hour late).
        let mar9 = midnight(year: 2025, month: 3, day: 9, timeZone: tz)
        #expect(next == mar9)

        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        #expect(c.year == 2025)
        #expect(c.month == 3)
        #expect(c.day == 9)
        #expect(c.hour == 0)
        #expect(c.minute == 0)
    }

    @Test("1-day interval: fall-back regression — stays at local midnight after fix")
    func intervalOneDayFallBack() throws {
        let tz = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        let nov2 = midnight(year: 2024, month: 11, day: 2, timeZone: tz)
        let pattern = SchedulePattern.interval(.seconds(86400), timezone: tz)
        let next = try #require(try pattern.nextRunTime(after: nov2))

        let nov3 = midnight(year: 2024, month: 11, day: 3, timeZone: tz)
        #expect(next == nov3)

        // Nov 3 midnight EST = 05:00 UTC, not 04:00 UTC (which would be Nov 2 23:00 EST).
        let c = cal.dateComponents([.day, .hour], from: next)
        #expect(c.day == 3)
        #expect(c.hour == 0)
    }

    @Test("14-day interval: two-week cadence stays at local midnight across DST")
    func intervalFourteenDayAcrossDST() throws {
        let tz = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        // Oct 26, 2024 (two weeks before Nov 9 — safely past the Nov 3 fall-back)
        let oct26 = midnight(year: 2024, month: 10, day: 26, timeZone: tz)
        let pattern = SchedulePattern.interval(.seconds(86400 * 14), timezone: tz)
        let next = try #require(try pattern.nextRunTime(after: oct26))

        // Nov 9 00:00 EST (UTC-5) = Nov 9 05:00 UTC.
        let nov9 = midnight(year: 2024, month: 11, day: 9, timeZone: tz)
        #expect(next == nov9)

        let c = cal.dateComponents([.day, .hour], from: next)
        #expect(c.day == 9)
        #expect(c.hour == 0)
    }
}
