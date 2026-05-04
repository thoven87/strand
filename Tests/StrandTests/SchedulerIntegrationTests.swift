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
}
