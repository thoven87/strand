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

// MARK: - Test suite

@Suite("Integration — Child workflows", .tags(.integration), .serialized)
struct ChildWorkflowTests {

    // ── 1 ───────────────────────────────────────────────────────────────────
    // A single worker serves both the parent orchestrator and the child workflow
    // because they share the same queue. The worker claims the parent first,
    // which enqueues AddTenWorkflow, suspends to SLEEPING, and releases its slot.
    // The same worker then claims the child, completes it, and the parent is
    // re-awoken. The final result must equal input + 10 = 17.
    @Test("child workflow on the same queue adds ten and returns the correct result")
    func childWorkflowOnSameQueue() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [SameQueueParentWorkflow.self, AddTenWorkflow.self]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                SameQueueParentWorkflow.self,
                options: .init(),
                input: 7
            )
            let result = try await handle.result(timeout: .seconds(15))
            #expect(result == 17)
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
                "t\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())"
            try await client.createQueue(childQueue)

            var workerTask1: Task<Void, Never>? = nil
            var workerTask2: Task<Void, Never>? = nil
            do {
                // Parent worker: handles CrossQueueParentWorkflow on the test queue.
                workerTask1 = startWorker(
                    postgres: client.postgres,
                    queueName: client.queueName,
                    logger: client.logger,
                    workflows: [CrossQueueParentWorkflow.self]
                )
                // Child worker: handles AddTenWorkflow on the dedicated child queue.
                workerTask2 = startWorker(
                    postgres: client.postgres,
                    queueName: childQueue,
                    logger: client.logger,
                    workflows: [AddTenWorkflow.self]
                )

                let handle = try await client.startWorkflow(
                    CrossQueueParentWorkflow.self,
                    options: .init(),
                    input: ChildQueueInput(value: 5, childQueue: childQueue)
                )
                let result = try await handle.result(timeout: .seconds(20))
                #expect(result == 15)

                workerTask1?.cancel()
                workerTask2?.cancel()
                try? await client.dropQueue(childQueue)
            } catch {
                workerTask1?.cancel()
                workerTask2?.cancel()
                try? await client.dropQueue(childQueue)
                throw error
            }
        }
    }
}
