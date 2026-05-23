public import Logging  // Logger in public function signatures
public import Metrics  // MetricsFactory in withWorker signature
public import PostgresNIO  // PostgresClient in public function signatures
import ServiceLifecycle
public import Strand
import Synchronization

#if canImport(FoundationEssentials)
public import FoundationEssentials  // UUID in awaitSnapshot / awaitTerminal
#else
public import Foundation
#endif

// MARK: - StrandTestError

/// Thrown by test helpers when a timeout or unexpected condition occurs.
public struct StrandTestError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ message: String) { self.description = message }
}

// MARK: - TestExpectation

/// Push-based test synchronisation using `AsyncStream`.
///
/// Pass an instance to an activity or workflow, call ``trigger()`` from inside
/// the running code, and ``wait(for:count:timeout:)`` in the test body.
///
/// ```swift
/// struct MyActivity: Activity {
///     let done: TestExpectation
///     func run(input: String, context: ActivityContext) async throws -> String {
///         defer { done.trigger() }
///         return input.uppercased()
///     }
/// }
///
/// let done = TestExpectation()
/// try await withWorker(postgres: client.postgres, queueName: client.queueName,
///                      logger: client.logger, activities: [MyActivity(done: done)]) {
///     try await client.enqueueActivity(MyActivity.self, input: "hello")
///     try await done.wait(for: "MyActivity")
/// }
/// ```
public struct TestExpectation: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    public init() {
        (self.stream, self.continuation) = AsyncStream<Void>.makeStream()
    }

    /// Signal that one unit of work completed.
    public func trigger() {
        continuation.yield()
    }

    /// Await `count` triggers or throw ``StrandTestError`` after `timeout` elapses.
    public func wait(
        for label: String? = nil,
        count: Int = 1,
        timeout: Duration = .seconds(10)
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = self.stream.makeAsyncIterator()
                for _ in 0..<count { await iterator.next() }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw StrandTestError(label.map { "timed out waiting on \($0)" } ?? "timed out")
            }
            try await group.next()!
            group.cancelAll()
        }
    }
}

// MARK: - makePostgresClient

