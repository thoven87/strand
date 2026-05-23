import Logging
import NIOCore
import PostgresNIO
import Synchronization
import Testing

@testable import Strand

// MARK: - Shared workflow fixture

/// Minimal workflow used by the workflow-fairness test.
/// Runs one `TenantSlotActivity` then returns, so the completion log captures
/// which tenant's workflow got a slot — not which activity got a slot.
private struct FairnessTrackingWorkflow: Workflow {
    typealias Input = TenantSlotActivity.Input
    typealias Output = StrandVoid

    mutating func run(
        context: WorkflowContext<Self>,
        input: TenantSlotActivity.Input
    ) async throws -> StrandVoid {
        try await context.runActivity(
            TenantSlotActivity.self,
            input: input,
            options: ActivityOptions(maxAttempts: 1)
        )
    }
}

/// Parent workflow used by the child-workflow fairness test.
/// Fans out to N children for "heavy" and 1 child for "light" using
/// `ChildWorkflowOptions(fairnessKey:)`, then waits for all to complete.
private struct ChildFairnessParentWorkflow: Workflow {
    struct Input: Codable, Sendable {
        let heavyCount: Int
    }
    typealias Output = StrandVoid

    mutating func run(
        context: WorkflowContext<Self>,
        input: Input
    ) async throws -> StrandVoid {
        try await withThrowingTaskGroup(of: StrandVoid.self) { group in
            // Heavy children: all enqueued together with fairness key "heavy".
            for _ in 0..<input.heavyCount {
                group.addTask {
                    try await context.runChildWorkflow(
                        FairnessTrackingWorkflow.self,
                        options: ChildWorkflowOptions(fairnessKey: "heavy"),
                        input: .init(tenantKey: "heavy")
                    )
                }
            }
            // One light child: queued after heavy children but
            // fairness ensures it’s never starved to the end.
            group.addTask {
                try await context.runChildWorkflow(
                    FairnessTrackingWorkflow.self,
                    options: ChildWorkflowOptions(fairnessKey: "light"),
                    input: .init(tenantKey: "light")
                )
            }
            try await group.waitForAll()
        }
        return .done
    }
}

// MARK: - Shared activity fixture

/// Append-only log used to capture activity completion order.
/// Implemented as a class so it can be stored in a `struct` without violating
/// the `Copyable` requirement (Mutex<T> is ~Copyable).
private final class CompletionLog: Sendable {
    private let _log: Mutex<[String]> = Mutex([])
    func append(_ key: String) { _log.withLock { $0.append(key) } }
    var value: [String] { _log.withLock { $0 } }
}

/// Records which `tenantKey` completed each slot and optionally fires a
/// `TestExpectation` when a specific key is seen.
///
/// Must be defined at file scope so `Activity.name` (the Swift type
/// name) is stable — the registry looks up handlers by this string.
private struct TenantSlotActivity: Activity {
    struct Input: Codable, Sendable { let tenantKey: String }
    typealias Output = StrandVoid

    /// Append-only log of tenant keys in completion order.
    let log: CompletionLog
    /// Called synchronously after the slot is recorded.
    let onComplete: @Sendable (String) -> Void

    func run(input: Input, context: ActivityContext) async throws -> StrandVoid {
        log.append(input.tenantKey)
        onComplete(input.tenantKey)
        return .done
    }
}

// MARK: - Suite

@Suite("Integration — Fairness", .tags(.integration), .serialized)
struct FairnessTests {

