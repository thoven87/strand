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

// ── 1. AlwaysReady ───────────────────────────────────────────────────────────
// The predicate closure ignores state entirely (`{ _ in true }`), so the
// condition fast-path fires the moment `run` is entered — no stored property,
// no suspension, no signal required.
//
// Note: workflow structs must decode cleanly from the initial empty-object `{}`
// that the worker synthesises on the first activation. Non-optional stored
// properties like `var ready = true` would cause a `keyNotFound` decoding error
// because the synthesised `Decodable` init requires the key to be present.
// This fixture avoids the problem by having no stored state at all.
// Used by: conditionSatisfiedImmediately

private struct AlwaysReadyWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        try await context.condition { _ in true }
        return "done"
    }
}

// ── 2. Pauseable ─────────────────────────────────────────────────────────────
// `unpaused` is `Bool?` so it can be decoded from the initial empty-object `{}`
// (decodeIfPresent returns nil for a missing key). The "unpause" signal sets it
// to `true`; the predicate checks for an explicit `true` rather than truthiness
// so that a `nil` value is treated as "not yet unpaused".
// Used by: conditionBlocksThenSignalUnblocks

private struct PauseableWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    var unpaused: Bool?

    mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
        if name == "unpause" { unpaused = true }
    }

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        try await context.condition { $0.unpaused == true }
        return "unpaused"
    }
}

// ── 3. ConditionTimeout — no signal ─────────────────────────────────────────
// 600 ms deadline; no signal is ever sent, so the deadline passes and
// condition returns `false`. The workflow maps false → "timed-out".
// `unpaused` is `Bool?` for the same decoding reason as PauseableWorkflow.
// Used by: conditionWithTimeoutTimedOut

private struct ConditionTimeoutWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    var unpaused: Bool?

    mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
        if name == "unpause" { unpaused = true }
    }

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        let met = try await context.condition({ $0.unpaused == true }, timeout: .milliseconds(600))
        return met ? "unpaused" : "timed-out"
    }
}

// ── 4. ConditionTimeout — signal arrives ─────────────────────────────────────
// 10 s deadline; the test sends "unpause" after ~400 ms, well before the
// deadline, so the condition is satisfied and the workflow returns "unpaused".
// `unpaused` is `Bool?` for the same decoding reason as PauseableWorkflow.
// Used by: conditionWithTimeoutSignalArrives

private struct ConditionTimeoutSignalWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    var unpaused: Bool?

    mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
        if name == "unpause" { unpaused = true }
    }

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        let met = try await context.condition({ $0.unpaused == true }, timeout: .seconds(10))
        return met ? "unpaused" : "timed-out"
    }
}

// MARK: - Test suite

@Suite("Integration — Conditions", .tags(.integration), .serialized)
struct ConditionTests {

    // ── 1 ───────────────────────────────────────────────────────────────────
    // When the predicate is already `true` at the start of the first activation,
    // `condition(_:)` must return immediately without entering any suspension.
    @Test("condition already satisfied on entry returns without suspension")
    func conditionSatisfiedImmediately() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [AlwaysReadyWorkflow.self]
            ) {
                let handle = try await client.startWorkflow(
                    AlwaysReadyWorkflow.self,
                    options: .init(),
                    input: "start"
                )
                let result = try await handle.result(timeout: .seconds(10))
                #expect(result == "done")
            }
        }
    }

    // ── 2 ───────────────────────────────────────────────────────────────────
    // `condition(_:)` suspends the workflow (no timeout). The "unpause" signal
    // is sent while the workflow is waiting; on the next activation the predicate
    // evaluates to `true` and `run` proceeds to completion.
    @Test("condition suspends workflow and unblocks when the signal satisfies the predicate")
    func conditionBlocksThenSignalUnblocks() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [PauseableWorkflow.self]
            ) {
                let handle = try await client.startWorkflow(
                    PauseableWorkflow.self,
                    options: .init(),
                    input: "start"
                )

                // Wait until the workflow enters condition suspension (WAITING state).
                try await awaitSnapshot(handle, where: { $0.state == .waiting }, timeout: .seconds(5))

                // Deliver the signal that sets `unpaused = true`.
                try await handle.signal(name: "unpause")

                let result = try await handle.result(timeout: .seconds(10))
                #expect(result == "unpaused")
            }
        }
    }

    // ── 3 ───────────────────────────────────────────────────────────────────
    // `condition(_:timeout:)` with a 10 s deadline. The signal arrives ~400 ms
    // into the wait — well before the deadline — so the condition is satisfied
    // and the workflow returns "unpaused" (not "timed-out").
    @Test("condition with timeout unblocks when signal arrives before the deadline")
    func conditionWithTimeoutSignalArrives() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [ConditionTimeoutSignalWorkflow.self]
            ) {
                let handle = try await client.startWorkflow(
                    ConditionTimeoutSignalWorkflow.self,
                    options: .init(),
                    input: "start"
                )

                // Wait until the workflow enters condition suspension (SLEEPING/WAITING state).
                try await awaitSnapshot(
                    handle,
                    where: { $0.state == .waiting || $0.state == .sleeping },
                    timeout: .seconds(5)
                )

                // Send the signal — well within the 10 s deadline.
                try await handle.signal(name: "unpause")

                let result = try await handle.result(timeout: .seconds(15))
                #expect(result == "unpaused")
            }
        }
    }

    // ── 4 ───────────────────────────────────────────────────────────────────
    // `condition(_:timeout:)` with a 600 ms deadline. No signal is ever sent.
    // The timer fires, the predicate is still `false`, and condition returns `false`.
    // The workflow maps false → "timed-out" as output.
    @Test("condition with timeout returns false when deadline passes without a signal")
    func conditionWithTimeoutTimedOut() async throws {
        try await withTestEnvironment { client in
            try await withWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [ConditionTimeoutWorkflow.self]
            ) {
                let handle = try await client.startWorkflow(
                    ConditionTimeoutWorkflow.self,
                    options: .init(),
                    input: "start"
                )

                // No signal sent — the 600 ms deadline will elapse, causing
                // the workflow to catch StrandError.timeout and return "timed-out".
                let result = try await handle.result(timeout: .seconds(15))
                #expect(result == "timed-out")
            }
        }
    }
}
