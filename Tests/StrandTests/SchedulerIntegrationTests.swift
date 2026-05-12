import Logging
import NIOCore
import PostgresNIO
import Testing

@testable import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Workflow fixture
//
// Simple no-op workflow used by all scheduler tests.
// Completes in a single activation so any fired task reaches COMPLETED quickly.

private struct SitSimpleWorkflow: Workflow {
    typealias Input = StrandVoid
    typealias Output = StrandVoid

    mutating func run(
        context: WorkflowContext<Self>,
        input: StrandVoid
    ) async throws -> StrandVoid {
        .done
    }
}

// MARK: - Test suite

@Suite("Integration — Scheduler", .tags(.integration), .serialized)
struct SchedulerIntegrationTests {

    // ── 1 ───────────────────────────────────────────────────────────────────
    //
    // End-to-end test that a `StrandScheduler` actually fires a registered
    // schedule and the fired task is processed by a worker within 5 seconds.
    //
    // Setup:
    //  - Register a schedule with `.interval(.seconds(1))`.
    //  - Start the scheduler with `sleepCap: .seconds(1)` — it wakes at most
    //    every 1 second, but fires exactly when `next_run_at <= now`.
    //  - Start a worker to process the triggered workflows.
    //
    // Timing:
    //  - `next_run_at` is set to ≈ now + 1 second at registration.
    //  - Scheduler wakes, finds the due schedule, fires it (enqueues a task).
    //  - Worker claims and completes the task.
    //  - `schedule.run_count` is incremented by `markScheduleFired`.
    //  - Whole cycle repeats every ~1 second; we wait at most 5 seconds for
    //    `run_count >= 1`.
    //
    @Test(
        "scheduler fires a scheduled workflow and run_count reaches 1 within 5 seconds",
        .tags(.integration)
    )
    func schedulerFiresWithinWindow() async throws {
        try await withTestEnvironment { client in
            let scheduler = StrandScheduler(
                client: client,
                options: SchedulerOptions(sleepCap: .seconds(1))
            )

            let scheduleID = try await client.schedule(
                name: "sit-fire-test",
                pattern: .interval(.seconds(1)),
                workflowType: SitSimpleWorkflow.self,
                input: .done
            )

            // Start the scheduler and a worker in the background.
            let schedulerTask = Task { try? await scheduler.run() }
            defer { schedulerTask.cancel() }

            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [SitSimpleWorkflow.self]
            )
            defer { workerTask.cancel() }

            // Poll until run_count >= 1 or the 5-second deadline expires.
            var runCount = 0
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                let summaries = try await client.listSchedules(queue: client.queueName)
                runCount =
                    summaries.first(where: { $0.name == "sit-fire-test" })?.runCount ?? 0
                if runCount >= 1 { break }
                try await Task.sleep(for: .milliseconds(200))
            }

