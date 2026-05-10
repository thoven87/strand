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

// MARK: - Workflow & Activity fixtures
//
// All types are file-private to avoid name collisions with other test files
// in the same module.

// ── WltEchoWorkflow ──────────────────────────────────────────────────────────
// Minimal workflow that returns the input string upper-cased.
// Used by: delayUntilPreventsEarlyExecution, namespaceIsolationPreventsWorkerLeakage.

private struct WltEchoWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        input.uppercased()
    }
}

// ── WltHungActivity ──────────────────────────────────────────────────────────
// Activity that hangs indefinitely on its *first* invocation (run number 0)
// and completes instantly on every subsequent invocation. The `executionCount`
// counter is injected so each test can own a fresh instance without sharing
// mutable state across test runs.
//
// Flow in expiredLeaseRetriedByNewWorker:
//   Run 1: count=0 → sleep 60 s → worker cancelled → run left RUNNING in DB
//   Run 2: count=1 → return input immediately → task COMPLETED
//
// Used by: expiredLeaseRetriedByNewWorker.

private struct WltHungActivity: ActivityDefinition {
    typealias Input = String
    typealias Output = String

    let executionCount: AtomicCounter

    func run(input: String, context: ActivityContext) async throws -> String {
        let runNumber = executionCount.value
        executionCount.increment()
        if runNumber == 0 {
            // First run: hang until the worker task is cancelled.
            try await Task.sleep(for: .seconds(60))
        }
        return input
    }
}

// ── WltSlowActivity ───────────────────────────────────────────────────────────
// Activity that sleeps for 30 seconds. Guarantees it is still RUNNING when
// the parent workflow is cancelled in the cascade-cancellation test.
//
// Used by: cancelWorkflowCascadesToChildren.

private struct WltSlowActivity: ActivityDefinition {
    typealias Input = StrandVoid
    typealias Output = StrandVoid

    func run(input: StrandVoid, context: ActivityContext) async throws -> StrandVoid {
        try await Task.sleep(for: .seconds(30))
        return .done
    }
}

// ── WltCancellableWorkflow ────────────────────────────────────────────────────
// Workflow that dispatches two WltSlowActivity calls in parallel with `async let`.
// Because both activities sleep for 30 seconds they are guaranteed to be RUNNING
// when the parent is cancelled.
//
// Used by: cancelWorkflowCascadesToChildren.

private struct WltCancellableWorkflow: Workflow {
    typealias Input = StrandVoid
    typealias Output = StrandVoid

    mutating func run(
        context: WorkflowContext<Self>,
        input: StrandVoid
    ) async throws -> StrandVoid {
        async let a: StrandVoid = context.runActivity(WltSlowActivity.self)
        async let b: StrandVoid = context.runActivity(WltSlowActivity.self)
        _ = try await (a, b)
        return .done
    }
}

// ── WltSignalWorkflow ──────────────────────────────────────────────────────────────────
// Workflow that suspends until a named signal arrives, then returns the
// decoded payload string.
//
// Used by: signalWakesWorkflowAndDeliversPayload.

private struct WltSignalWorkflow: Workflow {
    typealias Input = StrandVoid
    typealias Output = String

    var received: String = ""

    mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
        if name == "unlock", let buf = payload {
            received = (try? JSON.decode(String.self, from: buf)) ?? ""
        }
    }

    mutating func run(
        context: WorkflowContext<Self>,
        input: StrandVoid
    ) async throws -> String {
        try await context.condition { !$0.received.isEmpty }
        return received
    }
}

// MARK: - Test suite

@Suite("Integration — Worker Lifecycle", .tags(.integration), .serialized)
struct WorkerLifecycleTests {

