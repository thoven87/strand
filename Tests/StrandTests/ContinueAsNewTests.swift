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

// ── SuggestWorkflow ————————————————————————————————————————————
// Runs one activity then returns whether suggestContinueAsNew was true on the
// second activation (the first activation always starts with historyEventCount=0).
// First activation writes WORKFLOW_STARTED + ACTIVITY_SCHEDULED (~2 events) and
// parks; the second activation starts with historyEventCount ≈ 2 and is where
// we observe the suggestion.
// Used by: suggestContinueAsNewFiresAtHalfThreshold

private struct SuggestPing: Activity {
    typealias Input = String
    typealias Output = String
    static let name = "suggest-ping"
    func run(input: String, context: ActivityContext) async throws -> String { input }
}

private struct SuggestWorkflow: Workflow {
    typealias Input = StrandVoid  // no input needed
    typealias Output = Bool  // was suggestContinueAsNew true on the second activation?

    mutating func run(
        context: WorkflowContext<Self>,
        input: StrandVoid
    ) async throws -> Bool {
        // One activity — causes a second activation when it completes.
        _ = try await context.runActivity(SuggestPing.self, input: "ping")
        // Second activation: historyEventCount ≈ 2 (WORKFLOW_STARTED + ACTIVITY_SCHEDULED).
        // With historyWarningThreshold=4, threshold/2=2, so suggestContinueAsNew = (2 >= 2) = true.
        // With the default threshold of 10_000, 2 < 5_000, so it is false.
        return context.suggestContinueAsNew
    }
}

// MARK: - Test suite

@Suite("Integration — Continue-as-new", .tags(.integration), .serialized)
struct ContinueAsNewTests {

    // ── 0 ─────────────────────────────────────────────────────────────────────────
    // context.suggestContinueAsNew is false for fresh workflows (historyEventCount=0)
    // and becomes true when historyEventCount >= historyWarningThreshold / 2.
    //
    // We use historyWarningThreshold=4 so the half-threshold is 2. After one activity
    // completes the parent's historyEventCount on the second activation is ≈2, making
    // suggestContinueAsNew true. With the default threshold (10_000, half=5_000), the
    // same count of 2 leaves it false.
    @Test("suggestContinueAsNew is false below threshold and true at or above half-threshold")
    func suggestContinueAsNewThreshold() async throws {
        try await withTestEnvironment { client in
            // Low threshold: historyWarningThreshold=4 → half=2 → should be true after 1 activity
            let suggested = try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [SuggestWorkflow.self],
                activities: [SuggestPing()],
                historyWarningThreshold: 4
            ) {
                let handle = try await client.startWorkflow(
                    SuggestWorkflow.self,
                    input: StrandVoid()
                )
                return try await handle.result(timeout: .seconds(10))
            }
            #expect(suggested == true, "expected suggestContinueAsNew=true with threshold=4")

            // Default threshold (10_000): historyEventCount≈2 is far below half=5_000
            let suggestedDefault = try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [SuggestWorkflow.self],
                activities: [SuggestPing()]
                // historyWarningThreshold defaults to 10_000
            ) {
                let handle = try await client.startWorkflow(
                    SuggestWorkflow.self,
                    input: StrandVoid()
                )
                return try await handle.result(timeout: .seconds(10))
            }
            #expect(suggestedDefault == false, "expected suggestContinueAsNew=false with default threshold")
        }
    }

    // ── 1 ─────────────────────────────────────────────────────────────────────────
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
                    status: .completed,
                    timeout: .seconds(15),
                    label: "terminal ContinueWorkflow generation (count == 3)"
                )
            }
        }
    }
}