            #expect(
                runCount >= 1,
                "scheduler should have fired the schedule at least once within 5 seconds"
            )

            // Cleanup: delete the schedule row so it does not accumulate in
            // the shared dev DB across test runs.
            try? await client.deleteSchedule(id: scheduleID)
        }
    }

    // ── 2 ───────────────────────────────────────────────────────────────────
    //
    // Verifies the "catch-up to most recent slot" behaviour described in
    // `StrandClient._schedule`.
    //
    // When `startsAt` is in the past, `_schedule` advances `next_run_at` to the
    // most recent elapsed interval boundary (the `.latest` accuracy default).
    // This means the schedule is immediately due when it is registered — the
    // scheduler fires it on its very first poll without any sleep.
    //
    // Setup:
    //  - `startsAt = now - 10 seconds`, `pattern = .interval(.seconds(5))`.
    //  - With `.latest` accuracy, `next_run_at` is advanced to the most recent
    //    5-second boundary before `registrationTime`, which is ≤ now.
    //
    // Assertions:
    //  1. The schedule row's `nextRunAt` is ≤ `registrationTime + 2s` (small
    //     margin for slow execution).
    //  2. The scheduler fires it within 5 seconds → `run_count >= 1`.
    //
    @Test(
        "schedule with startsAt in the past recovers the most recent missed slot immediately",
        .tags(.integration)
    )
    func scheduleStartsAtInPastIsImmediatelyDue() async throws {
        try await withTestEnvironment { client in
            let registrationTime = Date.now
            let startsAt = registrationTime.addingTimeInterval(-10)

            let scheduleID = try await client.schedule(
                name: "sit-paststart-test",
                pattern: .interval(.seconds(5)),
                workflowType: SitSimpleWorkflow.self,
                input: .done,
                startsAt: startsAt
            )

            // Assertion 1: nextRunAt must be at-or-before registrationTime (allow 2 s margin).
            let summaries = try await client.listSchedules(queue: client.queueName)
            let sched = summaries.first(where: { $0.name == "sit-paststart-test" })
            #expect(sched != nil, "schedule row must exist immediately after creation")
            if let s = sched {
                if let nextRunAt = s.nextRunAt {
                    #expect(
                        nextRunAt <= registrationTime.addingTimeInterval(2),
                        "nextRunAt (\(nextRunAt)) must be <= registrationTime + 2 s"
                    )
                } else {
                    Issue.record(
                        "nextRunAt is nil — schedule with a back-dated startsAt should be immediately due"
                    )
                }
            }

            // Start scheduler + worker and wait for the first fire.
            let scheduler = StrandScheduler(
                client: client,
                options: SchedulerOptions(sleepCap: .seconds(1))
            )
            let schedulerTask = Task { try? await scheduler.run() }
            defer { schedulerTask.cancel() }

            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [SitSimpleWorkflow.self]
            )
            defer { workerTask.cancel() }

            // Assertion 2: schedule fires within 5 seconds.
            var runCount = 0
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                let list = try await client.listSchedules(queue: client.queueName)
                runCount =
                    list.first(where: { $0.name == "sit-paststart-test" })?.runCount ?? 0
                if runCount >= 1 { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(
                runCount >= 1,
                "scheduler should have fired the recovered missed slot within 5 seconds"
            )

            // Cleanup.
            try? await client.deleteSchedule(id: scheduleID)
        }
    }

    // ── 3 ───────────────────────────────────────────────────────────────────────────
    //
    // `last_run_at` stores the WALL-CLOCK time `fire()` was actually called,
    // not the scheduled slot time.
    //
    // Users reading the dashboard see "Last run: 2 minutes ago" which reflects
    // when the scheduler actually did work.  The slot time lives in the separate
    // `last_slot_at` column and is used internally for catch-up arithmetic.
    //
    // We record the wall-clock time just before the scheduler fires, wait for
    // one fire, then assert `lastRunAt ≈ now` (within a generous bound to
    // absorb scheduling jitter) and that it is NOT equal to the scheduled slot
    // (which was in the past when `startsAt` is backdated).
    //
    @Test(
        "markScheduleFired stores the wall-clock fire time in last_run_at",
        .tags(.integration)
    )
    func firedAtIsWallClockNotScheduledSlot() async throws {
        try await withTestEnvironment { client in
            // Register with startsAt 5 minutes ago and a 2-minute interval.
            // accuracy .latest advances nextRunAt to the most-recent elapsed
            // 2-minute slot, which is approximately now − 60 s — clearly in the
            // past and clearly distinguishable from the wall-clock fire time.
            let scheduleID = try await client.schedule(
                name: "sit-firedat-test",
                pattern: .interval(.seconds(120)),
                workflowType: SitSimpleWorkflow.self,
                input: .done,
                startsAt: Date.now.addingTimeInterval(-300)  // 5 minutes ago
            )

            // Capture the scheduled slot (nextRunAt) — this will be ~60 s in the past.
            let preFireList = try await client.listSchedules(queue: client.queueName)
            guard
                let scheduledSlot =
                    preFireList.first(where: { $0.name == "sit-firedat-test" })?.nextRunAt
            else {
                Issue.record("schedule must have a nextRunAt after registration")
                return
            }
            let fireStarted = Date.now  // wall-clock lower bound

            // Start the scheduler.
            let scheduler = StrandScheduler(
                client: client,
                options: SchedulerOptions(sleepCap: .seconds(1))
            )
            let schedulerTask = Task { try? await scheduler.run() }
            defer { schedulerTask.cancel() }

            // Wait until the schedule has fired at least once.
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                let list = try await client.listSchedules(queue: client.queueName)
                if (list.first(where: { $0.name == "sit-firedat-test" })?.runCount ?? 0) >= 1 {
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            let fireEnded = Date.now  // wall-clock upper bound

            let postFireList = try await client.listSchedules(queue: client.queueName)
            let lastRunAt =
                postFireList.first(where: { $0.name == "sit-firedat-test" })?.lastRunAt

            #expect(lastRunAt != nil, "lastRunAt must be set after the schedule fires")
            if let lastRunAt {
                // last_run_at must be within the wall-clock window [fireStarted, fireEnded].
                #expect(
                    lastRunAt >= fireStarted.addingTimeInterval(-1),
                    "lastRunAt (\(lastRunAt)) must be ≈ now, not the scheduled slot (\(scheduledSlot))"
                )
                #expect(
                    lastRunAt <= fireEnded.addingTimeInterval(1),
                    "lastRunAt (\(lastRunAt)) must not be in the future"
                )
                // And it must NOT equal the scheduled slot (which was in the past).
                #expect(
                    abs(lastRunAt.timeIntervalSince(scheduledSlot)) > 1,
                    "lastRunAt must differ from the scheduled slot; got lastRunAt=\(lastRunAt) slot=\(scheduledSlot)"
                )
            }

            try? await client.deleteSchedule(id: scheduleID)
        }
    }

    // ── 4 ───────────────────────────────────────────────────────────────────────────
    //
    // `upsertSchedule` uses LEAST(existing, new) so that re-registration moves
    // `next_run_at` to the most-recent missed slot when the newly-computed value
    // is earlier than the DB value — healing any corruption caused by a previous
    // cold-restart that jumped `next_run_at` too far into the future.
    //
    // Test sequence:
    //  1. Register with no startsAt → next_run_at ≈ now + 3600 s (future).
    //  2. Re-register the same name with startsAt 2 h ago and accuracy .latest.
    //     Catch-up computes the most-recent elapsed 1-hour boundary, which is
    //     ≤ now — earlier than the existing future slot.
    //  3. Assert next_run_at moved to that earlier slot (immediately due).
    //  4. Re-register again with the same startsAt (second restart).
    //     The newly-computed slot is the same as step 2 — LEAST is a no-op.
    //  5. Assert next_run_at did not move further forward.
    //
    @Test(
        "upsertSchedule moves next_run_at to most-recent elapsed slot on re-registration with past startsAt",
        .tags(.integration)
    )
    func upsertMovesNextRunAtToCatchupSlotOnReregistration() async throws {
        try await withTestEnvironment { client in
            let startsAt = Date.now.addingTimeInterval(-7200)  // 2 hours ago

            // Step 1: fresh registration, no startsAt → next_run_at ≈ now + 3600s.
            let scheduleID = try await client.schedule(
                name: "sit-least-test",
                pattern: .interval(.seconds(3600)),
                workflowType: SitSimpleWorkflow.self,
                input: .done
            )
            let registrationTime = Date.now

            let initial = try await client.listSchedules(queue: client.queueName)
            guard
                let initialNextRunAt =
                    initial.first(where: { $0.name == "sit-least-test" })?.nextRunAt
            else {
                Issue.record("schedule must have nextRunAt after fresh registration")
                return
            }
            #expect(
                initialNextRunAt > registrationTime,
                "fresh registration must produce a future next_run_at"
            )

            // Step 2: re-register with startsAt 2 hours ago.
            // accuracy .latest computes the most-recently-elapsed 1-hour slot,
            // which is somewhere between (now - 3600) and now — earlier than the
            // existing initialNextRunAt.  LEAST should take the earlier value.
            _ = try await client.schedule(
                name: "sit-least-test",
                pattern: .interval(.seconds(3600)),
                workflowType: SitSimpleWorkflow.self,
                input: .done,
                startsAt: startsAt
            )
            let afterCatchup = Date.now

            // Step 3: next_run_at must now be the catch-up slot (≤ now).
            let mid = try await client.listSchedules(queue: client.queueName)
            let midNextRunAt = mid.first(where: { $0.name == "sit-least-test" })?.nextRunAt

            #expect(midNextRunAt != nil, "nextRunAt must remain set after re-registration")
            if let t = midNextRunAt {
                #expect(
                    t <= afterCatchup.addingTimeInterval(1),
                    "catch-up must move next_run_at to an immediately-due slot; got \(t)"
                )
                #expect(
                    t < initialNextRunAt,
                    "catch-up slot must be earlier than the original future slot; was \(initialNextRunAt), got \(t)"
                )
            }

            // Step 4: re-register again (simulates a second restart) — same startsAt.
            _ = try await client.schedule(
                name: "sit-least-test",
                pattern: .interval(.seconds(3600)),
                workflowType: SitSimpleWorkflow.self,
                input: .done,
                startsAt: startsAt
            )

            // Step 5: next_run_at must not have drifted further forward.
            let after = try await client.listSchedules(queue: client.queueName)
            let afterNextRunAt = after.first(where: { $0.name == "sit-least-test" })?.nextRunAt

            #expect(afterNextRunAt != nil)
            if let before = midNextRunAt, let after = afterNextRunAt {
                #expect(
                    after <= before.addingTimeInterval(1),
                    "second restart must not advance next_run_at; was \(before), got \(after)"
                )
            }

            try? await client.deleteSchedule(id: scheduleID)
        }
    }
}

