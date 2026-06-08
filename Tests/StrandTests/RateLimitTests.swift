import Logging
import NIOCore
import PostgresNIO
import Synchronization
import Testing

@testable import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Fixtures

private struct EchoInput: Codable, Sendable { let value: String }

/// Minimal activity that returns its input — used to verify rate-limited
/// activities still produce the correct result.
private struct EchoActivity: Activity {
    typealias Input = EchoInput
    typealias Output = String

    func run(input: EchoInput, context: ActivityContext) async throws -> String {
        input.value
    }
}

/// Workflow that runs three EchoActivities sequentially, each under the same
/// rate limit.  Returns the concatenated results so the test can confirm all
/// three executed correctly.
private struct ThreeEchoWorkflow: Workflow {
    typealias Input = StrandVoid
    typealias Output = String

    mutating func run(
        context: WorkflowContext<Self>,
        input: StrandVoid
    ) async throws -> String {
        // Very high rate (100/s = 10 ms gap) keeps tests fast while still
        // exercising the slot-allocation path.
        let rl = RateLimit(limit: 100, period: .seconds(1))
        let a = try await context.runActivity(EchoActivity.self, input: .init(value: "A"), options: .init(rateLimit: rl))
        let b = try await context.runActivity(EchoActivity.self, input: .init(value: "B"), options: .init(rateLimit: rl))
        let c = try await context.runActivity(EchoActivity.self, input: .init(value: "C"), options: .init(rateLimit: rl))
        return "\(a)\(b)\(c)"
    }
}

// MARK: - Helpers

/// Reads `available_at` for the most-recent PENDING/SLEEPING run of each
/// task in `taskIDs`, ordered by creation time.
private func fetchAvailableAt(
    postgres: PostgresClient,
    taskIDs: [UUID],
    logger: Logger
) async throws -> [UUID: Date] {
    let stream = try await postgres.query(
        """
        SELECT DISTINCT ON (r.task_id) r.task_id, r.available_at
        FROM strand.runs r
        WHERE r.task_id = ANY(\(taskIDs))
        ORDER BY r.task_id, r.attempt DESC
        """,
        logger: logger
    )
    var result: [UUID: Date] = [:]
    for try await row in stream {
        var col = row.makeIterator()
        let tid = try col.next()!.decode(UUID.self, context: .default)
        let at = try col.next()!.decode(Date.self, context: .default)
        result[tid] = at
    }
    return result
}

// MARK: - Tests

@Suite("Integration — Rate limiting", .tags(.integration), .serialized)
struct RateLimitTests {