/// Builds a ``PostgresClient`` from environment variables, falling back to
/// sensible local-dev defaults.
///
/// | Variable | Default |
/// |---|---|
/// | `POSTGRES_HOST` | `localhost` |
/// | `POSTGRES_PORT` | `5499` |
/// | `POSTGRES_USER` | `strand` |
/// | `POSTGRES_PASSWORD` | `strand` |
/// | `POSTGRES_DB` | `strand_dev` |
public func makePostgresClient(logger: Logger) -> PostgresClient {
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

// MARK: - withTestEnvironment

/// Creates a fresh randomly-named queue, runs `work`, then deletes all test
/// artefacts regardless of success or failure.
///
/// ```swift
/// @Test func myWorkflow() async throws {
///     try await withTestEnvironment { client in
///         try await withWorker(
///             postgres: client.postgres,
///             queueName: client.queueName,
///             logger: client.logger,
///             workflows: [MyWorkflow.self]
///         ) {
///             let handle = try await client.startWorkflow(MyWorkflow.self, input: .init())
///             let snap = try await awaitTerminal(client: client, taskID: handle.taskID)
///             #expect(snap.state == .completed)
///         }
///     }
/// }
/// ```
public func withTestEnvironment<T: Sendable>(
    _ work: @Sendable (StrandClient) async throws -> T
) async throws -> T {
    let logger = Logger(label: "test.strand")
    let queueName = "t\(UUID().uuidString.replacing("-", with: "").prefix(12).lowercased())"
    let postgres = makePostgresClient(logger: logger)
    let client = StrandClient(postgres: postgres, queue: queueName, logger: logger)

    let pgTask = Task { await postgres.run() }
    defer { pgTask.cancel() }

    try await Task.sleep(for: .milliseconds(100))
    try await client.verifySchema()

    // Sweep stale test queues (pattern "t" + 12 hex chars, older than 30 min).
    // Prevents accumulation from killed test runs, especially scheduler tests
    // that keep firing until the connection pool collapses.
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
            DELETE FROM strand.runs        WHERE task_id IN (SELECT id FROM strand.tasks WHERE queue = q);
            DELETE FROM strand.tasks       WHERE queue = q;
            DELETE FROM strand.queues      WHERE name  = q;
          END LOOP;
        END;
        $$
        """,
        logger: logger
    )

    try await client.createQueue(queueName)

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
            // strand.runs has no FK cascade to strand.tasks, so orphaned run rows
            // accumulate and cause full seq-scans in shutdownWorker. Delete runs
            // before tasks (tasks deletion order doesn't matter — no FK between them).
            try await postgres.query(
                "DELETE FROM strand.runs WHERE task_id IN (SELECT id FROM strand.tasks WHERE queue = \(queueName))",
                logger: logger
            )
            try await postgres.query(
                "DELETE FROM strand.tasks       WHERE queue = \(queueName)",
                logger: logger
            )
            try await client.dropQueue(queueName)
        } catch {
            logger.error(
                "[StrandTesting] cleanup failed",
                metadata: ["queue": "\(queueName)", "error": "\(error)"]
            )
        }
    }

    do {
        let result = try await work(client)
        await cleanup()
        return result
    } catch {
        await cleanup()
        throw error
    }
}

// MARK: - withWorker

/// Runs a ``StrandWorker`` for the duration of `work`, then gracefully shuts
/// it down before returning.
///
/// The worker and notifier run inside a `ServiceGroup` owned by a
/// `withThrowingTaskGroup`. When `work` completes (success or error)
/// `triggerGracefulShutdown()` is called and the group awaits
/// `serviceGroup.run()` before returning — the worker is fully stopped
/// before ``withTestEnvironment(_:)`` runs its cleanup, eliminating FK races
/// on `strand_tasks_queue_fk`.
///
/// ```swift
/// try await withTestEnvironment { client in
///     try await withWorker(
///         postgres: client.postgres,
///         queueName: client.queueName,
///         logger: client.logger,
///         workflows: [OrderWorkflow.self],
///         activities: [ChargeCardActivity()]
///     ) {
///         // test body — worker is running here
///     }
/// }
/// ```
@discardableResult
public func withWorker<T: Sendable>(
    postgres: PostgresClient,
    queueName: String,
    logger: Logger,
    concurrency: Int = 4,
    workflows: [any Workflow.Type] = [],
    activityContainers: [any ActivityContainerProtocol] = [],
    activities: [any Activity] = [],
    metricsFactory: (any MetricsFactory)? = nil,
    _ work: @Sendable () async throws -> T
) async throws -> T {
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
            notifyJitter: .zero
        ),
        notifier: notifier,
        workflows: workflows,
        activityContainers: activityContainers,
        activities: activities,
        logger: logger,
        metricsFactory: metricsFactory
    )
    return try await withThrowingTaskGroup(of: Void.self) { group in
        let serviceGroup = ServiceGroup(
            configuration: .init(
                services: [notifier, worker],
                gracefulShutdownSignals: [],
                logger: logger
            )
        )
        group.addTask { try await serviceGroup.run() }
        do {
            let result = try await work()
            await serviceGroup.triggerGracefulShutdown()
            return result
        } catch {
            await serviceGroup.triggerGracefulShutdown()
            throw error
        }
    }
}

// MARK: - withScheduler

/// Runs a ``StrandScheduler`` for the duration of `work`, then gracefully shuts
/// it down before returning — same lifecycle guarantee as ``withWorker``.
///
/// ```swift
/// try await withTestEnvironment { client in
///     let scheduler = StrandScheduler(client: client, ...)
///     try await withScheduler(scheduler, logger: client.logger) {
///         try await awaitScheduleRunCount(client: client, scheduleName: "my-schedule")
///     }
/// }
/// ```
@discardableResult
public func withScheduler<T: Sendable>(
    _ scheduler: StrandScheduler,
    logger: Logger,
    _ work: @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: Void.self) { group in
        let serviceGroup = ServiceGroup(
            configuration: .init(
                services: [scheduler],
                gracefulShutdownSignals: [],
                logger: logger
            )
        )
        group.addTask { try await serviceGroup.run() }
        do {
            let result = try await work()
            await serviceGroup.triggerGracefulShutdown()
            return result
        } catch {
            await serviceGroup.triggerGracefulShutdown()
            throw error
        }
    }
}

// MARK: - awaitSnapshot

/// Polls `fetchTaskResult` until the snapshot satisfies `predicate`, or
/// throws ``StrandTestError`` on `timeout`.
///
/// ```swift
/// // Wait until the workflow suspends on a timer:
/// try await awaitSnapshot(client: client, taskID: handle.taskID,
///                         where: { $0.state == .sleeping }, label: "workflow SLEEPING")
///
/// // Wait for RUNNING state AND an external gate:
/// try await awaitSnapshot(client: client, taskID: enq.taskID,
///                         where: { $0.state == .running && counter.value >= 1 })
/// ```
@discardableResult
public func awaitSnapshot(
    client: StrandClient,
    taskID: UUID,
    where predicate: (TaskResultSnapshot) -> Bool,
    timeout: Duration = .seconds(10),
    label: String? = nil
) async throws -> TaskResultSnapshot {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let snap = try await client.fetchTaskResult(id: taskID), predicate(snap) {
            return snap
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw StrandTestError(
        label.map { "timed out waiting for: \($0)" }
            ?? "snapshot predicate not satisfied for \(taskID) within \(timeout)"
    )
}

/// Convenience overload for typed ``WorkflowHandle``.
@discardableResult
public func awaitSnapshot<W: Workflow>(
    _ handle: WorkflowHandle<W>,
    where predicate: (TaskResultSnapshot) -> Bool,
    timeout: Duration = .seconds(10),
    label: String? = nil
) async throws -> TaskResultSnapshot {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let snap = try await handle.snapshot(), predicate(snap) { return snap }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw StrandTestError(
        label.map { "timed out waiting for: \($0)" }
            ?? "snapshot predicate not satisfied for \(handle.taskID) within \(timeout)"
    )
}

// MARK: - awaitScheduleRunCount

/// Polls `listSchedules` until schedule `scheduleName` has fired at least
/// `minCount` times, or throws ``StrandTestError`` on `timeout`.
public func awaitScheduleRunCount(
    client: StrandClient,
    scheduleName: String,
    atLeast minCount: Int = 1,
    timeout: Duration = .seconds(10)
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let list = try await client.listSchedules(queue: client.queueName)
        if (list.first(where: { $0.name == scheduleName })?.runCount ?? 0) >= minCount { return }
        try await Task.sleep(for: .milliseconds(200))
    }
    throw StrandTestError(
        "schedule '\(scheduleName)' did not fire \(minCount) time(s) within \(timeout)"
    )
}

// MARK: - awaitAnyTask

/// Polls `listTasks` until at least one task named `taskName` in the client's
/// queue has reached `state`, or throws ``StrandTestError`` on `timeout`.
///
/// Useful when `continueAsNew` creates independent new tasks whose IDs are
/// unknown at test time — poll by name and target state instead of task ID.
///
/// ```swift
/// // Wait for the terminal ContinueWorkflow generation to complete
/// try await awaitAnyTask(client: client, taskName: "ContinueWorkflow",
///                        state: .completed, timeout: .seconds(15))
/// ```
public func awaitAnyTask(
    client: StrandClient,
    taskName: String,
    state: TaskState,
    timeout: Duration = .seconds(10),
    label: String? = nil
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let stream = try await client.postgres.query(
            """
            SELECT 1 FROM strand.tasks
            WHERE namespace_id = \(client.namespaceID)
              AND queue        = \(client.queueName)
              AND name         = \(taskName)
              AND state        = \(state)
            LIMIT 1
            """,
            logger: client.logger
        )
        if (try await stream.first(where: { _ in true })) != nil { return }
        try await Task.sleep(for: .milliseconds(200))
    }
    throw StrandTestError(
        label ?? "no '\(taskName)' task reached state '\(state.rawValue)' within \(timeout)"
    )
}

// MARK: - awaitTerminal

/// Polls until `taskID` reaches a terminal state (completed / failed / cancelled)
/// or throws ``StrandTestError`` on `timeout`.
@discardableResult
public func awaitTerminal(
    client: StrandClient,
    taskID: UUID,
    timeout: Duration = .seconds(10)
) async throws -> TaskResultSnapshot {
    try await awaitSnapshot(
        client: client,
        taskID: taskID,
        where: { $0.state == .completed || $0.state == .failed || $0.state == .cancelled },
        timeout: timeout,
        label: "terminal state for \(taskID)"
    )
}