// MARK: - Catch-up unit tests (injected `now`, no scheduler process)

/// Parses an ISO 8601 UTC date string (`"YYYY-MM-DDThh:mm:ssZ"`).
/// File-level so it is never captured as `self` inside `#expect` closures.
private func catchupDate(_ s: String) -> Date {
    try! Date(s, strategy: .iso8601)
}

/// Formats a date as `"YYYY-MM-DDThh:mm:ssZ"` for assertion messages.
private func catchupFmt(_ d: Date?) -> String {
    guard let d else { return "nil" }
    return d.formatted(.iso8601)
}

/// Seeds a schedule row with an explicit `next_run_at` + `last_slot_at` (the state
/// `markScheduleFired` would have written), then re-registers with an injected `now`
/// (the state `_schedule` produces on a restart).  Returns the resulting `next_run_at`.
private func catchupNextRunAt(
    client: StrandClient,
    name: String,
    interval: Duration,
    existingNextRunAt: Date,  // what markScheduleFired last set (may be correct or corrupted)
    lastSlot: Date,  // last successfully-fired slot boundary
    now: Date  // injected current time for the restart
) async throws -> Date? {
    // Step 1: create the row (use injected now to avoid real-time contamination).
    _ = try await client._schedule(
        name: name,
        pattern: .interval(interval),
        taskName: SitSimpleWorkflow.workflowName,
        params: StrandVoid.done,
        now: now
    )
    // Step 2: seed the pre-existing DB state directly.
    try await client.postgres.query(
        """
        UPDATE strand.schedules
        SET next_run_at  = \(existingNextRunAt),
            last_slot_at = \(lastSlot)
        WHERE queue = \(client.queueName) AND name = \(name)
        """,
        logger: client.logger
    )
    // Step 3: simulate restart — re-register with injected now.
    _ = try await client._schedule(
        name: name,
        pattern: .interval(interval),
        taskName: SitSimpleWorkflow.workflowName,
        params: StrandVoid.done,
        now: now
    )
    let schedules = try await client.listSchedules(queue: client.queueName)
    return schedules.first(where: { $0.name == name })?.nextRunAt
}

