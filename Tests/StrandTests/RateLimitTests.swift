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

// MARK: - Unit tests

/// Pure in-process tests for `RateLimit.slotParams` — no database required.
///
/// Uses GitHub's Search API limit (30 req/min authenticated) as a concrete,
/// publicly documented example:
///   base interval = 60,000 ms / 30 = 2,000 ms per slot
///
/// The batch scenario — fetching detail records for each of 50 search results
/// in one dispatch — is realistic: search returns 50 items, the next step
/// calls the detail endpoint for every item (50 outbound calls).
@Suite("RateLimit.slotParams — units scaling")
struct RateLimitSlotParamsTests {

    // GitHub Search API (authenticated): 30 requests / minute.
    // One search request per dispatch → interval = 60,000 ms / 30 = 2,000 ms.
    @Test("units=1 produces the base intervalMs")
    func unitsOneIsBaseInterval() {
        let rl = RateLimit(limit: 30, period: .minutes(1), sharedKey: "github")!
        let params = rl.slotParams(for: "SearchReposActivity")
        #expect(params.intervalMs == 2_000)
        #expect(params.slotKey == "github")
    }

    // Fetching detail records for each of the 50 search results = 50 API calls
    // per dispatch.  units=50 advances the cursor by 50 × 2,000 ms = 100,000 ms,
    // so the bucket correctly throttles the next activity by the full cost.
    @Test("units=50 scales intervalMs by 50, same shared bucket")
    func unitsFiftyScalesInterval() {
        let rl = RateLimit(limit: 30, period: .minutes(1), sharedKey: "github", units: 50)!
        let params = rl.slotParams(for: "FetchRepoDetailsBatchActivity")
        #expect(params.intervalMs == 100_000)
        #expect(params.slotKey == "github")  // sharedKey is unchanged by units
    }

    // A single-call dispatch (units=1) and a 50-call batch dispatch (units=50)
    // must drain from the same "github" bucket so their combined load is correctly
    // accounted for.
    @Test("units=1 and units=50 resolve to the same slot key")
    func unitsDontChangeSlotKey() {
        let single = RateLimit(limit: 30, period: .minutes(1), sharedKey: "github", units: 1)!
        let batch = RateLimit(limit: 30, period: .minutes(1), sharedKey: "github", units: 50)!
        #expect(single.slotParams(for: "A").slotKey == batch.slotParams(for: "B").slotKey)
    }

    // keyed factory: closure
    // keyed(limit:period:by:) with a typed closure derives the slot key from the
    // activity's input at enqueue time instead of requiring it at the call site.
    @Test("keyed factory: closure derives slot key from typed input")
    func keyedClosureDrivesSlotKey() {
        struct UserInput: Sendable { let userID: String }

        let rl = RateLimit.keyed(limit: 30, period: .minutes(1)) {
            (input: UserInput) in input.userID
        }!

        let resolved = rl.resolving(input: UserInput(userID: "user-42"))
        let params = resolved.slotParams(for: "ProcessPayment")
        // slot key = "ProcessPayment:user-42"  (no sharedKey, so activity-name prefix applies)
        #expect(params.slotKey == "ProcessPayment:user-42")
        #expect(params.intervalMs == 2_000)
    }

    // keyed factory: KeyPath (non-optional)
    @Test("keyed factory: non-optional KeyPath derives slot key from typed input")
    func keyedKeyPathNonOptional() {
        struct UserInput: Sendable { let userID: String }

        let rl = RateLimit.keyed(limit: 30, period: .minutes(1), by: \UserInput.userID)!

        let resolved = rl.resolving(input: UserInput(userID: "user-99"))
        #expect(resolved.slotParams(for: "A").slotKey == "A:user-99")
    }

