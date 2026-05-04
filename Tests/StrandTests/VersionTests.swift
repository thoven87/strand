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

// ── VersionedWorkflow ────────────────────────────────────────────────────────
// Sleeps briefly so the test has a window to call `client.markVersion` before
// the version checkpoint is reached, then branches on the stored value.
// Returns "new-path" (true) or "old-path" (false).
// Used by: firstEncounterReturnsTrue, markVersionForcesOldPath

private struct VersionedWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        // Sleep briefly so the test window can call markVersion before this point.
        try await context.sleep(for: .milliseconds(200))
        let isNew = try context.version(changeID: "v2-feature")
        return isNew ? "new-path" : "old-path"
    }
}

// MARK: - Test suite

@Suite("Integration — Version checkpoints", .tags(.integration), .serialized)
struct VersionTests {

    // ── 1 ───────────────────────────────────────────────────────────────────
    // The very first time a workflow instance reaches `version(changeID:)` there
    // is no stored checkpoint, so the method returns `true` and persists it.
    // Subsequent re-activations would replay the same `true` value. The workflow
    // therefore takes the "new-path" branch and returns "new-path".
    @Test("first encounter of version(changeID:) returns true and takes the new code path")
    func firstEncounterReturnsTrue() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [VersionedWorkflow.self]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                VersionedWorkflow.self,
                options: .init(),
                input: "start"
            )
            let result = try await handle.result(timeout: .seconds(10))
            #expect(result == "new-path")
        }
    }

    // ── 2 ───────────────────────────────────────────────────────────────────
    // `StrandClient.markVersion` writes a version checkpoint directly into the
    // DB while the workflow is SLEEPING (during its 200 ms sleep). When the
    // next activation loads its checkpoint cache it finds `false` for
    // "v2-feature" and `version(changeID:)` returns that stored value, causing
    // the workflow to return "old-path".
    //
    // Timeline:
    //   t=  0 ms — workflow claimed, enters sleep(200 ms), run transitions to SLEEPING
    //   t=100 ms — test calls markVersion(..., value: false, taskID: handle.taskID)
    //   t=200 ms — sleep fires, worker re-claims the run
    //   t=200 ms — checkpoint cache loaded (contains the false written at t=100 ms)
    //   t=200 ms — version(changeID:) reads the cache → false → returns "old-path"
    @Test("markVersion with value: false overrides the checkpoint and forces the old code path")
    func markVersionForcesOldPath() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [VersionedWorkflow.self]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                VersionedWorkflow.self,
                options: .init(),
                input: "start"
            )

            // The workflow sleeps for 200 ms. At 100 ms it is still SLEEPING —
            // a safe window to write the version checkpoint before the next
            // activation loads its checkpoint cache.
            try await Task.sleep(for: .milliseconds(100))
            try await client.markVersion(
                changeID: "v2-feature",
                value: false,
                taskID: handle.taskID
            )

            let result = try await handle.result(timeout: .seconds(10))
            #expect(result == "old-path")
        }
    }
}