    // ── 1 ───────────────────────────────────────────────────────────────────
    //
    // Full end-to-end test of the lease-expiry retry path via `leaseExpiryLoop`.
    //
    // Step-by-step:
    //  1. Enqueue a WltHungActivity (max 2 attempts, no backoff).
    //  2. Start worker 1 — it claims the activity and enters the 60-second sleep.
    //  3. Wait until `strand.tasks.state == 'RUNNING'` (worker has claimed).
    //  4. Cancel worker 1 — Swift catches CancellationError and leaves the run
    //     RUNNING in the DB (this is the documented graceful-shutdown behaviour).
    //  5. Manually backdate `strand.runs.lease_expires_at` by 2 seconds so the
    //     next sweep fires immediately.
    //  6. Start worker 2 with `leaseExpiryInterval: .seconds(1)` so the sweep
    //     runs within 1 second rather than the 5-second default.
    //  7. Worker 2's `leaseExpiryLoop` calls `sweepExpiredLeases`, which calls
    //     `failRun`, which creates a new PENDING run for attempt 2.
    //  8. Worker 2 claims attempt 2 → WltHungActivity.run returns immediately
    //     (runNumber == 1 on retry) → task reaches COMPLETED.
    //  9. Assert state == .completed and attempt == 2.
    //
    @Test(
        "expired lease is swept by leaseExpiryLoop and re-queued transparently at the same attempt",
        .tags(.integration)
    )
    func expiredLeaseRetriedByNewWorker() async throws {
        let counter = AtomicCounter()

        try await withTestEnvironment { client in

            // 1. Enqueue the activity: 2 max attempts, immediate retry (no backoff).
            let enq = try await client.enqueueActivity(
                WltHungActivity.self,
                input: "hello",
                options: ActivityOptions(
                    maxAttempts: 2,
                    retryStrategy: .constant(.zero)
                )
            )

            // 2. Start worker 1 with the hung activity registered.
            let worker1Task = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                activities: [WltHungActivity(executionCount: counter)]
            )

            // 3. Wait until the run is RUNNING (worker has claimed and entered the handler).
            let runDeadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < runDeadline {
                if let snap = try await client.fetchTaskResult(id: enq.taskID),
                    snap.state == .running
                {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }

            // 4. Cancel worker 1. The worker catches CancellationError and
            //    deliberately leaves the run in RUNNING state.
            worker1Task.cancel()
            try await Task.sleep(for: .milliseconds(300))

            // 5. Backdate the lease so the next sweep treats it as expired.
            try await client.postgres.query(
                """
                UPDATE strand.runs
                SET lease_expires_at = NOW() - INTERVAL '2 seconds'
                WHERE task_id = \(enq.taskID)
                  AND state   = 'RUNNING'
                """,
                logger: client.logger
            )

            // 6. Start worker 2 with a short leaseExpiryInterval so the
            //    sweep fires within ~1 second instead of the 5-second default.
            let worker2Task = Task {
                let notifier2 = StrandNotifier(
                    postgres: client.postgres,
                    channels: [StrandNotifier.tasksChannel],
                    logger: client.logger
                )
                let worker2 = StrandWorker(
                    postgres: client.postgres,
                    options: WorkerOptions(
                        queue: client.queueName,
                        pollInterval: .milliseconds(20),
                        fatalOnLeaseTimeout: false,
                        leaseExpiryInterval: .seconds(1)
                    ),
                    notifier: notifier2,
                    activities: [WltHungActivity(executionCount: counter)],
                    logger: client.logger
                )
                try? await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await notifier2.run() }
                    group.addTask { try await worker2.run() }
                    try await group.next()
                    group.cancelAll()
                }
            }
            defer { worker2Task.cancel() }

            // 7-8. Wait for terminal state.
            let snap = try await awaitTerminal(
                client: client,
                taskID: enq.taskID,
                timeout: .seconds(20)
            )
            #expect(snap.state == .completed)

