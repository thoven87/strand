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

// ── CountingWorkflow ─────────────────────────────────────────────────────────
// Increments a module-level static counter each time its handler body executes,
// then returns the input string verbatim. The counter lets the test verify that
// no workflow was double-claimed and executed more than once.
//
// `executionCount` is a file-private type-level static; because `CountingWorkflow`
// is `private` it cannot be referenced from any other file in the test module,
// so there is no cross-test interference even when tests run sequentially in
// the same process.
// Used by: multipleWorkersDontDoubleClaim.

private struct CountingWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    static let executionCount = AtomicCounter()

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        Self.executionCount.increment()
        return input
    }
}

// MARK: - Test suite

@Suite("Integration — Concurrency", .tags(.integration), .serialized)
struct ConcurrencyTests {

    // ── 1 ───────────────────────────────────────────────────────────────────
    // Three independent `StrandWorker` instances poll the same queue with a
    // concurrency of 4 each (up to 12 simultaneous execution slots). Fifteen
    // distinct `CountingWorkflow` tasks are enqueued with a 50 ms gap between
    // submissions to avoid overwhelming the connection pool.
    //
    // The `FOR UPDATE SKIP LOCKED` claim in `Queries.claimRuns` guarantees that
    // each row is visible to exactly one worker at a time. This test makes that
    // guarantee observable by:
    //   • Asserting every result string matches the corresponding input — proving
    //     each workflow ran the correct handler body.
    //   • Asserting `CountingWorkflow.executionCount.value == 15` — proving no
    //     workflow was claimed and executed by more than one worker.
    //
    // The three worker tasks are cancelled in a `defer` block so they are always
    // stopped regardless of whether the test body succeeds or throws.
    @Test("fifteen concurrent workflows complete exactly once across three competing workers")
    func multipleWorkersDontDoubleClaim() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                concurrency: 4,
                workflows: [CountingWorkflow.self]
            ) {
                try await withWorker(
                    postgres: client.postgres,
                    queueName: client.queueName,
                    logger: client.logger,
                    concurrency: 4,
                    workflows: [CountingWorkflow.self]
                ) {
                    try await withWorker(
                        postgres: client.postgres,
                        queueName: client.queueName,
                        logger: client.logger,
                        concurrency: 4,
                        workflows: [CountingWorkflow.self]
                    ) {
                        // Enqueue 15 workflows with a small inter-submission delay so
                        // concurrent connection pool usage stays well within limits.
                        var handles: [WorkflowHandle<CountingWorkflow>] = []
                        for i in 0..<15 {
                            let handle = try await client.startWorkflow(
                                CountingWorkflow.self,
                                options: .init(),
                                input: "job-\(i)"
                            )
                            handles.append(handle)
                            try await Task.sleep(for: .milliseconds(50))
                        }

                        // Collect results sequentially. Each `result(timeout:)` call polls
                        // with exponential back-off until the workflow reaches a terminal
                        // state or the 30 s deadline is exceeded.
                        for (i, handle) in handles.enumerated() {
                            let result = try await handle.result(timeout: .seconds(30))
                            // The workflow must echo its own input string verbatim.
                            #expect(result == "job-\(i)")
                        }

                        // Every workflow must have executed exactly once.
                        // Any value > 15 indicates at least one double-claim.
                        #expect(CountingWorkflow.executionCount.value == 15)
                    }
                }
            }
        }
    }
}
