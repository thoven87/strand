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
    // `last_run_at` stores the scheduled slot time, not the wall-clock fire time.
    //
    // `markScheduleFired` is called with `firedAt: row.scheduledAt` — the
    // `next_run_at` value that triggered the fire.  When the scheduler catches
    // up a missed slot the wall-clock time and the slot time diverge (e.g. a
    // slot due at 13:00 UTC may be processed at 12:19 UTC the following day);
    // `last_run_at` must always reflect the slot, not the poll time, so the
    // UI displays a coherent cadence.
    //
    // We snapshot `nextRunAt` immediately after registration (that is the slot
    // the scheduler will fire), start the scheduler, wait for one fire, then
    // assert `lastRunAt == snapshotted nextRunAt` within floating-point tolerance.
    //
    @Test(
        "markScheduleFired stores the scheduled slot time, not the wall-clock fire time",
        .tags(.integration)
    )
    func firedAtIsScheduledSlotNotWallClock() async throws {
        try await withTestEnvironment { client in
            // Register with startsAt in the past so the schedule is
            // immediately due on the first scheduler poll.
            let scheduleID = try await client.schedule(
                name: "sit-firedat-test",
                pattern: .interval(.seconds(5)),
                workflowType: SitSimpleWorkflow.self,
                input: .done,
                startsAt: Date.now.addingTimeInterval(-10)
            )

            // Capture the scheduled slot time before the scheduler fires.
            let preFireList = try await client.listSchedules(queue: client.queueName)
            guard
                let scheduledSlot =
                    preFireList
                    .first(where: { $0.name == "sit-firedat-test" })?.nextRunAt
            else {
                Issue.record("schedule must have a nextRunAt after registration")
                return
            }

            // Start the scheduler (no worker needed — markScheduleFired runs
            // independently of whether a worker processes the enqueued task).
            let scheduler = StrandScheduler(
                client: client,
                options: SchedulerOptions(sleepCap: .seconds(1))
            )
            let schedulerTask = Task { try? await scheduler.run() }
            defer { schedulerTask.cancel() }

            // Wait until the schedule has been fired at least once.
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                let list = try await client.listSchedules(queue: client.queueName)
                if (list.first(where: { $0.name == "sit-firedat-test" })?.runCount ?? 0) >= 1 {
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }

            // lastRunAt must equal scheduledSlot (the slot the scheduler fired),
            // not the wall-clock time the scheduler happened to poll.
            let postFireList = try await client.listSchedules(queue: client.queueName)
            let lastRunAt =
                postFireList
                .first(where: { $0.name == "sit-firedat-test" })?.lastRunAt

            #expect(lastRunAt != nil, "lastRunAt must be set after the schedule fires")
            if let lastRunAt {
                // Both values come from the same Postgres TIMESTAMPTZ column
                // decoded through the same path — they must be bit-identical.
                let drift = abs(lastRunAt.timeIntervalSince(scheduledSlot))
                #expect(
                    drift < 0.001,
                    "lastRunAt (\(lastRunAt)) must equal the scheduled slot (\(scheduledSlot)), not the wall-clock fire time; drift = \(drift)s"
                )
            }

            try? await client.deleteSchedule(id: scheduleID)
        }
    }

    // ── 4 ───────────────────────────────────────────────────────────────────────────
    //
    // `upsertSchedule` never moves `next_run_at` backwards.
    //
    // The ON CONFLICT clause uses `GREATEST(existing, incoming)` so that a
    // scheduler restart — which recomputes `next_run_at` from scratch via
    // catch-up recovery — cannot reset an already-advanced schedule to an
    // earlier slot.  Without this guard, restarts cause spurious re-fires
    // (idempotent at the task level but they inflate `run_count` and corrupt
    // `last_run_at` with the catch-up wall-clock time).
    //
    // Test sequence:
    //  1. Register with no startsAt → next_run_at ≈ now + 3600 s (future).
    //  2. Re-register the same name with startsAt 2 h ago → catch-up recovery
    //     computes next_run_at ≈ now, which is earlier than the existing value.
    //  3. Assert the DB still holds the original future next_run_at.
    //
    @Test(
        "upsertSchedule preserves next_run_at when re-registration computes an earlier value",
        .tags(.integration)
    )
    func upsertPreservesNextRunAtOnReregistration() async throws {
        try await withTestEnvironment { client in
            // Step 1: fresh registration, no startsAt → next_run_at ≈ now + 3600s.
            let scheduleID = try await client.schedule(
                name: "sit-greatest-test",
                pattern: .interval(.seconds(3600)),
                workflowType: SitSimpleWorkflow.self,
                input: .done
            )

            let initial = try await client.listSchedules(queue: client.queueName)
            guard
                let initialNextRunAt =
                    initial
                    .first(where: { $0.name == "sit-greatest-test" })?.nextRunAt
            else {
                Issue.record("schedule must have nextRunAt after fresh registration")
                return
            }

            // Step 2: re-register the same name with startsAt 2 hours ago.
            // .latest accuracy fast-forwards nextRunAt to the most recent
            // elapsed 1-hour boundary, which is ≤ now — well behind the
            // already-set initialNextRunAt (≈ now + 3600s).
            _ = try await client.schedule(
                name: "sit-greatest-test",  // same name → ON CONFLICT DO UPDATE
                pattern: .interval(.seconds(3600)),
                workflowType: SitSimpleWorkflow.self,
                input: .done,
                startsAt: Date.now.addingTimeInterval(-7200)  // 2 hours ago
            )

            // Step 3: next_run_at must not have moved backward.
            let after = try await client.listSchedules(queue: client.queueName)
            let afterNextRunAt =
                after
                .first(where: { $0.name == "sit-greatest-test" })?.nextRunAt

            #expect(afterNextRunAt != nil, "nextRunAt must remain set after re-registration")
            if let afterNextRunAt {
                #expect(
                    afterNextRunAt >= initialNextRunAt.addingTimeInterval(-1),
                    "next_run_at must not regress on re-registration: was \(initialNextRunAt), got \(afterNextRunAt)"
                )
            }

            try? await client.deleteSchedule(id: scheduleID)
        }
    }
}