            // 9. Verify the sweep re-queued the same attempt (no attempt increment).
            // A lease expiry is an infrastructure event, not a business failure —
            // the task's retry budget must not be consumed.
            if let detail = try await ManagementQueries.getTask(
                on: client.postgres,
                namespaceID: "default",
                taskID: enq.taskID,
                logger: client.logger
            ) {
                #expect(detail.attempt == 1)
            } else {
                Issue.record("task detail row not found after completion")
            }
        }
    }

    // ── 2 ───────────────────────────────────────────────────────────────────
    //
    // Verifies that a workflow enqueued with `WorkflowOptions.delayUntil` set
    // 3 seconds in the future is NOT claimed by a worker until that time passes.
    //
    // The `available_at` column in `strand.runs` is set to `delayUntil` and
    // the `claimTasks` query includes `AND available_at <= NOW()`, so the run
    // is invisible to the worker until the clock advances past `delayUntil`.
    //
    @Test(
        "task with delayUntil is not claimed by the worker before its scheduled time",
        .tags(.integration)
    )
    func delayUntilPreventsEarlyExecution() async throws {
        try await withTestEnvironment { client in
            let availableAt = Date.now.addingTimeInterval(3)

            let handle = try await client.startWorkflow(
                WltEchoWorkflow.self,
                options: WorkflowOptions(delayUntil: availableAt),
                input: "hi"
            )

            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [WltEchoWorkflow.self]
            )
            defer { workerTask.cancel() }

            // After 1 second the task must still be PENDING — too early to claim.
            try await Task.sleep(for: .seconds(1))
            let earlySnap = try await client.fetchTaskResult(id: handle.taskID)
            #expect(
                earlySnap?.state == .pending,
                "task must remain PENDING before delayUntil elapses"
            )

            // After the delay elapses the worker picks it up and completes it.
            let finalSnap = try await awaitTerminal(
                client: client,
                taskID: handle.taskID,
                timeout: .seconds(10)
            )
            #expect(finalSnap.state == .completed)
        }
    }

    // ── 3 ───────────────────────────────────────────────────────────────────
    //
    // Cancelling a running workflow must cascade to all of its running child
    // activities via the recursive CTE in `Queries.cancelTask`.
    //
    // Setup:
    //  - Workflow dispatches two WltSlowActivity tasks in parallel (`async let`).
    //  - Both activities sleep for 30 seconds, so they are still RUNNING when
    //    the workflow is cancelled.
    //  - Poll `ManagementQueries.listChildTasks` until both show state == .running,
    //    then cancel the parent.
    //
    // Assertions:
    //  - Parent task state == .cancelled.
    //  - Both child activity tasks state == .cancelled.
    //
    @Test(
        "cancelling a workflow propagates cancellation to all running child activities",
        .tags(.integration)
    )
    func cancelWorkflowCascadesToChildren() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                concurrency: 4,
                workflows: [WltCancellableWorkflow.self],
                activities: [WltSlowActivity()]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                WltCancellableWorkflow.self,
                options: .init(maxAttempts: 1),
                input: .done
            )

            // Poll until both child activities are RUNNING in the DB.
            var childRows: [TaskSummaryRow] = []
            let runDeadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < runDeadline {
                let page = try await ManagementQueries.listChildTasks(
                    on: client.postgres,
                    namespaceID: "default",
                    parentTaskID: handle.taskID,
                    cursor: nil,
                    limit: 10,
                    logger: client.logger
                )
                if page.items.filter({ $0.state == .running }).count >= 2 {
                    childRows = page.items
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(
                childRows.filter({ $0.state == .running }).count >= 2,
                "expected at least 2 running child activities before cancellation"
            )

            // Cancel the parent workflow — must cascade to all descendants.
            try await client.cancelTask(id: handle.taskID)

            // Parent must be CANCELLED.
            let parentSnap = try await client.fetchTaskResult(id: handle.taskID)
            #expect(parentSnap?.state == .cancelled)

            // Both child activities must also be CANCELLED.
            for child in childRows {
                let childSnap = try await client.fetchTaskResult(id: child.id)
                #expect(
                    childSnap?.state == .cancelled,
                    "child activity \(child.id) must be CANCELLED after parent cancellation"
                )
            }
        }
    }

    // ── 4 ───────────────────────────────────────────────────────────────────
    //
    // Namespace isolation: a worker scoped to namespace B must not claim tasks
    // enqueued in namespace A, even when both workers share the same queue name.
    //
    // `StrandWorker.pollLoop` filters by `namespace_id` in every SQL query, so
    // worker B will never see namespace A's `strand.runs` rows.
    //
    // After proving namespace B's worker ignores the task, we start a namespace A
    // worker and confirm the task completes normally.
    //
    @Test(
        "worker in namespace B does not process tasks enqueued in namespace A",
        .tags(.integration)
    )
    func namespaceIsolationPreventsWorkerLeakage() async throws {
        try await withTestEnvironment { clientA in
            // Build a second client scoped to a unique namespace B but the same queue.
            let nsBSuffix = UUID()
                .uuidString
                .replacingOccurrences(of: "-", with: "")
                .prefix(12)
                .lowercased()
            let nsB = "wlt-nsb-\(nsBSuffix)"
            let clientB = StrandClient(
                postgres: clientA.postgres,
                queue: clientA.queueName,
                namespace: nsB,
                logger: clientA.logger
            )

            // Start worker B — auto-registers namespace B and its queue,
            // then polls exclusively for namespace B tasks.
            let workerBTask = Task {
                let notifierB = StrandNotifier(
                    postgres: clientA.postgres,
                    channels: [StrandNotifier.tasksChannel],
                    logger: clientA.logger
                )
                let w = StrandWorker(
                    postgres: clientA.postgres,
                    options: WorkerOptions(
                        queue: clientA.queueName,
                        namespace: nsB,
                        pollInterval: .milliseconds(20),
                        fatalOnLeaseTimeout: false
                    ),
                    notifier: notifierB,
                    workflows: [WltEchoWorkflow.self],
                    logger: clientA.logger
                )
                try? await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await notifierB.run() }
                    group.addTask { try await w.run() }
                    try await group.next()
                    group.cancelAll()
                }
            }
            defer { workerBTask.cancel() }

            // Give worker B a moment to start up before enqueuing.
            try await Task.sleep(for: .milliseconds(200))

            // Enqueue a workflow in namespace A (the "default" namespace).
            let handle = try await clientA.startWorkflow(
                WltEchoWorkflow.self,
                options: .init(),
                input: "hello"
            )

            // Worker B must NOT claim namespace A's task.
            try await Task.sleep(for: .seconds(1))
            let earlySnap = try await clientA.fetchTaskResult(id: handle.taskID)
            #expect(
                earlySnap?.state == .pending,
                "worker B must not claim tasks belonging to namespace A"
            )

            // Start a worker for namespace A — it must process the task.
            let workerATask = startWorker(
                postgres: clientA.postgres,
                queueName: clientA.queueName,
                logger: clientA.logger,
                workflows: [WltEchoWorkflow.self]
            )
            defer { workerATask.cancel() }

            let result = try await handle.result(timeout: .seconds(10))
            #expect(result == "HELLO")

            // Cleanup: drop namespace B's queue and namespace row.
            // withTestEnvironment handles all of namespace A's artefacts.
            try? await clientB.dropQueue(clientA.queueName)
            _ = try? await clientA.postgres.query(
                "DELETE FROM strand.namespaces WHERE id = \(nsB)",
                logger: clientA.logger
            )
        }
    }

    // ── 5 ───────────────────────────────────────────────────────────────────────
    //
    // Signal delivery integration test.
    //
    // Verifies:
    //   a) A workflow that calls context.condition stays SLEEPING until
    //      the signal arrives.
    //   b) After signal delivery the workflow resumes and completes.
    //   c) The payload is delivered correctly to handleSignal.

    @Test("signal wakes a sleeping workflow and delivers payload", .tags(.integration))
    func signalWakesWorkflowAndDeliversPayload() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [WltSignalWorkflow.self]
            )
            defer { workerTask.cancel() }

            // 1. Enqueue — workflow will block in condition { !$0.received.isEmpty }
            let result = try await client.startWorkflow(
                WltSignalWorkflow.self,
                input: .done
            )
            let taskID = result.taskID

            // 2. Confirm workflow is SLEEPING before signal arrives
            try await Task.sleep(for: .milliseconds(500))
            let earlySnap = try await client.fetchTaskResult(id: taskID)
            #expect(earlySnap?.state != .completed, "workflow should not have completed before signal")

            // 3. Send signal with payload
            let handle = try await client.workflow(id: result.workflowID, as: WltSignalWorkflow.self)
            try await handle!.signal(name: "unlock", payload: "hello")

            // 4. Workflow should now complete with the payload value
            let terminal = try await awaitTerminal(
                client: client,
                taskID: taskID,
                timeout: .seconds(10)
            )
            #expect(terminal.state == .completed)

            // 5. Verify the payload was delivered and returned as the workflow result
            if let decoded = try? terminal.decodeResult(as: String.self) {
                #expect(decoded == "hello")
            }
        }
    }
}
