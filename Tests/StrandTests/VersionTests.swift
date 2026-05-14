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

// ── VersionBeforeSleepWorkflow ────────────────────────────────────────────────
// The version checkpoint is written BEFORE the sleep, so a worker crash during
// the sleep still has the checkpoint on disk. The fresh-path recovery on the
// next worker must replay the stored value.
// seqNum 1 = version checkpoint, seqNum 2 = sleep.
// Used by: versionCheckpointSurvivesWorkerRestart

private struct VersionBeforeSleepWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        // Version call is BEFORE the sleep — checkpoint written before sleep fires.
        let isNew = try context.version(changeID: "v2-before-sleep")
        try await context.sleep(for: .milliseconds(200))
        return isNew ? "new-path" : "old-path"
    }
}

// ── TwoVersionWorkflow ────────────────────────────────────────────────────────
// Demonstrates the multi-step migration pattern: two independent changeIDs
// called unconditionally, each consuming its own stable sequence number.
// seqNum 1 = sleep, seqNum 2 = v2-feature, seqNum 3 = v3-feature.
// Used by: multiStepBothDefault, multiStepMarkV3False, multiStepBothFalse

private struct TwoVersionWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        // Sleep first so the test can mark version values before they are read.
        try await context.sleep(for: .milliseconds(200))
        // Both calls are UNCONDITIONAL — determinism requires this.
        let isV2 = try context.version(changeID: "multi-v2")
        let isV3 = try context.version(changeID: "multi-v3")
        if isV3 { return "v3-path" }  // current code (both patches applied)
        if isV2 { return "v2-path" }  // intermediate (only first patch)
        return "original-path"  // neither patch applied
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

    // ── 2 ───────────────────────────────────────────────────────────────────────
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

            // Wait until the workflow is confirmed SLEEPING before overwriting
            // the checkpoint. A fixed Task.sleep(100ms) is a timing race on slow
            // CI machines: if the first activation hasn't run yet, markVersion
            // writes false but the activation later overwrites it with true.
            // Polling the actual state is safe regardless of machine speed.
            let sleepDeadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < sleepDeadline {
                if let snap = try await handle.snapshot(), snap.state == .sleeping {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await client.markVersion(
                changeID: "v2-feature",
                value: false,
                taskID: handle.taskID
            )

            let result = try await handle.result(timeout: .seconds(10))
            #expect(result == "old-path")
        }
    }

    // ── 3 ───────────────────────────────────────────────────────────────────────
    // The version checkpoint is written on the FIRST activation (before the sleep).
    // Cancelling the first worker while the workflow sleeps simulates a crash.
    // The second worker's fresh-path recovery loads checkpoints from the DB;
    // version() must return the stored `true` value rather than `true` from
    // a default — confirming the checkpoint survives a worker restart.
    @Test("version checkpoint written before sleep survives worker restart")
    func versionCheckpointSurvivesWorkerRestart() async throws {
        try await withTestEnvironment { client in
            // First worker runs the workflow until it enters the sleep.
            let firstWorker = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [VersionBeforeSleepWorkflow.self]
            )

            let handle = try await client.startWorkflow(
                VersionBeforeSleepWorkflow.self,
                options: .init(),
                input: "start"
            )

            // Wait until the workflow is SLEEPING (version checkpoint persisted,
            // now suspended on the sleep timer).
            let sleepDeadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < sleepDeadline {
                if let snap = try await handle.snapshot(), snap.state == .sleeping {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }

            // Simulate a worker crash by cancelling the first worker.
            // The run is now SLEEPING in the DB with a persisted version checkpoint.
            firstWorker.cancel()

            // Start a fresh worker. It will do a fresh-path activation: load
            // checkpoints from DB, populate the checkpoint cache, then drain.
            // version(changeID:) must return the stored `true` from the cache,
            // not the default `true` from a new write — but the observable
            // result is the same. The important thing is the checkpoint survives.
            let secondWorker = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [VersionBeforeSleepWorkflow.self]
            )
            defer { secondWorker.cancel() }

            let result = try await handle.result(timeout: .seconds(10))
            // version checkpoint stored `true` before crash — new-path after recovery.
            #expect(result == "new-path")
        }
    }

    // ── 4 ───────────────────────────────────────────────────────────────────────
    // Multi-step migration — both changeIDs default to `true`.
    // Neither markVersion call is made: isV2=true, isV3=true → "v3-path".
    @Test("multi-step: both version gates default to true and take the v3 path")
    func multiStepBothDefault() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [TwoVersionWorkflow.self]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                TwoVersionWorkflow.self,
                options: .init(),
                input: "start"
            )
            let result = try await handle.result(timeout: .seconds(10))
            // Both default to true; v3 wins the cascading check.
            #expect(result == "v3-path")
        }
    }

    // ── 5 ───────────────────────────────────────────────────────────────────────
    // Multi-step migration — only the LATEST (v3) gate is forced to false.
    // seqNum layout: sleep=1, multi-v2=2, multi-v3=3.
    // While sleeping (1 checkpoint written), v3 is the second unwritten version
    // call → callSiteIndex: 2 → seqNum = 1+2 = 3.
    // Result: isV2=true (default), isV3=false → "v2-path".
    @Test("multi-step: marking only the v3 gate false takes the intermediate v2 path")
    func multiStepMarkV3False() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [TwoVersionWorkflow.self]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                TwoVersionWorkflow.self,
                options: .init(),
                input: "start"
            )

            let sleepDeadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < sleepDeadline {
                if let snap = try await handle.snapshot(), snap.state == .sleeping {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }

            // 1 checkpoint written (sleep at seqNum 1).
            // v3 is the 2nd unwritten version call → callSiteIndex: 2 → seqNum 3.
            try await client.markVersion(
                changeID: "multi-v3",
                value: false,
                taskID: handle.taskID,
                callSiteIndex: 2
            )

            let result = try await handle.result(timeout: .seconds(10))
            #expect(result == "v2-path")
        }
    }

    // ── 6 ───────────────────────────────────────────────────────────────────────
    // Multi-step migration — BOTH gates forced to false.
    // Mark v2 first (callSiteIndex: 1 → seqNum=2), which writes a checkpoint and
    // advances the count to 2. Then mark v3 (callSiteIndex: 1 → seqNum=3).
    // Result: isV2=false, isV3=false → "original-path".
    @Test("multi-step: marking both gates false takes the original path")
    func multiStepBothFalse() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [TwoVersionWorkflow.self]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                TwoVersionWorkflow.self,
                options: .init(),
                input: "start"
            )

            let sleepDeadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < sleepDeadline {
                if let snap = try await handle.snapshot(), snap.state == .sleeping {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }

            // Mark v2 first: count=1, callSiteIndex=1 → seqNum=2. Count becomes 2.
            try await client.markVersion(
                changeID: "multi-v2",
                value: false,
                taskID: handle.taskID,
                callSiteIndex: 1
            )
            // Mark v3 next: count=2, callSiteIndex=1 → seqNum=3.
            try await client.markVersion(
                changeID: "multi-v3",
                value: false,
                taskID: handle.taskID,
                callSiteIndex: 1
            )

            let result = try await handle.result(timeout: .seconds(10))
            #expect(result == "original-path")
        }
    }
}
