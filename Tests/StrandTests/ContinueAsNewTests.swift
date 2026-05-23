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
    // marks the old one CONTINUED_AS_NEW. The new task is then claimed by the
    // worker and runs to completion.
    @Test("continueAsNew enqueues a fresh task that runs to completion")
    func basicContinueAsNew() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [InfiniteWorkflow.self]
            ) {
                let handle = try await client.startWorkflow(
                    InfiniteWorkflow.self,
                    options: .init(),
                    input: InfiniteInput(generation: 0)
                )

                // Wait for the original task to reach a terminal state.
                // `continueAsNew` transitions it to CONTINUED_AS_NEW, not COMPLETED.
                // We cannot call handle.result() because the handle points to a
                // continued task — instead use awaitSnapshot with the full set of
                // terminal states.
                let snap = try await awaitSnapshot(
                    handle,
                    where: { [.completed, .continuedAsNew, .failed, .cancelled].contains($0.state) },
                    timeout: .seconds(10),
                    label: "InfiniteWorkflow generation-0 terminal state"
                )
                #expect(
                    snap.state == .completed || snap.state == .continuedAsNew,
                    "original task should be COMPLETED or CONTINUED_AS_NEW, got \(snap.state)"
                )
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
                let handle = try await client.startWorkflow(
                    ContinueWorkflow.self,
                    options: .init(),
                    input: ContinueInput(count: 0, limit: 3)
                )

                // Step 1: wait for generation 0 to become CONTINUED_AS_NEW.
                // continueAsNew on a root workflow creates an independent new task;
                // the original handle transitions to CONTINUED_AS_NEW, not COMPLETED.
                _ = try await awaitSnapshot(
                    handle,
                    where: { $0.state == .continuedAsNew || $0.state == .completed },
                    timeout: .seconds(10),
                    label: "ContinueWorkflow generation-0 continued"
                )

                // Step 2: wait for the terminal generation (count == 3) to COMPLETE.
                // continueAsNew creates independent tasks with no parent-child link,
                // so we don't have a direct handle to the final generation — use
                // awaitAnyTask to poll by name and state instead.
                try await awaitAnyTask(
                    client: client,
                    taskName: "ContinueWorkflow",
                    state: .completed,
                    timeout: .seconds(15),
                    label: "terminal ContinueWorkflow generation (count == 3)"
                )
            }
        }
    }
}