    // ── 1 ────────────────────────────────────────────────────────────────────────
    // Enqueuing three standalone activities with the same global key (nil) and a
    // 1-per-10-second limit must allocate distinct, consecutive slots:
    //   run 1 → available_at ≈ NOW          (no delay)
    //   run 2 → available_at ≈ NOW + 10 s
    //   run 3 → available_at ≈ NOW + 20 s
    //
    // A 10-second interval is used deliberately: the slot-allocation SQL contains
    // GREATEST(stored_cursor, NOW()), which resets the cursor to NOW when the
    // stored slot has already elapsed.  With a 1-second interval the GREATEST reset
    // can trigger on a loaded machine if a subsequent enqueue takes just over 1 s
    // to acquire a DB connection.  At 10 s the reset window is wide enough that
    // it cannot be triggered by normal back-to-back async calls.
    //
    // This test inspects the DB directly so it doesn't need to wait for
    // execution and is fast regardless of worker speed.
    @Test("global key: three consecutive enqueues get 10-second-apart slots")
    func globalKeySlotStagger() async throws {
        try await withTestEnvironment { client in
            let before = Date.now
            let e1 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "x"),
                options: .init(rateLimit: .init(limit: 1, period: .seconds(10)))
            )
            let e2 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "y"),
                options: .init(rateLimit: .init(limit: 1, period: .seconds(10)))
            )
            let e3 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "z"),
                options: .init(rateLimit: .init(limit: 1, period: .seconds(10)))
            )
            let after = Date.now

            let dates = try await fetchAvailableAt(
                postgres: client.postgres,
                taskIDs: [e1.taskID, e2.taskID, e3.taskID],
                logger: client.logger
            )

            let at1 = try #require(dates[e1.taskID])
            let at2 = try #require(dates[e2.taskID])
            let at3 = try #require(dates[e3.taskID])

            // Run 1: slot = first available → must be immediately claimable
            // (≤ 500 ms after enqueue, allowing for clock skew between Swift and Postgres).
            #expect(
                at1 <= after.addingTimeInterval(0.5),
                "run 1 should be immediately available, got \(at1)"
            )

            // Run 2: slot is ~10 s after run 1's slot.
            let gap12 = at2.timeIntervalSince(at1)
            #expect(
                gap12 >= 9.0 && gap12 <= 11.0,
                "gap between run 1 and run 2 should be ~10 s, got \(gap12)"
            )

            // Run 3: slot is ~10 s after run 2's slot.
            let gap23 = at3.timeIntervalSince(at2)
            #expect(
                gap23 >= 9.0 && gap23 <= 11.0,
                "gap between run 2 and run 3 should be ~10 s, got \(gap23)"
            )

            // Sanity: slots are strictly ordered.
            #expect(
                at1 < at2 && at2 < at3,
                "available_at values must be strictly increasing"
            )

            _ = before  // suppress unused-variable warning
        }
    }

    // ── 2 ────────────────────────────────────────────────────────────────────────
    // Two different entity keys must have INDEPENDENT slot cursors.
    // Each key's first run is immediately available, even when both are enqueued
    // back-to-back with a tight rate limit.
    @Test("per-entity keys have independent slot cursors")
    func perKeyIndependence() async throws {
        try await withTestEnvironment { client in
            // Enqueue two tasks under key "alpha" and two under key "beta".
            let alpha1 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "a1"),
                options: .init(rateLimit: .init(limit: 1, period: .seconds(10), key: "alpha"))
            )
            let beta1 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "b1"),
                options: .init(rateLimit: .init(limit: 1, period: .seconds(10), key: "beta"))
            )
            let alpha2 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "a2"),
                options: .init(rateLimit: .init(limit: 1, period: .seconds(10), key: "alpha"))
            )
            let beta2 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "b2"),
                options: .init(rateLimit: .init(limit: 1, period: .seconds(10), key: "beta"))
            )

            let dates = try await fetchAvailableAt(
                postgres: client.postgres,
                taskIDs: [alpha1.taskID, alpha2.taskID, beta1.taskID, beta2.taskID],
                logger: client.logger
            )

            let atA1 = try #require(dates[alpha1.taskID])
            let atA2 = try #require(dates[alpha2.taskID])
            let atB1 = try #require(dates[beta1.taskID])
            let atB2 = try #require(dates[beta2.taskID])

            let now = Date.now

            // First run under each key is immediately available.
            #expect(
                atA1 <= now.addingTimeInterval(0.5),
                "alpha first run should be immediate, got \(atA1)"
            )
            #expect(
                atB1 <= now.addingTimeInterval(0.5),
                "beta first run should be immediate, got \(atB1)"
            )

            // Second run under each key is delayed by 10 s.
            #expect(
                atA2.timeIntervalSince(atA1) >= 9.0,
                "alpha second run should be ~10 s after first, got gap \(atA2.timeIntervalSince(atA1))"
            )
            #expect(
                atB2.timeIntervalSince(atB1) >= 9.0,
                "beta second run should be ~10 s after first, got gap \(atB2.timeIntervalSince(atB1))"
            )

            // Cross-key: alpha and beta first runs don't block each other.
            // Both should be near-simultaneous (within 1 s of each other).
            let crossGap = abs(atA1.timeIntervalSince(atB1))
            #expect(
                crossGap < 1.0,
                "alpha and beta first runs should be nearly simultaneous, gap=\(crossGap)"
            )
        }
    }

    // ── 3 ────────────────────────────────────────────────────────────────────────
    // After an idle period the slot cursor resets to NOW via GREATEST(cursor, NOW()),
    // so the next enqueue is IMMEDIATELY available — no artificial backlog.
    @Test("idle reset: cursor resets after a gap so the next task is immediate")
    func idleReset() async throws {
        try await withTestEnvironment { client in
            let key = "idle-reset-\(UUID().uuidString)"

            // Enqueue one task to seed the cursor.
            let first = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "seed"),
                options: .init(rateLimit: .init(limit: 1, period: .seconds(1), key: key))
            )

            // The cursor is now at NOW + 1 s.  Wait 1.5 s so it falls into the past.
            try await Task.sleep(for: .milliseconds(1_500))

            // After the idle gap, the next enqueue should be immediately available
            // (cursor reset by GREATEST(past_cursor, NOW()) = NOW).
            let second = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "after-idle"),
                options: .init(rateLimit: .init(limit: 1, period: .seconds(1), key: key))
            )

            let dates = try await fetchAvailableAt(
                postgres: client.postgres,
                taskIDs: [first.taskID, second.taskID],
                logger: client.logger
            )

            let atSecond = try #require(dates[second.taskID])
            let now = Date.now

            // The second task should be immediately available (not 1 s in the future).
            #expect(
                atSecond <= now.addingTimeInterval(0.3),
                "after idle period, next task should be immediately available, got \(atSecond)"
            )
        }
    }

    // ── 4 ────────────────────────────────────────────────────────────────────────
    // Activities without a rate limit must NOT be delayed — their available_at
    // should be NOW, regardless of whether a rate-limited activity with the same
    // name was previously enqueued.
    @Test("no rateLimit: activity is always immediately available")
    func noRateLimitIsImmediate() async throws {
        try await withTestEnvironment { client in
            let e1 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "no-limit")
            )
            let e2 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "no-limit-2")
            )
            let e3 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "no-limit-3")
            )

            let dates = try await fetchAvailableAt(
                postgres: client.postgres,
                taskIDs: [e1.taskID, e2.taskID, e3.taskID],
                logger: client.logger
            )

            let now = Date.now
            for (id, at) in dates {
                #expect(
                    at <= now.addingTimeInterval(0.3),
                    "task \(id) without rateLimit should be immediately available, got \(at)"
                )
            }
        }
    }

    // ── 5 ────────────────────────────────────────────────────────────────────────
    // End-to-end: a workflow that schedules three rate-limited activities
    // (100/s — fast enough for a test) must still complete with the correct
    // result.  Verifies that rate limiting doesn't break the execution model.
    @Test("workflow with rate-limited activities completes with correct result")
    func workflowRateLimitedActivitiesCorrectResult() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [ThreeEchoWorkflow.self],
                activities: [EchoActivity()]
            ) {
                let handle = try await client.startWorkflow(
                    ThreeEchoWorkflow.self,
                    options: .init(),
                    input: .done
                )
                let result = try await handle.result(timeout: .seconds(15))
                #expect(result == "ABC")
            }
        }
    }

    // ── 6 ────────────────────────────────────────────────────────────────────────
    // The slot key is "ActivityName:entityKey" when a key is provided.
    // Two activities with the SAME name but DIFFERENT entity keys must not
    // interfere with each other (the slotKey includes the key component).
    @Test("slot key includes entity key — same activity name, different keys are independent")
    func slotKeyIncludesEntityKey() async throws {
        try await withTestEnvironment { client in
            // Enqueue under EchoActivity with key "customer:1" and "customer:2".
            let c1a = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "c1-first"),
                options: .init(rateLimit: .init(limit: 1, period: .seconds(5), key: "customer:1"))
            )
            let c2a = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "c2-first"),
                options: .init(rateLimit: .init(limit: 1, period: .seconds(5), key: "customer:2"))
            )
            // Second tasks under each key — these should be delayed 5 s each.
            let c1b = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "c1-second"),
                options: .init(rateLimit: .init(limit: 1, period: .seconds(5), key: "customer:1"))
            )
            let c2b = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "c2-second"),
                options: .init(rateLimit: .init(limit: 1, period: .seconds(5), key: "customer:2"))
            )

            let dates = try await fetchAvailableAt(
                postgres: client.postgres,
                taskIDs: [c1a.taskID, c1b.taskID, c2a.taskID, c2b.taskID],
                logger: client.logger
            )

            let atC1a = try #require(dates[c1a.taskID])
            let atC1b = try #require(dates[c1b.taskID])
            let atC2a = try #require(dates[c2a.taskID])
            let atC2b = try #require(dates[c2b.taskID])
            let now = Date.now

            // First tasks for each customer: immediately available.
            #expect(atC1a <= now.addingTimeInterval(0.5), "c1 first should be immediate")
            #expect(atC2a <= now.addingTimeInterval(0.5), "c2 first should be immediate")

            // Second tasks: delayed ~5 s within their own key.
            #expect(
                atC1b.timeIntervalSince(atC1a) >= 4.5,
                "c1 second should be ~5 s after c1 first"
            )
            #expect(
                atC2b.timeIntervalSince(atC2a) >= 4.5,
                "c2 second should be ~5 s after c2 first"
            )
        }
    }
}
