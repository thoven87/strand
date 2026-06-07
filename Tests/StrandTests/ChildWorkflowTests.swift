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

// MARK: - Workflow fixtures
//
// All workflow types are file-private to avoid name collisions with other test
// files in the same module.

// ── 1. AddTen ────────────────────────────────────────────────────────────────
// Simple leaf child workflow: adds 10 to the integer input.
// Registered on both workers in the cross-queue test and on the single shared
// worker in the same-queue test.
// Used by: SameQueueParentWorkflow, CrossQueueParentWorkflow.

private struct AddTenWorkflow: Workflow {
    typealias Input = Int
    typealias Output = Int

    mutating func run(context: WorkflowContext<Self>, input: Int) async throws -> Int {
        input + 10
    }
}

// ── 2. ChildQueueInput ───────────────────────────────────────────────────────
// Carries both the numeric value to operate on and the name of the queue that
// the child workflow should be dispatched to. Passing the queue name through
// the input lets each test supply a unique, randomly-generated child queue
// name without any global mutable state.
// Used by: CrossQueueParentWorkflow.

private struct ChildQueueInput: Codable, Sendable {
    let value: Int
    let childQueue: String
}

// ── 3. CrossQueueParent ──────────────────────────────────────────────────────
// Orchestrator that dispatches `AddTenWorkflow` to `input.childQueue` via
// `ChildWorkflowOptions.queue`. Suspends until the child completes, then
// returns the child's output as its own result.
// Used by: childWorkflowOnDifferentQueue.

private struct CrossQueueParentWorkflow: Workflow {
    typealias Input = ChildQueueInput
    typealias Output = Int

    mutating func run(
        context: WorkflowContext<Self>,
        input: ChildQueueInput
    ) async throws -> Int {
        try await context.runChildWorkflow(
            AddTenWorkflow.self,
            options: .init(queue: input.childQueue),
            input: input.value
        )
    }
}

// ── 4. SameQueueParent ───────────────────────────────────────────────────────
// Orchestrator that dispatches `AddTenWorkflow` on the default (inherited)
// queue — no `ChildWorkflowOptions.queue` override. Both parent and child
// therefore land on the same queue and can be served by a single worker.
// Used by: childWorkflowOnSameQueue.

private struct SameQueueParentWorkflow: Workflow {
    typealias Input = Int
    typealias Output = Int

    mutating func run(context: WorkflowContext<Self>, input: Int) async throws -> Int {
        try await context.runChildWorkflow(AddTenWorkflow.self, input: input)
    }
}

// ── 5. RequestCancelChild / RequestCancelParent ───────────────────────────
// Child workflow: suspends in `context.condition` until `context.isCancelRequested`
// is set by the framework (cooperative cancel from parent) or the timeout fires.
// Returns "cancelled" when the cancel signal arrives, "timeout" otherwise.
// Used by: parentClosePolicyRequestCancelDeliversSignal.

private struct RequestCancelChildWorkflow: Workflow {
    typealias Input = StrandVoid
    typealias Output = String

    mutating func run(
        context: WorkflowContext<Self>,
        input: StrandVoid
    ) async throws -> String {
        // Block until the parent requests cooperative cancellation.
        try await context.waitForCancellation()
        return "cancelled"
    }
}

// Parent: starts the child with .requestCancel policy and suspends waiting for it.
// The test cancels the parent externally via `client.cancelTask`, which triggers
// `cancelDescendants` and delivers the cooperative cancel signal to the child.
private struct WaitForCancelableChildWorkflow: Workflow {
    typealias Input = StrandVoid
    typealias Output = String

    mutating func run(
        context: WorkflowContext<Self>,
        input: StrandVoid
    ) async throws -> String {
        try await context.runChildWorkflow(
            RequestCancelChildWorkflow.self,
            options: .init(parentClosePolicy: .requestCancel),
            input: StrandVoid()
        )
    }
}

// MARK: - Test suite

@Suite("Integration — Child workflows", .tags(.integration), .serialized)
struct ChildWorkflowTests {

