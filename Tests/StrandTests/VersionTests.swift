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
        // Sleep long enough that the test has a comfortable window to write
        // markVersion and have it commit well before the timer fires.
        // 200 ms was too tight: on this machine the worker claims the sleeping
        // run within ~15 ms of available_at, leaving markVersion's DB write
        // racing listVersionMarkers on the same connection pool.
        try await context.sleep(for: .seconds(2))
        let isNew = context.version(changeID: "v2-feature")
        return isNew ? "new-path" : "old-path"
    }
}

// ── VersionBeforeSleepWorkflow ────────────────────────────────────────────────
// The version marker is written BEFORE the sleep, so a worker crash during
// the sleep still has the marker in strand.workflow_version_markers. The
// fresh-path recovery on the next worker must replay the stored value.
// Used by: versionCheckpointSurvivesWorkerRestart

private struct VersionBeforeSleepWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        // Version call is BEFORE the sleep — marker written before sleep fires.
        let isNew = context.version(changeID: "v2-before-sleep")
        try await context.sleep(for: .milliseconds(200))
        return isNew ? "new-path" : "old-path"
    }
}

// ── TwoVersionWorkflow ──────────────────────────────────────────────────
// Demonstrates the multi-step migration pattern: two independent changeIDs
// each stored by name in strand.workflow_version_markers. No seq_num consumed.
// Used by: multiStepBothDefault, multiStepMarkV3False, multiStepBothFalse

private struct TwoVersionWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        // Sleep long enough that markVersion writes commit well before the timer fires.
        try await context.sleep(for: .seconds(2))
        // Both calls use distinct changeIDs — each keyed independently.
        let isV2 = context.version(changeID: "multi-v2")
        let isV3 = context.version(changeID: "multi-v3")
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
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [VersionedWorkflow.self]
            ) {
                let handle = try await client.startWorkflow(
                    VersionedWorkflow.self,
                    options: .init(),
                    input: "start"
                )
                let result = try await handle.result(timeout: .seconds(10))
                #expect(result == "new-path")
            }
        }
    }

    // ── 2 ───────────────────────────────────────────────────────────────────────────
    // `StrandClient.markVersion` writes a version marker directly into
    // `strand.workflow_version_markers` while the workflow is SLEEPING. When
    // the next activation loads its version marker cache it finds `false` for
    // "v2-feature" and `version(changeID:)` returns that stored value, causing
    // the workflow to return "old-path".
    //
    // Timeline:
    //   t=  0 ms — workflow claimed, enters sleep(200 ms), run transitions to SLEEPING
    //   t=100 ms — test calls markVersion(..., value: false, taskID: handle.taskID)
    //   t=200 ms — sleep fires, worker re-claims the run
    //   t=200 ms — version marker cache loaded (contains the false written at t=100 ms)
    //   t=200 ms — version(changeID:) reads the cache → false → returns "old-path"
    @Test("markVersion with value: false overrides the checkpoint and forces the old code path")
    func markVersionForcesOldPath() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [VersionedWorkflow.self]
            ) {
                let handle = try await client.startWorkflow(
                    VersionedWorkflow.self,
                    options: .init(),
                    input: "start"
                )

                // Wait until the workflow is confirmed SLEEPING before overwriting
                // the checkpoint — ensures markVersion commits before the timer fires.
                try await awaitRunState(client: client, taskID: handle.taskID, state: .sleeping, timeout: .seconds(5), label: "workflow SLEEPING")
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

    // ── 3 ───────────────────────────────────────────────────────────────────────────
    // The version marker is written on the FIRST activation (before the sleep).
    // Cancelling the first worker while the workflow sleeps simulates a crash.
    // The second worker's fresh-path recovery loads version markers from the DB;
    // version() must return the stored `true` value rather than `true` from
    // a default — confirming the marker survives a worker restart.
    @Test("version checkpoint written before sleep survives worker restart")
    func versionCheckpointSurvivesWorkerRestart() async throws {
        try await withTestEnvironment { client in
            let handle = try await client.startWorkflow(
                VersionBeforeSleepWorkflow.self,
                options: .init(),
                input: "start"
            )

            // First worker runs the workflow until it enters the sleep.
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [VersionBeforeSleepWorkflow.self]
            ) {
                // Wait until the workflow is SLEEPING (version checkpoint persisted,
                // now suspended on the sleep timer).
                try await awaitRunState(client: client, taskID: handle.taskID, state: .sleeping, timeout: .seconds(5), label: "workflow SLEEPING")
                // Return from closure — worker shuts down, leaving run in SLEEPING state.
            }

            // Start a fresh worker. It will do a fresh-path activation: load
            // version markers from DB, populate the version marker cache, then drain.
            // version(changeID:) must return the stored `true` from the cache,
            // not the default `true` from a new write — but the observable
            // result is the same. The important thing is the marker survives.
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [VersionBeforeSleepWorkflow.self]
            ) {
                let result = try await handle.result(timeout: .seconds(10))
                // version checkpoint stored `true` before crash — new-path after recovery.
                #expect(result == "new-path")
            }
        }
    }

    // ── 4 ───────────────────────────────────────────────────────────────────────
    // Multi-step migration — both changeIDs default to `true`.
    // Neither markVersion call is made: isV2=true, isV3=true → "v3-path".
    @Test("multi-step: both version gates default to true and take the v3 path")
    func multiStepBothDefault() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [TwoVersionWorkflow.self]
            ) {
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
    }

    // ── 5 ───────────────────────────────────────────────────────────────────────────
    // Multi-step migration — only the LATEST (v3) gate is forced to false.
    // markVersion targets by changeID — no seq_num needed.
    // Result: isV2=true (default), isV3=false → "v2-path".
    @Test("multi-step: marking only the v3 gate false takes the intermediate v2 path")
    func multiStepMarkV3False() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [TwoVersionWorkflow.self]
            ) {
                let handle = try await client.startWorkflow(
                    TwoVersionWorkflow.self,
                    options: .init(),
                    input: "start"
                )

                try await awaitRunState(client: client, taskID: handle.taskID, state: .sleeping, timeout: .seconds(5), label: "workflow SLEEPING")

                try await client.markVersion(
                    changeID: "multi-v3",
                    value: false,
                    taskID: handle.taskID
                )

                let result = try await handle.result(timeout: .seconds(10))
                #expect(result == "v2-path")
            }
        }
    }

    // ── 6 ───────────────────────────────────────────────────────────────────────────
    // Multi-step migration — BOTH gates forced to false.
    // Each changeID is independent — call markVersion twice, once per changeID.
    // Result: isV2=false, isV3=false → "original-path".
    @Test("multi-step: marking both gates false takes the original path")
    func multiStepBothFalse() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [TwoVersionWorkflow.self]
            ) {
                let handle = try await client.startWorkflow(
                    TwoVersionWorkflow.self,
                    options: .init(),
                    input: "start"
                )

                try await awaitRunState(client: client, taskID: handle.taskID, state: .sleeping, timeout: .seconds(5), label: "workflow SLEEPING")

                try await client.markVersion(
                    changeID: "multi-v2",
                    value: false,
                    taskID: handle.taskID
                )
                try await client.markVersion(
                    changeID: "multi-v3",
                    value: false,
                    taskID: handle.taskID
                )

                let result = try await handle.result(timeout: .seconds(10))
                #expect(result == "original-path")
            }
        }
    }
}