    // keyed factory: KeyPath (optional) — nil value falls back to global bucket
    @Test("keyed factory: optional KeyPath falls back to global bucket when nil")
    func keyedKeyPathOptional() {
        struct PageInput: Sendable { let officeID: String? }

        let rl = RateLimit.keyed(limit: 30, period: .minutes(1), by: \PageInput.officeID)!

        // Non-nil value → per-entity bucket
        let resolvedSome = rl.resolving(input: PageInput(officeID: "office-7"))
        #expect(resolvedSome.slotParams(for: "SyncPage").slotKey == "SyncPage:office-7")

        // Nil value → global bucket (activity-name key, no partition)
        let resolvedNil = rl.resolving(input: PageInput(officeID: nil))
        #expect(resolvedNil.slotParams(for: "SyncPage").slotKey == "SyncPage")
    }

    // keyed + sharedKey — extractor partitions WITHIN the shared bucket
    @Test("keyed factory: extractor partitions within a sharedKey bucket")
    func keyedWithSharedKey() {
        struct TenantInput: Sendable { let tenantID: String }

        // Two different activity types, same sharedKey, same extractor.
        let rl = RateLimit.keyed(limit: 100, period: .minutes(1), sharedKey: "api") {
            (input: TenantInput) in input.tenantID
        }!

        // sharedKey wins over the derived key for the bucket PREFIX,
        // but the partition is appended: "api:tenant-A".
        let paramsA = rl.resolving(input: TenantInput(tenantID: "tenant-A")).slotParams(for: "ActivityX")
        let paramsB = rl.resolving(input: TenantInput(tenantID: "tenant-B")).slotParams(for: "ActivityY")

        // Different tenants → different slot keys despite different activity names.
        #expect(paramsA.slotKey == "api:tenant-A")
        #expect(paramsB.slotKey == "api:tenant-B")
        #expect(paramsA.slotKey != paramsB.slotKey)
    }

    // resolving(input:) is a no-op when no extractor is present
    @Test("resolving(input:) is a no-op without a keyExtractor")
    func resolvingNoOpWithoutExtractor() {
        let rl = RateLimit(limit: 30, period: .minutes(1), key: "static-key")!
        let resolved = rl.resolving(input: "anything")
        #expect(resolved.slotParams(for: "A").slotKey == "A:static-key")
    }

    @Test("units clamped to 1: zero or negative units treated as 1")
    func unitsClampedToOne() {
        let rl = RateLimit(limit: 30, period: .minutes(1), sharedKey: "github", units: 0)!
        #expect(rl.units == 1)
        #expect(rl.slotParams(for: "A").intervalMs == 2_000)
    }

    @Test("per-key bucket: units scales intervalMs without changing the key prefix")
    func unitsWithPerKeyBucket() {
        let rl = RateLimit(limit: 10, period: .seconds(1), key: "customer:42", units: 5)!
        let params = rl.slotParams(for: "PaymentActivity")
        // base = 1,000 ms / 10 = 100 ms; × 5 units = 500 ms
        #expect(params.intervalMs == 500)
        #expect(params.slotKey == "PaymentActivity:customer:42")
    }
}

