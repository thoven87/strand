import Logging
import Metrics
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

// MARK: - Tag

extension Tag {
    @Tag static var integration: Self
}

// MARK: - Thread-safe test utilities

/// Thread-safe integer counter used to verify execution counts from workflow/activity handlers.
final class AtomicCounter: @unchecked Sendable {
    private let _value: Mutex<Int> = Mutex(0)
    var value: Int { _value.withLock { $0 } }
    func increment() { _value.withLock { $0 += 1 } }
}

/// Thread-safe single-value box used to compare values captured across separate activations.
final class AtomicInt: @unchecked Sendable {
    private let _value: Mutex<Int> = Mutex(0)
    var value: Int { _value.withLock { $0 } }
    func store(_ v: Int) { _value.withLock { $0 = v } }
}

// MARK: - Test error types

struct IntegrationError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { self.description = msg }
}

// MARK: - Infrastructure helpers

/// Builds a `PostgresClient` from environment variables, falling back to sensible
/// local-dev defaults.
func makePostgresClient(logger: Logger) -> PostgresClient {
    let env = ProcessInfo.processInfo.environment
    return PostgresClient(
        configuration: .init(
            host: env["POSTGRES_HOST"] ?? "localhost",
            port: Int(env["POSTGRES_PORT"] ?? "5499") ?? 5499,
            username: env["POSTGRES_USER"] ?? "strand",
            password: env["POSTGRES_PASSWORD"] ?? "strand",
            database: env["POSTGRES_DB"] ?? "strand_dev",
            tls: .disable
        ),
        backgroundLogger: logger
    )
}

/// Spins up a Postgres connection, creates a fresh randomly-named queue,
/// calls `work`, then drops the queue regardless of success or failure.
func withTestEnvironment<T: Sendable>(
    _ work: @Sendable (StrandClient) async throws -> T
) async throws -> T {
    let logger = Logger(label: "test.strand")
    let queueName =
        "t\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())"
    let postgres = makePostgresClient(logger: logger)
    let client = StrandClient(
        postgres: postgres,
        queue: queueName,
        logger: logger
    )

    let pgTask = Task { await postgres.run() }
    defer { pgTask.cancel() }

    try await Task.sleep(for: .milliseconds(100))
    try await client.verifySchema()
    try await client.createQueue(queueName)

    // Shared teardown: remove all test artefacts so they don't appear in the
    // dev dashboard when the DB is shared between tests and DevServer.
    // Deleting tasks cascades to runs, checkpoints, workflow_history,
    // workflow_state, workflow_signals, and task_completions via ON DELETE CASCADE.
    // Events and event_waits are not FK-linked so we delete them explicitly.
    func cleanup() async {
        _ = try? await postgres.query(
            "DELETE FROM strand.tasks       WHERE queue = \(queueName)",
            logger: logger
        )
        _ = try? await postgres.query(
            "DELETE FROM strand.events      WHERE queue = \(queueName)",
            logger: logger
        )
        _ = try? await postgres.query(
            "DELETE FROM strand.event_waits WHERE queue = \(queueName)",
            logger: logger
        )
        try? await client.dropQueue(queueName)
    }

    do {
        let result = try await work(client)
        await cleanup()
        return result
    } catch {
        logger.error("test environment error: \(String(reflecting: error))")
        await cleanup()
        throw error
    }
}

/// Launches a `StrandWorker` in a background `Task`.  Cancel the returned task
/// to stop the worker.
func startWorker(
    postgres: PostgresClient,
    queueName: String,
    logger: Logger,
    concurrency: Int = 4,
    workflows: [any WorkflowRegistrable.Type] = [],
    activityContainers: [any ActivityContainerProtocol] = [],
    activities: [any ActivityBox] = [],
    metricsFactory: (any MetricsFactory)? = nil
) -> Task<Void, Never> {
    let worker = StrandWorker(
        postgres: postgres,
        options: WorkerOptions(
            queue: queueName,
            workflowConcurrency: concurrency,
            activityConcurrency: concurrency * 2,
            pollInterval: .milliseconds(20),
            fatalOnLeaseTimeout: false
        ),
        workflows: workflows,
        activityContainers: activityContainers,
        activities: activities,
        logger: logger,
        metricsFactory: metricsFactory
    )
    return Task { try? await worker.run() }
}

/// Polls `fetchTaskResult` until the task reaches a terminal state or `timeout` elapses.
func awaitTerminal(
    client: StrandClient,
    taskID: UUID,
    timeout: Duration = .seconds(10)
) async throws -> TaskResultSnapshot {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let snap = try await client.fetchTaskResult(id: taskID),
            snap.state == .completed || snap.state == .failed || snap.state == .cancelled
        {
            return snap
        }
        try await Task.sleep(for: .milliseconds(80))
    }
    throw IntegrationError("task \(taskID) did not reach terminal state within \(timeout)")
}
