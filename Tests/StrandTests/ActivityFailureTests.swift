import Logging
import NIOCore
import PostgresNIO
import Synchronization
import Testing

@testable import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Activity definition (always fails)
//
// Regression: previously, a workflow calling context.runActivity() would permanently
// deadlock (stuck in SLEEPING/WAITING) when the activity exhausted all its retry
// attempts.  Root cause: loadCompletedChildActivities only included
// tc.state = 'COMPLETED', so FAILED activities were invisible to the executor's
// fast path.  The workflow re-activated, missed the FAILED activity, registered a
// new event_wait AFTER the completion signal had already fired, and hung forever.
//
// Fix: loadCompletedChildActivities now includes state IN ('COMPLETED','FAILED',
// 'CANCELLED') and routes non-success states into preloadedNonCompletions, which
// runActivity checks in fast path 2a and immediately throws ActivityError.

/// An activity that unconditionally throws on every attempt.
/// Used to exercise the FAILED activity fast-path without waiting for retries.
private struct AlwaysFailingActivity: ActivityDefinition {
    typealias Input = String
    typealias Output = String

    static let name = "always-failing-activity-regression"

    func run(input: String, context: ActivityContext) async throws -> String {
        throw AlwaysFailingError(attempt: context.attempt)
    }
}

private struct AlwaysFailingError: Error, CustomStringConvertible {
    let attempt: Int
    var description: String { "unconditional failure on attempt \(attempt)" }
}

// MARK: - Workflow: catches ActivityError and compensates

/// Invokes AlwaysFailingActivity with maxAttempts: 1 so it exhausts retries
/// in one attempt, then catches ActivityError and returns a known sentinel
/// value.  The workflow should finish in state .completed.
private struct CatchingActivityFailureWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        do {
            return try await context.runActivity(
                AlwaysFailingActivity.self,
                input: input,
                options: .init(maxAttempts: 1, retryStrategy: .constant(.zero))
            )
        } catch is ActivityError {
            // Compensating path: activity exhausted all retries; acknowledge
            // and return a stable sentinel so the test can verify we got here.
            return "compensated"
        }
    }
}

// MARK: - Workflow: does NOT catch ActivityError

/// Invokes AlwaysFailingActivity with maxAttempts: 1 and lets the resulting
/// ActivityError propagate unhandled.  The workflow itself should
/// reach state .failed (not deadlock in .sleeping or .waiting).
private struct PropagatingActivityFailureWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        // Deliberately no catch — the error should propagate and fail the workflow.
        try await context.runActivity(
            AlwaysFailingActivity.self,
            input: input,
            options: .init(maxAttempts: 1, retryStrategy: .constant(.zero))
        )
    }
}

// MARK: - Test suite

@Suite("Integration — Activity failure handling", .tags(.integration), .serialized)
struct ActivityFailureTests {

    // ── Test 1: caught failure ────────────────────────────────────────────────

    @Test("activity that exhausts all attempts is caught by workflow and workflow completes")
    func activityCaughtAndWorkflowCompletes() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [CatchingActivityFailureWorkflow.self],
                activities: [AlwaysFailingActivity()]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                CatchingActivityFailureWorkflow.self,
                options: .init(),
                input: "go"
            )

            // If the regression were still present the workflow would hang
            // in SLEEPING and handle.result() would throw StrandError.timeout.
            let result = try await handle.result(timeout: .seconds(15))

            #expect(result == "compensated")
        }
    }

    // ── Test 2: uncaught failure ──────────────────────────────────────────────

    @Test("activity that exhausts all attempts propagates as ActivityError when uncaught")
    func activityUncaughtCausesWorkflowToFail() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [PropagatingActivityFailureWorkflow.self],
                activities: [AlwaysFailingActivity()]
            )
            defer { workerTask.cancel() }

            // maxAttempts: 1 on the workflow prevents multiple workflow-level
            // retries so the test reaches .failed quickly.
            let handle = try await client.startWorkflow(
                PropagatingActivityFailureWorkflow.self,
                options: .init(maxAttempts: 1),
                input: "go"
            )

            // If the regression were still present the workflow would hang in
            // SLEEPING and awaitTerminal would throw IntegrationError (timeout).
            let snap = try await awaitTerminal(
                client: client,
                taskID: handle.taskID,
                timeout: .seconds(15)
            )

            #expect(snap.state == .failed)
        }
    }
}
