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

// MARK: - Activity fixtures

private struct UppercaseActivity: Activity {
    typealias Input = String
    typealias Output = String
    func run(input: String, context: ActivityContext) async throws -> String {
        input.uppercased()
    }
}

private struct AddOneActivity: Activity {
    typealias Input = Int
    typealias Output = Int
    func run(input: Int, context: ActivityContext) async throws -> Int {
        input + 1
    }
}

private struct FailingLocalActivity: Activity {
    typealias Input = String
    typealias Output = String
    typealias Failure = LocalError
    struct LocalError: Error, Codable, Sendable {}
    func run(input: String, context: ActivityContext) async throws -> String {
        throw LocalError()
    }
}

// MARK: - Workflow fixtures

// Calls a single local activity and returns the result.
private struct LocalUpperWorkflow: Workflow {
    typealias Input = String
    typealias Output = String
    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        try await context.runLocalActivity(UppercaseActivity.self, input: input)
    }
}

// Chains two local activities: uppercase then append "!".
private struct LocalChainWorkflow: Workflow {
    typealias Input = String
    typealias Output = String
    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        let upper = try await context.runLocalActivity(UppercaseActivity.self, input: input)
        let count = try await context.runLocalActivity(AddOneActivity.self, input: upper.count)
        return "\(upper)(\(count))"
    }
}

// Mixes a local activity with a regular activity.
private struct MixedWorkflow: Workflow {
    typealias Input = String
    typealias Output = String
    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        // Local: runs in-process within this activation
        let upper = try await context.runLocalActivity(UppercaseActivity.self, input: input)
        // Regular: dispatched via DB queue to an activity worker slot
        let reversed = try await context.runActivity(ReverseLocalActivity.self, input: upper)
        return reversed
    }
}

// Simple regular activity used by MixedWorkflow.
private struct ReverseLocalActivity: Activity {
    typealias Input = String
    typealias Output = String
    var onRan: (@Sendable () -> Void)?
    func run(input: String, context: ActivityContext) async throws -> String {
        let result = String(input.reversed())
        onRan?()
        return result
    }
}

// Workflow whose local activity always fails — the activation should fail.
private struct FailLocalWorkflow: Workflow {
    typealias Input = String
    typealias Output = String
    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        try await context.runLocalActivity(FailingLocalActivity.self, input: input)
    }
}

// MARK: - Test suite

@Suite("Integration — Local activities", .tags(.integration), .serialized)
struct LocalActivityTests {

    // ── 1 ───────────────────────────────────────────────────────────────────
    // A single local activity executes in-process within the same activation,
    // checkpoints its result, and the workflow completes in one round-trip.
    @Test("local activity executes in-process and returns the correct result")
    func singleLocalActivity() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [LocalUpperWorkflow.self],
                activities: [UppercaseActivity()]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                LocalUpperWorkflow.self,
                options: .init(),
                input: "hello"
            )
            let result = try await handle.result(timeout: .seconds(10))
            #expect(result == "HELLO")
        }
    }

    // ── 2 ───────────────────────────────────────────────────────────────────
    // Two local activities run sequentially within the same activation.
    // The second sees the result of the first without any DB round-trip.
    @Test("chained local activities execute sequentially in one activation")
    func chainedLocalActivities() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [LocalChainWorkflow.self],
                activities: [UppercaseActivity(), AddOneActivity()]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                LocalChainWorkflow.self,
                options: .init(),
                input: "hi"
            )
            // "hi" → uppercase → "HI" (len 2) → AddOne → 3 → "HI(3)"
            let result = try await handle.result(timeout: .seconds(10))
            #expect(result == "HI(3)")
        }
    }

    // ── 3 ───────────────────────────────────────────────────────────────────
    // A local activity can be mixed with a regular queued activity in the same
    // workflow. The local one runs in-process; the regular one goes through the
    // normal DB → queue → worker path.
    @Test("local and regular activities can be mixed in the same workflow")
    func mixedLocalAndRegularActivity() async throws {
        try await withTestEnvironment { client in
            try await confirmation("ReverseLocalActivity ran") { confirm in
                let workerTask = startWorker(
                    postgres: client.postgres,
                    queueName: client.queueName,
                    logger: client.logger,
                    workflows: [MixedWorkflow.self],
                    activities: [UppercaseActivity(), ReverseLocalActivity(onRan: { confirm() })]
                )
                defer { workerTask.cancel() }

                let handle = try await client.startWorkflow(
                    MixedWorkflow.self,
                    options: .init(),
                    input: "abc"
                )
                // "abc" → local uppercase → "ABC" → regular reverse → "CBA".
                // awaitTerminal guarantees the activity completed before we return,
                // so confirmation will see exactly 1 call to confirm().
                let snap = try await awaitTerminal(
                    client: client,
                    taskID: handle.taskID,
                    timeout: .seconds(30)
                )
                #expect(snap.state == .completed)
                let result = try snap.decodeResult(as: String.self)
                #expect(result == "CBA")
            }
        }
    }

    // ── 4 ───────────────────────────────────────────────────────────────────
    // If a local activity throws, the whole activation fails (no retry).
    // The workflow task transitions to FAILED.
    @Test("a throwing local activity fails the whole activation")
    func failingLocalActivity() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [FailLocalWorkflow.self],
                activities: [FailingLocalActivity()]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                FailLocalWorkflow.self,
                options: .init(),
                input: "trigger"
            )
            let snap = try await awaitTerminal(
                client: client,
                taskID: handle.taskID,
                timeout: .seconds(10)
            )
            #expect(snap.state == .failed)
        }
    }
}