    // ── 1. Activity-level fairness key ───────────────────────────────────────
    //
    // `claimTasks` uses a frontier query: only the highest-priority / oldest run
    // per `fairness_key` is eligible.  With two fairness keys and enough free
    // slots, both frontiers are claimed in the very first poll — so a "light"
    // tenant's ACTIVITY is never starved behind 20 "heavy" tenant activities.
    //
    // Without fairness keys all 21 tasks compete in FIFO order; "light" (enqueued
    // last) would appear at the very end of the completion log.
    @Test("[activity] fairness key ensures a light tenant is never starved by a heavy tenant")
    func activityFairnessKeyInterleavesTenants() async throws {
        let log = CompletionLog()
        let heavyCount = 20
        let total = heavyCount + 1

        try await withTestEnvironment { client in
            // Enqueue ALL tasks BEFORE starting the worker so the entire batch
            // is visible in the first claimTasks call. If the worker starts first
            // it would claim tasks one-by-one as they arrive (FIFO), defeating
            // the fairness test.

            // Heavy tenant: 20 tasks enqueued first (they fill the queue).
            for _ in 0..<heavyCount {
                _ = try await client.enqueueActivity(
                    TenantSlotActivity.self,
                    input: .init(tenantKey: "heavy"),
                    options: ActivityOptions(fairnessKey: "heavy")
                )
            }

            // Light tenant: 1 task enqueued AFTER all heavy tasks.
            // In a plain FIFO queue this would be position 20 (last).
            _ = try await client.enqueueActivity(
                TenantSlotActivity.self,
                input: .init(tenantKey: "light"),
                options: ActivityOptions(fairnessKey: "light")
            )

            // NOW start the worker — it sees all 21 tasks at once.
            // concurrency: 1  →  workflowConcurrency=1, activityConcurrency=2
            // maxConcurrency = 3, so the first claimTasks call requests qty=3.
            // With 2 fairness keys both frontiers are eligible; LIMIT 3 claims both
            // in one shot regardless of queue depth.
            try await confirmation("all \(total) activities complete", expectedCount: total) { confirmed in
                let allDone = TestExpectation()
                let activity = TenantSlotActivity(log: log) { _ in
                    confirmed()
                    allDone.trigger()
                }
                try await withWorker(
                    postgres: client.postgres,
                    queueName: client.queueName,
                    logger: client.logger,
                    concurrency: 1,
                    activities: [activity]
                ) {
                    try await allDone.wait(for: "all \(total) activities", count: total, timeout: .seconds(10))
                }
            }

            // Both heavy-frontier and light-frontier are claimed in the first poll.
            // "light" MUST appear at index 0 or 1 in the completion log.
            // In a FIFO queue it would appear at index 20.
            let seq = log.value
            let lightIndex = seq.firstIndex(of: "light") ?? seq.count
            #expect(
                lightIndex <= 1,
                "light tenant must land in the first claim batch (index ≤ 1); got \(lightIndex); order: \(seq)"
            )
        }
    }

    // ── 2. Activity-level priority ──────────────────────────────────────────
    //
    // `claimTasks` orders candidates by `priority ASC` before any other key.
    // A critical task (rawValue 1) therefore always sorts ahead of minimal tasks
    // (rawValue 5) regardless of enqueue order.
    //
    // Without priority the ACTIVITY would appear last since it was enqueued after
    // the 10 minimal tasks.
    @Test("[activity] critical-priority task is claimed before minimal-priority backlog")
    func activityPriorityOrdersDispatch() async throws {
        let log = CompletionLog()
        let minimalCount = 10
        let total = minimalCount + 1

        try await withTestEnvironment { client in
            // Enqueue all tasks BEFORE starting the worker (same reasoning as
            // the fairness test — the full batch must be visible at first claim).

            // 10 minimal-priority tasks enqueued first (no fairness key — all in
            // the same FIFO pool so priority is the only differentiator).
            for _ in 0..<minimalCount {
                _ = try await client.enqueueActivity(
                    TenantSlotActivity.self,
                    input: .init(tenantKey: "minimal"),
                    options: ActivityOptions(priority: .minimal)
                )
            }

            // 1 critical task enqueued LAST.  Without priority ordering it would
            // sit at the back of the queue; with priority it jumps to the front.
            _ = try await client.enqueueActivity(
                TenantSlotActivity.self,
                input: .init(tenantKey: "critical"),
                options: ActivityOptions(priority: .critical)
            )

            // `ORDER BY priority ASC` puts critical (1) before minimal (5), so
            // critical is always in the first claim batch.
            // maxConcurrency = workflowConcurrency + activityConcurrency = 1+2 = 3,
            // so the first claim picks 3 tasks: critical + two minimal.  All three
            // are instant, making intra-batch completion order indeterminate.
            // critIdx ≤ 2 proves critical was in the first 3-task batch.
            // In a FIFO queue (no priority) critical would appear at index 10.
            try await confirmation("all \(total) activities complete", expectedCount: total) { confirmed in
                let allDone = TestExpectation()
                let activity = TenantSlotActivity(log: log) { _ in
                    confirmed()
                    allDone.trigger()
                }
                try await withWorker(
                    postgres: client.postgres,
                    queueName: client.queueName,
                    logger: client.logger,
                    concurrency: 1,
                    activities: [activity]
                ) {
                    try await allDone.wait(for: "all \(total) activities", count: total, timeout: .seconds(10))
                }
            }

            let seq = log.value
            let critIdx = seq.firstIndex(of: "critical") ?? seq.count
            #expect(
                critIdx <= 2,
                "critical task must be in the first claim batch (index ≤ 2); got \(critIdx); order: \(seq)"
            )
        }
    }

    // ── 3. Workflow-level fairness key ──────────────────────────────────────
    //
    // Same frontier-based guarantee as test 1, but now the competing tasks are
    // WORKFLOW runs (kind='WORKFLOW'), not standalone activities.  This validates
    // that `WorkflowOptions(fairnessKey:)` flows through `startWorkflow` →
    // `enqueueTask` → `strand.runs.fairness_key` and that `claimTasks` respects
    // it for workflow activations exactly as it does for activities.
    //
    // `FairnessTrackingWorkflow` runs one `TenantSlotActivity` internally so the
    // completion log records which tenant's WORKFLOW got a slot first.
    @Test("[workflow] fairness key on WorkflowOptions prevents heavy tenant from starving light tenant")
    func workflowFairnessKeyInterleavesTenants() async throws {
        let log = CompletionLog()
        let heavyCount = 20
        let total = heavyCount + 1  // 21 activity completions (one per workflow)

        try await withTestEnvironment { client in
            // Enqueue all workflows BEFORE starting the worker.

            // 20 heavy-tenant workflows: fairnessKey is on the WORKFLOW, not the activity.
            for _ in 0..<heavyCount {
                _ = try await client.startWorkflow(
                    FairnessTrackingWorkflow.self,
                    options: WorkflowOptions(fairnessKey: "heavy"),
                    input: .init(tenantKey: "heavy")
                )
            }

            // 1 light-tenant workflow enqueued AFTER all heavy workflows.
            // Without fairness the heavy tenant's 20 workflow activations would
            // run first; with fairness both frontiers are claimed together.
            _ = try await client.startWorkflow(
                FairnessTrackingWorkflow.self,
                options: WorkflowOptions(fairnessKey: "light"),
                input: .init(tenantKey: "light")
            )

            try await confirmation("all \(total) activities complete", expectedCount: total) { confirmed in
                let allDone = TestExpectation()
                let activity = TenantSlotActivity(log: log) { _ in
                    confirmed()
                    allDone.trigger()
                }
                try await withWorker(
                    postgres: client.postgres,
                    queueName: client.queueName,
                    logger: client.logger,
                    concurrency: 1,
                    workflows: [FairnessTrackingWorkflow.self],
                    activities: [activity]
                ) {
                    try await allDone.wait(for: "all \(total) activities", count: total, timeout: .seconds(15))
                }
            }

            // The light-tenant workflow's activity must appear in the first few slots.
            // lightIndex ≤ 5 proves fairness is working without being brittle under
            // parallel test load — without fairness, light would always appear at index 20.
            let seq = log.value
            let lightIndex = seq.firstIndex(of: "light") ?? seq.count
            #expect(
                lightIndex <= 5,
                "light workflow must not be starved (index ≤ 5); got \(lightIndex); order: \(seq)"
            )
        }
    }

    // ── 4. Child-workflow fairness key ──────────────────────────────────────
    //
    // Exercises the `ChildWorkflowOptions(fairnessKey:)` path specifically:
    //   WorkflowContext.runChildWorkflow → scheduleChildWorkflow command
    //   → applyScheduleCommands → enqueueChildTasksBatch(fairnessKey:)
    //
    // A parent workflow fans out 20 heavy children + 1 light child via
    // `withThrowingTaskGroup`.  `applyScheduleCommands` enqueues all 21 atomically
    // so the worker sees both fairness frontiers in one poll.  The light child
    // must not be starved behind the heavy children.
    @Test("[child workflow] ChildWorkflowOptions fairnessKey prevents heavy children from starving light child")
    func childWorkflowFairnessKeyInterleavesTenants() async throws {
        let log = CompletionLog()
        let total = 21  // 21 FairnessTrackingWorkflow children, each runs 1 TenantSlotActivity

        try await withTestEnvironment { client in
            // Start the parent FIRST — it fans out children atomically in one
            // applyScheduleCommands call, so all children are in the DB together
            // before the worker's first poll.
            _ = try await client.startWorkflow(
                ChildFairnessParentWorkflow.self,
                input: .init(heavyCount: 20)
            )

            try await confirmation("all \(total) activities complete", expectedCount: total) { confirmed in
                let allDone = TestExpectation()
                let activity = TenantSlotActivity(log: log) { _ in
                    confirmed()
                    allDone.trigger()
                }
                try await withWorker(
                    postgres: client.postgres,
                    queueName: client.queueName,
                    logger: client.logger,
                    concurrency: 1,
                    workflows: [
                        ChildFairnessParentWorkflow.self,
                        FairnessTrackingWorkflow.self,
                    ],
                    activities: [activity]
                ) {
                    try await allDone.wait(for: "all \(total) activities", count: total, timeout: .seconds(20))
                }
            }

            // All 21 child workflows are enqueued atomically by enqueueChildTasksBatch,
            // so both fairness frontiers are visible to the worker's first poll.
            // lightIndex ≤ 12 (out of 21 total activities) proves fairness prevents full
            // starvation — without it, light would always appear at index 20.
            let seq = log.value
            let lightIndex = seq.firstIndex(of: "light") ?? seq.count
            #expect(
                lightIndex <= 12,
                "light child must not be fully starved (index ≤ 12); got \(lightIndex); order: \(seq)"
            )
        }
    }
}