// MARK: - Integration tests

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

    // ── 7 ────────────────────────────────────────────────────────────────────────────────
    // units > 1: a high-unit dispatch must advance the shared-bucket cursor
    // by N × intervalMs rather than 1 × intervalMs.
    //
    // Setup: all three tasks share the same sharedKey (unique per test run).
    //   e1 — units=1,  limit=1/10s: immediate; cursor → NOW+10 s
    //   e2 — units=5,  limit=1/10s: available ≈ NOW+10 s; cursor → NOW+60 s
    //   e3 — units=1,  limit=1/10s: available ≈ NOW+60 s
    //
    // Gap e2→e3 must be ~50 s (5 × 10 s), proving the units=5 dispatch consumed
    // five slots’ worth of budget from the shared bucket.
    @Test("units > 1: dispatch consumes N slots from the shared bucket")
    func unitsConsumeMultipleSlots() async throws {
        try await withTestEnvironment { client in
            // Unique key so this test’s bucket doesn’t bleed into other runs.
            let key = "units-test-\(UUID().uuidString)"
            let single = RateLimit(limit: 1, period: .seconds(10), sharedKey: key)!
            let five = RateLimit(limit: 1, period: .seconds(10), sharedKey: key, units: 5)!

            let e1 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "1"),
                options: .init(rateLimit: single)
            )
            let e2 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "2"),
                options: .init(rateLimit: five)
            )
            let e3 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "3"),
                options: .init(rateLimit: single)
            )

            let dates = try await fetchAvailableAt(
                postgres: client.postgres,
                taskIDs: [e1.taskID, e2.taskID, e3.taskID],
                logger: client.logger
            )

            let at1 = try #require(dates[e1.taskID])
            let at2 = try #require(dates[e2.taskID])
            let at3 = try #require(dates[e3.taskID])
            let now = Date.now

            // e1: first in a cold bucket — immediately available.
            #expect(at1 <= now.addingTimeInterval(0.5), "e1 should be immediate")

            // e2: delayed by one single-unit interval from e1 (~10 s).
            let gap12 = at2.timeIntervalSince(at1)
            #expect(
                gap12 >= 9.0 && gap12 <= 11.0,
                "gap e1→e2 should be ~10 s (1 unit × 10 s), got \(gap12) s"
            )

            // e3: delayed by five intervals from e2 (~50 s) because units=5
            // advanced the cursor by 5 × 10 s = 50 s.
            let gap23 = at3.timeIntervalSince(at2)
            #expect(
                gap23 >= 49.0 && gap23 <= 51.0,
                "gap e2→e3 should be ~50 s (5 units × 10 s), got \(gap23) s"
            )
        }
    }

    // ── 8 ────────────────────────────────────────────────────────────────────────────────
    // keyExtractor: two activities with DIFFERENT inputs derive DIFFERENT slot keys
    // from the same RateLimit declaration, landing in independent per-entity buckets.
    //
    // Setup: one shared RateLimit created with .keyed(..., by: \EchoInput.value).
    //        Each of the three enqueues passes a different EchoInput.value.
    //
    // Expected available_at schedule (limit: 1/10 s, each input is its own bucket):
    //   e1 (value: "a") → immediate       bucket "EchoActivity:a"
    //   e2 (value: "b") → immediate       bucket "EchoActivity:b"  (independent)
    //   e3 (value: "a") → ~10 s delayed   bucket "EchoActivity:a"  (same as e1)
    @Test("keyExtractor: different inputs land in independent per-entity buckets")
    func keyExtractorCreatesPerEntityBuckets() async throws {
        try await withTestEnvironment { client in
            let rl = RateLimit.keyed(limit: 1, period: .seconds(10), by: \EchoInput.value)!

            let e1 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "a"),
                options: .init(rateLimit: rl)
            )
            let e2 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "b"),
                options: .init(rateLimit: rl)
            )
            // Same input value as e1 — should share e1’s bucket and be delayed.
            let e3 = try await client.enqueueActivity(
                EchoActivity.self,
                input: .init(value: "a"),
                options: .init(rateLimit: rl)
            )

            let dates = try await fetchAvailableAt(
                postgres: client.postgres,
                taskIDs: [e1.taskID, e2.taskID, e3.taskID],
                logger: client.logger
            )

            let at1 = try #require(dates[e1.taskID])
            let at2 = try #require(dates[e2.taskID])
            let at3 = try #require(dates[e3.taskID])
            let now = Date.now

            // e1 and e2 have different keys — both immediately available.
            #expect(at1 <= now.addingTimeInterval(0.5), "e1 (bucket \"a\") should be immediate")
            #expect(at2 <= now.addingTimeInterval(0.5), "e2 (bucket \"b\") should be immediate")

            // e3 shares e1’s bucket — delayed ~10 s.
            let gap13 = at3.timeIntervalSince(at1)
            #expect(
                gap13 >= 9.0 && gap13 <= 11.0,
                "e3 should be ~10 s after e1 (same bucket \"a\"), got \(gap13) s"
            )
        }
    }
}