    // ── 0 ────────────────────────────────────────────────────────────────────────────
    // `parentClosePolicy = .requestCancel` delivers the cooperative cancel signal when
    // the parent is cancelled externally.
    //
    // Flow:
    //   1. Start WaitForCancelableChildWorkflow (parent) which spawns RequestCancelChildWorkflow
    //      (child) and suspends in WAITING state.
    //   2. Child suspends in `context.condition({ _ in context.isCancelRequested })`.
    //   3. Test cancels the parent via `cancelTask` which calls `cancelDescendants`:
    //      - `cancelDescendants` sets `cancel_requested = TRUE` on the child's task row
    //      - Wakes the child's WAITING run to PENDING
    //   4. Worker claims child; `claimed.cancelRequested = true`:
    //      - activation sets `activation.isCancelRequested = true` (for conditions)
    //      - calls `handlerTask.cancel()` (for slow-path CancellationError gates)
    //   5. `evaluateAndResumeFirstSatisfiedCondition` re-evaluates `{ _ in context.isCancelRequested }`
    //      → returns `true` → condition satisfied → child returns "cancelled".
    //   6. Test asserts the child's result is "cancelled".
    @Test("parentClosePolicy .requestCancel delivers cooperative cancel signal and child returns gracefully")
    func parentClosePolicyRequestCancelDeliversSignal() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [
                    WaitForCancelableChildWorkflow.self,
                    RequestCancelChildWorkflow.self,
                ]
            ) {
                // 1. Start the parent workflow.
                let parentHandle = try await client.startWorkflow(
                    WaitForCancelableChildWorkflow.self,
                    options: .init(maxAttempts: 1),
                    input: StrandVoid()
                )

                // 2. Wait until the child is in WAITING state — meaning it has run its
                //    first activation and is parked inside waitForCancellation().
                //
                //    It is not sufficient to wait until the child merely EXISTS (PENDING).
                //    If cancelTask fires while the child is still PENDING, cancelDescendants
                //    can't find a WAITING/SLEEPING run to wake, so request_cancel_wake
                //    returns zero rows and no pg_notify is sent.  The child would still
                //    complete (cancel_requested = TRUE causes the condition to fire on the
                //    first activation), but under full-suite Postgres load the worker may
                //    not claim the PENDING child within the test's timeout window.
                //
                //    Waiting for WAITING guarantees request_cancel_wake always finds a match.
                var childTaskID: UUID? = nil
                for _ in 0..<100 {  // up to 20 s (100 × 200 ms)
                    let page = try await ManagementQueries.listChildTasks(
                        on: client.postgres,
                        namespaceID: "default",
                        parentTaskID: parentHandle.taskID,
                        cursor: nil,
                        limit: 10,
                        logger: client.logger
                    )
                    if let child = page.items.first, child.state == .waiting {
                        childTaskID = child.id
                        break
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard let childTaskID else {
                    Issue.record("child task never reached WAITING state — parent did not start the child or it completed before parking")
                    return
                }

                // 3. Cancel the parent. `cancelDescendants` runs atomically inside
                //    `cancelTask`, delivering the cooperative cancel signal to the child
                //    and waking its WAITING run to PENDING.
                try await client.cancelTask(id: parentHandle.taskID)

                // 4. Await the child's result. The child sees `isCancelRequested = true`,
                //    its condition is satisfied, and it returns "cancelled" cooperatively.
                let childResult = try await client.awaitTaskResult(
                    id: childTaskID,
                    as: String.self,
                    options: .init(timeout: .seconds(30))
                )
                #expect(childResult == "cancelled")
            }
        }
    }

    // ── 1 ───────────────────────────────────────────────────────────────────────────
    // A single worker serves both the parent orchestrator and the child workflow
    // because they share the same queue. The worker claims the parent first,
    // which enqueues AddTenWorkflow, suspends to SLEEPING, and releases its slot.
    // The same worker then claims the child, completes it, and the parent is
    // re-awoken. The final result must equal input + 10 = 17.
    @Test("child workflow on the same queue adds ten and returns the correct result")
    func childWorkflowOnSameQueue() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [SameQueueParentWorkflow.self, AddTenWorkflow.self]
            ) {
                let handle = try await client.startWorkflow(
                    SameQueueParentWorkflow.self,
                    options: .init(),
                    input: 7
                )
                let result = try await handle.result(timeout: .seconds(15))
                #expect(result == 17)
            }
        }
    }

    // ── 2 ───────────────────────────────────────────────────────────────────
    // The parent orchestrator runs on `client.queueName`; `CrossQueueParent`
    // dispatches `AddTenWorkflow` to a separately created, randomly-named queue
    // served by a dedicated second worker. This exercises the full cross-queue
    // child dispatch path: the parent enqueues the child on the remote queue,
    // suspends to SLEEPING, and is re-awoken by the completion signal once the
    // child worker finishes. The final result must equal input.value + 10 = 15.
    //
    // Cleanup order (mirrored in both success and error paths so the child
    // queue is always removed even if the assertion or result-await throws):
    //   1. Cancel both worker tasks
    //   2. Drop the child queue
    @Test(
        "child workflow on a different queue dispatches cross-queue and returns the correct result"
    )
    func childWorkflowOnDifferentQueue() async throws {
        try await withTestEnvironment { client in
            let childQueue =
                "t\(UUID().uuidString.replacing("-", with: "").prefix(12).lowercased())"
            try await client.createQueue(childQueue)

            do {
                try await withWorker(
                    postgres: client.postgres,
                    queueName: client.queueName,
                    logger: client.logger,
                    workflows: [CrossQueueParentWorkflow.self]
                ) {
                    try await withWorker(
                        postgres: client.postgres,
                        queueName: childQueue,
                        logger: client.logger,
                        workflows: [AddTenWorkflow.self]
                    ) {
                        let handle = try await client.startWorkflow(
                            CrossQueueParentWorkflow.self,
                            options: .init(),
                            input: ChildQueueInput(value: 5, childQueue: childQueue)
                        )
                        let result = try await handle.result(timeout: .seconds(20))
                        #expect(result == 15)
                    }
                }
                try? await client.dropQueue(childQueue)
            } catch {
                try? await client.dropQueue(childQueue)
                throw error
            }
        }
    }
}
