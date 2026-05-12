import Testing

@testable import Strand

@Suite("Unit — sleepLabel duration formatting")
struct SleepLabelTests {

    // ── Milliseconds ──────────────────────────────────────────────────────

    @Test("sub-second values show raw milliseconds")
    func subSecond() {
        #expect(ManagementQueries.sleepLabel(durationMs: 0) == "0ms")
        #expect(ManagementQueries.sleepLabel(durationMs: 1) == "1ms")
        #expect(ManagementQueries.sleepLabel(durationMs: 500) == "500ms")
        #expect(ManagementQueries.sleepLabel(durationMs: 999) == "999ms")
    }

    // ── Seconds ───────────────────────────────────────────────────────────

    @Test("whole seconds show as Xs")
    func wholeSeconds() {
        #expect(ManagementQueries.sleepLabel(durationMs: 1_000) == "1s")
        #expect(ManagementQueries.sleepLabel(durationMs: 30_000) == "30s")
        #expect(ManagementQueries.sleepLabel(durationMs: 59_000) == "59s")
    }

    @Test("sub-minute values with leftover ms truncate to whole seconds")
    func subMinuteTruncation() {
        // 29_991 ms → 29 s (integer division — mirrors the JS fmtDuration behaviour)
        #expect(ManagementQueries.sleepLabel(durationMs: 29_991) == "29s")
        #expect(ManagementQueries.sleepLabel(durationMs: 1_999) == "1s")
    }

    // ── Minutes ───────────────────────────────────────────────────────────

    @Test("whole minutes show as Xm")
    func wholeMinutes() {
        #expect(ManagementQueries.sleepLabel(durationMs: 60_000) == "1m")
        #expect(ManagementQueries.sleepLabel(durationMs: 300_000) == "5m")
    }

    @Test("minutes with remainder seconds show as Xm Ys")
    func minutesAndSeconds() {
        #expect(ManagementQueries.sleepLabel(durationMs: 90_000) == "1m 30s")
        #expect(ManagementQueries.sleepLabel(durationMs: 3_599_000) == "59m 59s")
    }

    // ── Hours ─────────────────────────────────────────────────────────────

    @Test("whole hours show as Xh")
    func wholeHours() {
        #expect(ManagementQueries.sleepLabel(durationMs: 3_600_000) == "1h")
        #expect(ManagementQueries.sleepLabel(durationMs: 7_200_000) == "2h")
        #expect(ManagementQueries.sleepLabel(durationMs: 23 * 3_600_000) == "23h")
    }

    @Test("hours with remainder minutes show as Xh Ym")
    func hoursAndMinutes() {
        #expect(ManagementQueries.sleepLabel(durationMs: 5_400_000) == "1h 30m")
        #expect(ManagementQueries.sleepLabel(durationMs: 86_399_000) == "23h 59m")
    }

    // ── Days ──────────────────────────────────────────────────────────────

    @Test("whole days show as Xd")
    func wholeDays() {
        #expect(ManagementQueries.sleepLabel(durationMs: 86_400_000) == "1d")
        #expect(ManagementQueries.sleepLabel(durationMs: 7 * 86_400_000) == "7d")
        #expect(ManagementQueries.sleepLabel(durationMs: 365 * 86_400_000) == "365d")
    }

    @Test("days with remainder hours show as Xd Yh")
    func daysAndHours() {
        #expect(ManagementQueries.sleepLabel(durationMs: 90_000_000) == "1d 1h")
        #expect(ManagementQueries.sleepLabel(durationMs: 604_800_000 + 3_600_000) == "7d 1h")
    }
}