/// Catch-up arithmetic tests with an injected `now` so every assertion is
/// expressed as a fixed (existingNextRunAt, lastSlot, now) → expected triple.
/// No scheduler process is started; only `_schedule` and the DB are exercised.
@Suite("Unit — Schedule catch-up (injected now)", .tags(.integration), .serialized)
struct ScheduleCatchupUnitTests {

    // When existingNextRunAt is a future value that is LATER than the most-recent
    // elapsed slot (e.g. a previous restart jumped it past pending intervals),
    // re-registration must heal it by computing the correct catch-up slot and
    // letting LEAST(existing, computed) pick the earlier value.
    @Test("interval 90 min: corrupted future next_run_at healed to most-recent missed slot")
    func catchupInterval90MinCorruptedNextRunAt() async throws {
        try await withTestEnvironment { client in
            let result = try await catchupNextRunAt(
                client: client,
                name: "cu-90min-corrupt",
                interval: .seconds(5400),
                existingNextRunAt: catchupDate("2026-05-10T18:35:00Z"),
                lastSlot: catchupDate("2026-05-10T13:29:00Z"),
                now: catchupDate("2026-05-10T17:29:00Z")
            )
            // base=13:29 → first epoch boundary = 13:30 (9×90min from midnight)
            // steps=⌊(17:29-13:30)/90min⌋=⌊239/90⌋=2 → computed=13:30+180min=16:30
            // LEAST(18:35, 16:30) = 16:30
            let expected = catchupDate("2026-05-10T16:30:00Z")
            let got = catchupFmt(result)
            #expect(result == expected, "expected 16:30, got \(got)")
        }
    }

    // When existingNextRunAt is already the correct epoch-aligned next slot
    // and the restart happens before that slot is due, re-registration must
    // leave it untouched — LEAST(existing, computed) is a no-op when equal.
    @Test("interval 90 min: correct epoch-aligned next_run_at preserved on restart within window")
    func catchupInterval90MinCorrectNextRunAtPreserved() async throws {
        try await withTestEnvironment { client in
            let result = try await catchupNextRunAt(
                client: client,
                name: "cu-90min-correct",
                interval: .seconds(5400),
                existingNextRunAt: catchupDate("2026-05-10T18:00:00Z"),  // epoch-aligned: 12×90min
                lastSlot: catchupDate("2026-05-10T16:30:00Z"),  // epoch-aligned: 11×90min
                now: catchupDate("2026-05-10T17:00:00Z")
            )
            // base=16:30 → first epoch boundary = 18:00 (12×90min from midnight)
            // 18:00 > 17:00 → no catch-up, computed=18:00
            // LEAST(18:00, 18:00) = 18:00
            let expected = catchupDate("2026-05-10T18:00:00Z")
            let got = catchupFmt(result)
            #expect(result == expected, "expected 18:00, got \(got)")
        }
    }
}
