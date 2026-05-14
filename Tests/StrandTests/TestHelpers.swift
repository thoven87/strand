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

// MARK: - TestExpectation

/// Push-based test synchronisation using `AsyncStream`.
///
/// Pass an instance to an activity or workflow, call `trigger()` from inside
/// the running code, and `wait()` in the test. Unlike polling with
/// `Task.sleep`, completion is signalled the instant `trigger()` is called —
/// no fixed delay and no 2-second backoff window.
///
/// ```swift
/// private struct MyActivity: Activity {
///     let done: TestExpectation
///     func run(input: String, context: ActivityContext) async throws -> String {
///         defer { done.trigger() }
///         return input.uppercased()
///     }
/// }
///
/// // In the test:
/// let done = TestExpectation()
/// startWorker(..., activities: [MyActivity(done: done)])
/// try await done.wait(for: "MyActivity", timeout: .seconds(10))
/// ```
struct TestExpectation: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (self.stream, self.continuation) = AsyncStream<Void>.makeStream()
    }

    /// Signal that one unit of work completed.
    func trigger() {
        continuation.yield()
    }

    /// Await `count` triggers or throw after `timeout` elapses.
    func wait(
        for label: String? = nil,
        count: Int = 1,
        timeout: Duration = .seconds(10)
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = self.stream.makeAsyncIterator()
                for _ in 0..<count {
                    await iterator.next()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                let msg = label.map { "timed out waiting on \($0)" } ?? "timed out"
                throw IntegrationError(msg)
            }
            try await group.next()!
            group.cancelAll()
        }
    }
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
        "t\(UUID().uuidString.replacing("-", with: "").prefix(12).lowercased())"
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

    // ── Stale-queue sweep ─────────────────────────────────────────────────
    // Test queues follow the pattern "t" + 12 lowercase hex chars.  If a
    // previous `swift test` run was killed (^C, crash, timeout) before its
    // withTestEnvironment cleanup ran, those queues accumulate tasks in the
    // dev DB — especially scheduler tests whose StrandScheduler keeps firing
    // every second until the connection pool eventually collapses.
    //
    // On every new test environment we sweep queues matching the pattern that
    // are older than 30 minutes, deleting schedules, tasks, and the queue row.
    // 30 min is well above the longest single test suite runtime (~10 min) so
    // concurrent test runs on slow CI machines won’t accidentally nuke each other.
    _ = try await postgres.query(
        """
        DO $$
        DECLARE q TEXT;
        BEGIN
          FOR q IN
            SELECT name FROM strand.queues
            WHERE name ~ '^t[0-9a-f]{12}$'
              AND created_at < NOW() - INTERVAL '30 minutes'
          LOOP
            DELETE FROM strand.schedules   WHERE queue = q;
            DELETE FROM strand.events      WHERE queue = q;
            DELETE FROM strand.event_waits WHERE queue = q;
            DELETE FROM strand.tasks       WHERE queue = q;
            DELETE FROM strand.queues      WHERE name  = q;
          END LOOP;
        END;
        $$
        """,
        logger: logger
    )

    try await client.createQueue(queueName)

    // Shared teardown: remove all test artefacts so they don't accumulate in
    // the dev DB and confuse the dashboard or DevServer.
    //
    // Schedules are deleted first — a live schedule can fire new tasks while
    // older tasks are still being deleted. Errors are thrown, not swallowed:
    // a silently-failed cleanup leaves active schedules that StrandScheduler
    // will keep firing long after the test has finished.
    func cleanup() async {
        do {
            try await postgres.query(
                "DELETE FROM strand.schedules   WHERE queue = \(queueName)",
                logger: logger
            )
            try await postgres.query(
                "DELETE FROM strand.events      WHERE queue = \(queueName)",
                logger: logger
            )
            try await postgres.query(
                "DELETE FROM strand.event_waits WHERE queue = \(queueName)",
                logger: logger
            )
            try await postgres.query(
                "DELETE FROM strand.tasks       WHERE queue = \(queueName)",
                logger: logger
            )
            try await client.dropQueue(queueName)
        } catch {
            logger.error(
                "[TestHelpers] cleanup failed — manually run: DELETE FROM strand.schedules WHERE queue = '\(queueName)'",
                metadata: .forError(error)
            )
        }
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
    // Each test worker gets its own StrandNotifier so tests remain independent.
    // The notifier and worker run concurrently inside the same Task; cancelling
    // the returned task shuts down both.
    Task {
        let notifier = StrandNotifier(
            postgres: postgres,
            channels: [StrandNotifier.tasksChannel],
            logger: logger
        )
        let worker = StrandWorker(
            postgres: postgres,
            options: WorkerOptions(
                queue: queueName,
                workflowConcurrency: concurrency,
                activityConcurrency: concurrency * 2,
                pollInterval: .milliseconds(20),
                fatalOnLeaseTimeout: false,
                // No jitter in tests: single worker per queue, no thundering herd,
                // and jitter would add up to 50 ms latency per task step.
                notifyJitter: .zero
            ),
            notifier: notifier,
            workflows: workflows,
            activityContainers: activityContainers,
            activities: activities,
            logger: logger,
            metricsFactory: metricsFactory
        )
        try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await notifier.run() }
            group.addTask { try await worker.run() }
            try await group.next()
            group.cancelAll()
        }
    }
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
