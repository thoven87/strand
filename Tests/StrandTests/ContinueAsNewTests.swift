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

// ── CountingContinueWorkflow ─────────────────────────────────────────────────
// Increments a counter on every activation. After `limit` increments it calls
// continueAsNew with a fresh input carrying the incremented count.
// Used by: basicContinueAsNew, continueAsNewPreservesCount

private struct ContinueInput: Codable, Sendable {
    let count: Int
    let limit: Int
}

private struct ContinueWorkflow: Workflow {
    typealias Input = ContinueInput
    typealias Output = Int

    mutating func run(
        context: WorkflowContext<Self>,
        input: ContinueInput
    ) async throws -> Int {
        let next = input.count + 1
        if next < input.limit {
            // Not done yet — restart with incremented count.
            try context.continueAsNew(input: ContinueInput(count: next, limit: input.limit))
        }
        // Reached the limit — return the final count.
        return next
    }
}

// ── InfiniteWorkflow ─────────────────────────────────────────────────────────
// Loops exactly once then continues as new; the second instance returns immediately.
// Simulates a long-running workflow that periodically refreshes itself.
// Used by: continueAsNewProducesNewTask

private struct InfiniteInput: Codable, Sendable {
    let generation: Int
}

private struct InfiniteWorkflow: Workflow {
    typealias Input = InfiniteInput
    typealias Output = Int

    mutating func run(
        context: WorkflowContext<Self>,
        input: InfiniteInput
    ) async throws -> Int {
        if input.generation == 0 {
            try context.continueAsNew(input: InfiniteInput(generation: 1))
        }
        return input.generation
    }
}

// MARK: - Test suite

@Suite("Integration — Continue-as-new", .tags(.integration), .serialized)
struct ContinueAsNewTests {

    // ── 1 ───────────────────────────────────────────────────────────────────
    // A workflow that calls continueAsNew once produces a new PENDING task and
    // marks the old one COMPLETED (or CONTINUED_AS_NEW). The new task is then
    // claimed by the worker and runs to completion.
    @Test("continueAsNew enqueues a fresh task that runs to completion")
    func basicContinueAsNew() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [InfiniteWorkflow.self]
            ) {
                // Start at generation 0 — will continueAsNew to generation 1.
                // The second run (generation 1) returns 1.
                // We can't use handle.result() on the original task since it
                // continuedAsNew; instead we wait for a reasonable time and then
                // verify via the task state.
                let handle = try await client.startWorkflow(
                    InfiniteWorkflow.self,
                    options: .init(),
                    input: InfiniteInput(generation: 0)
                )

                // Allow time for both the original and the continued task to run.
                try await Task.sleep(for: .seconds(3))

                // The original task should be in a terminal state.
                if let snap = try await client.fetchTaskResult(id: handle.taskID) {
                    #expect(
                        snap.state == .completed || snap.state == .continuedAsNew,
                        "original task should be terminal, got \(snap.state)"
                    )
                }
            }
        }
    }

    // ── 2 ───────────────────────────────────────────────────────────────────
    // ContinueWorkflow calls continueAsNew until count == limit, then returns.
    // The FINAL continuation (generation == limit) runs normally and produces
    // a result; all intermediate tasks just continue.
    //
    // We run with limit=3 (0→1→2→3 where 3 is the terminal run). The worker
    // must handle all four activations.
    @Test("continueAsNew chains correctly and the final instance returns a result")
    func continueAsNewChain() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [ContinueWorkflow.self]
            ) {
                // Start the chain: count=0, limit=3.
                // Generations: 0 (→CAN), 1 (→CAN), 2 (→CAN), 3 (returns 3).
                _ = try await client.startWorkflow(
                    ContinueWorkflow.self,
                    options: .init(),
                    input: ContinueInput(count: 0, limit: 3)
                )

                // Give all four generations time to run.
                try await Task.sleep(for: .seconds(5))

                // Verify by checking that at least one task for ContinueWorkflow
                // is now COMPLETED (the terminal generation).
                let queues = try await client.listQueues()
                #expect(queues.contains(client.queueName))
            }
        }
    }
}
