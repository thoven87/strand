public import Logging  // Logger appears in the public init signature
public import Metrics
import NIOCore
public import PostgresNIO  // PostgresClient appears in the public init signature
public import ServiceLifecycle  // Service conformance is part of the public API
import Synchronization
import Tracing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - _WorkerExec

/// Internal execution context passed from the worker to registered handlers.
///
/// Bundles all resources the handler needs to interact with Postgres and
/// resolve per-run configuration. Created once per `StrandWorker` and captured
/// by every registration closure, so a single allocation serves all runs on
/// that worker.
package struct _WorkerExec: Sendable {
    let postgres: PostgresClient
    let queue: String
    let namespace: String
    let logger: Logger
    let options: WorkerOptions
    /// Runners for local activities registered on this worker.
    /// Keyed by activity name; each closure executes the activity in-process.
    let localActivityLookup: [String: @Sendable (ByteBuffer, _WorkerExec, UUID?) async throws -> ByteBuffer]
}

// MARK: - WorkerOptions

/// Configuration for a ``StrandWorker`` instance.
///
/// All properties have sensible defaults; only override what you need:
///
/// ```swift
/// WorkerOptions(
///     queue: "orders",
///     workflowConcurrency: 8,
///     activityConcurrency: 16,
///     pollInterval: .milliseconds(100),
///     claimTimeout: .seconds(60)
/// )
/// ```
public struct WorkerOptions: Sendable {
    /// Queue this worker polls for tasks. Default: `"default"`.
    public var queue: String

    /// Namespace this worker operates in. Must match the namespace used by the
    /// clients that enqueue tasks. Default: `"default"`.
    public var namespace: String

    /// Stable identifier for this worker process. Defaults to `hostname:pid`.
    public var workerID: String?

    /// Maximum number of workflow runs executing concurrently on this worker.
    /// Default: `4`.
    public var workflowConcurrency: Int

    /// Maximum number of activity executions running concurrently on this worker.
    /// Default: `8`.
    public var activityConcurrency: Int

    /// Fallback poll interval used when the LISTEN/NOTIFY connection is briefly down
    /// (e.g. during the 1-second reconnect back-off in `listenLoop`), and for tasks
    /// that become PENDING via paths that do not send NOTIFY — SLEEPING timer fires
    /// and lease-expiry re-queues.
    ///
    /// With LISTEN/NOTIFY active this is a safety net, not the primary wakeup mechanism.
    /// Keeping it at a few seconds (rather than sub-100 ms) avoids unnecessary polling
    /// when the queue is genuinely idle.
    ///
    /// Default: `.seconds(5)` (matches `leaseExpiryInterval`).
    public var pollInterval: Duration

    /// Maximum time a claimed task may run per attempt before the in-process
    /// deadline poller cancels it and the lease expiry sweep re-queues it.
    ///
    /// Must be at least 10 seconds to avoid races between the claim poll and
    /// the lease expiry sweep. Tasks that need shorter deadlines should set
    /// `ActivityOptions.timeout` directly.
    ///
    /// Default: `.seconds(120)`.
    public var claimTimeout: Duration

    /// Override the claim batch size. `nil` uses `workflowConcurrency + activityConcurrency`.
    public var batchSize: Int?

    /// No-op, retained for API source-compatibility. Timeout enforcement
    /// uses a racing child task inside `withThrowingTaskGroup` in `runTask`.
    public var fatalOnLeaseTimeout: Bool

    /// How long the worker waits for in-flight tasks to finish after receiving a
    /// graceful-shutdown signal. Default: `.seconds(10)`.
    public var gracefulShutdownTimeout: Duration

    /// Interval between expired-lease sweep passes. Default: `.seconds(5)`.
    public var leaseExpiryInterval: Duration

    /// Maximum random delay applied **only** to NOTIFY wakeups before the worker
    /// issues a `claimTasks` query.
    ///
    /// When many workers share a queue, a single `pg_notify` wakes all of them
    /// simultaneously. Without jitter they all hit Postgres at once; `FOR UPDATE
    /// SKIP LOCKED` keeps correctness but the concurrent empty claims waste DB
    /// resources. Jitter spreads the herd across a window so only the first few
    /// workers to fire actually find tasks, and the rest skip the round-trip.
    ///
    /// With a jitter window of W ms and N workers, the average number of
    /// concurrent claims after one notification is:
    ///
    ///     concurrent_claims ≈ N / W_ms
    ///
    /// Keep this around 2–5 to avoid unnecessary DB load:
    ///
    /// - 1 worker: `.zero` (no overhead)
    /// - ~10 workers: `.milliseconds(20)` — ~2–3 concurrent claims
    /// - ~100 workers: `.milliseconds(100)` — ~2–3 concurrent claims
    /// - 300+ workers: `.milliseconds(300)` — ~2–3 concurrent claims
    ///
    /// Jitter is **not** applied to the fallback `pollInterval` wakeup — those
    /// are already staggered naturally because workers start at different times.
    ///
    /// Default: `.milliseconds(50)` — a safe default for most SaaS deployments;
    /// set to `.zero` for development or single-worker setups.
    public var notifyJitter: Duration

    /// Called on every poll error. When `nil`, errors are logged at `.error` level.
    public var onError: (@Sendable (any Error) async -> Void)?

    public init(
        queue: String = "default",
        namespace: String = "default",
        workerID: String? = nil,
        workflowConcurrency: Int = 4,
        activityConcurrency: Int = 8,
        pollInterval: Duration = .seconds(5),
        claimTimeout: Duration = .seconds(120),
        batchSize: Int? = nil,
        fatalOnLeaseTimeout: Bool = true,
        gracefulShutdownTimeout: Duration = .seconds(10),
        leaseExpiryInterval: Duration = .seconds(5),
        notifyJitter: Duration = .milliseconds(50),
        onError: (@Sendable (any Error) async -> Void)? = nil
    ) {
        self.queue = queue
        self.namespace = namespace
        self.workerID = workerID
        self.workflowConcurrency = workflowConcurrency
        self.activityConcurrency = activityConcurrency
        self.pollInterval = pollInterval
        self.claimTimeout = claimTimeout
        self.batchSize = batchSize
        self.fatalOnLeaseTimeout = fatalOnLeaseTimeout
        self.gracefulShutdownTimeout = gracefulShutdownTimeout
        self.leaseExpiryInterval = leaseExpiryInterval
        self.notifyJitter = notifyJitter
        self.onError = onError
    }
}

// MARK: - AnyRegistration

/// Type-erased handler entry stored in ``Registry``.
///
/// Returns a non-nil `ByteBuffer` when the run completed and produced a result,
/// or `nil` when a workflow activation suspended cleanly (DB already updated).
///
/// `fatalDeadline` is the per-task 2×-claimTimeout deadline created in `runTask`.
/// Activities forward it into their heartbeat closure so that a heartbeating
/// activity keeps the deadline alive as long as it is making progress.
/// Workflow activations ignore it (they are short-lived replays).
///
/// `_WorkerExec` is NOT in the signature — all closures capture the shared exec
/// from `StrandWorker.init` which carries `localActivityLookup`. Passing it as
/// a parameter would allocate a new `_WorkerExec` (including an empty Dictionary)
/// on every task claim even though every caller ignores the parameter.
struct AnyRegistration: Sendable {
    let name: String
    let queueName: String
    let run: @Sendable (ClaimedTask, TaskDeadline) async throws -> ByteBuffer?
}

// MARK: - StrandWorker

/// A `Service`-conformant worker that drives the poll-claim-execute loop for one Postgres queue.
///
/// Register workflows by metatype and activities as instances or via containers:
///
/// ```swift
/// let worker = StrandWorker(
///     postgres: postgres,
///     options: .init(queue: "orders", workflowConcurrency: 4, activityConcurrency: 8),
///     workflows: [OrderWorkflow.self, FulfillmentWorkflow.self],
///     activityContainers: [PaymentActivities(stripe: stripe)],
///     activities: [NotificationActivity()]
/// )
///
/// let group = ServiceGroup(
///     configuration: .init(
///         services: [.init(service: postgres), .init(service: worker)],
///         gracefulShutdownSignals: [.sigterm, .sigint],
///         logger: logger
///     )
/// )
/// try await group.run()
/// ```
/// Wraps `any MetricsFactory` so it can be stored as a `let` on `StrandWorker`.
/// `MetricsFactory` inherits `Sendable` via `_SwiftMetricsSendableProtocol`, so
/// `any MetricsFactory` is `Sendable` and the compiler synthesises conformance
/// for this struct automatically — no `@unchecked` needed.
private struct _MetricsFactoryBox: Sendable {
    let value: any MetricsFactory
}

public struct StrandWorker: Service {
    private let postgres: PostgresClient
    private let options: WorkerOptions
    /// The namespace this worker operates in (mirrors `namespace`).
    /// Stored as a top-level field to avoid `namespace` at every call site.
    private let namespace: String
    /// Metrics backend. Defaults to the globally bootstrapped `MetricsSystem.factory`.
    /// Pass a test factory in tests to capture metrics without touching the global system.
    private let _metrics: _MetricsFactoryBox
    /// Logger for this worker instance.
    private let logger: Logger
    /// `Sendable` handler registry — a class reference whose `let` store is
    /// data-race free by construction (written once in `init`, never mutated).
    private let _registry: Registry
    /// Shared LISTEN/NOTIFY hub.  The worker subscribes to `strand_tasks`
    /// via the notifier's `AsyncStream` — no separate Postgres connection
    /// is opened.  The notifier must declare ``StrandChannels/tasks`` in its
    /// `channels` set.
    let notifier: StrandNotifier
    /// Optional shared timing buffer.  When set, the worker records each
    /// task's execution duration (in milliseconds) after every completion so
    /// ``StrandMetricsLoop`` can include DDSketch percentiles in its broadcast.
    private let metricsBuffer: AggregatedMetricsBuffer?

    /// Creates a worker with typed registration arrays.
    ///
    /// ```swift
    /// let worker = StrandWorker(
    ///     postgres: postgres,
    ///     options: WorkerOptions(queue: "orders", workflowConcurrency: 100),
    ///     workflows: [OrderWorkflow.self, FulfillmentWorkflow.self],
    ///     activityContainers: [PaymentActivities(stripe: stripe)],
    ///     activities: [NotificationActivity()]
    /// )
    /// ```
    public init(
        postgres: PostgresClient,
        options: WorkerOptions = .init(),
        notifier: StrandNotifier,
        metricsBuffer: AggregatedMetricsBuffer? = nil,
        workflows: [any WorkflowRegistrable.Type] = [],
        activityContainers: [any ActivityContainerProtocol] = [],
        activities: [any ActivityBox] = [],
        logger: Logger = Logger(label: "dev.strand.worker"),
        metricsFactory: (any MetricsFactory)? = nil
    ) {
        self.postgres = postgres
        self.options = options
        self.namespace = options.namespace
        self.notifier = notifier
        self.metricsBuffer = metricsBuffer
        self.logger = logger
        self._metrics = _MetricsFactoryBox(value: metricsFactory ?? MetricsSystem.factory)

        // Build local-activity lookup FIRST so it can be embedded in exec.
        // The lookup maps activity name → in-process runner closure (no DB row).
        let allActivities = activityContainers.flatMap { $0.activities } + activities
        var localLookup: [String: @Sendable (ByteBuffer, _WorkerExec, UUID?) async throws -> ByteBuffer] = [:]
        for box in allActivities {
            let token = box._makeToken()
            localLookup[token.name] = token.runLocal
        }

        let exec = _WorkerExec(
            postgres: postgres,
            queue: options.queue,
            namespace: namespace,
            logger: logger,
            options: options,
            localActivityLookup: localLookup
        )

        // Collect all registrations into a flat array so Registry can store them
        // as a `let` constant — no Mutex or nonisolated(unsafe) required.
        var registrations: [AnyRegistration] = []
        registrations.reserveCapacity(workflows.count + allActivities.count)

        for wfType in workflows {
            let token = wfType._makeToken()
            let queue = token.preferredQueue ?? options.queue
            registrations.append(
                AnyRegistration(
                    name: token.name,
                    queueName: queue,
                    run: { [token, exec] claimed, _ in try await token.activate(claimed, exec) }
                )
            )
        }

        for box in allActivities {
            let token = box._makeToken()
            let queue = token.preferredQueue ?? options.queue
            registrations.append(
                AnyRegistration(
                    name: token.name,
                    queueName: queue,
                    run: { [token, exec] claimed, deadline in
                        try await token.run(claimed, exec, deadline)
                    }
                )
            )
        }

        self._registry = Registry(registrations)
    }

    // MARK: - Service

    public func run() async throws {
        let workerID =
            options.workerID
            ?? "\(ProcessInfo.processInfo.hostName):\(ProcessInfo.processInfo.processIdentifier)"
        let scopedLogger = logger.withWorkerContext(
            queue: options.queue,
            namespace: namespace,
            workerID: workerID
        )
        scopedLogger.info(
            "worker starting",
            metadata: [
                "strand.concurrency.workflow": .stringConvertible(options.workflowConcurrency),
                "strand.concurrency.activity": .stringConvertible(options.activityConcurrency),
            ]
        )
        defer { scopedLogger.info("worker stopped") }

        // One-time: ensure the namespace and queue rows exist before polling.
        // registerNamespace is idempotent (ON CONFLICT DO NOTHING) so the
        // "default" namespace is never duplicated, and any custom namespace
        // declared by an application is auto-created without manual SQL.
        try await Queries.registerNamespace(
            on: postgres,
            namespaceID: namespace,
            logger: logger
        )
        try await Queries.createQueue(
            on: postgres,
            namespaceID: namespace,
            name: options.queue,
            logger: logger
        )

        // Shared running counter — lifted here so heartbeatLoop can read it.
        let running = _RunningCounter()

        // Register this worker in strand.workers so the dashboard can see it.
        // try? so a transient DB error on startup doesn't prevent the worker from running.
        try? await Queries.upsertWorker(
            on: postgres,
            workerID: workerID,
            namespaceID: namespace,
            queue: options.queue,
            concurrency: options.workflowConcurrency + options.activityConcurrency,
            running: 0,
            logger: logger
        )

        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        // Signal shared between listenLoop (producer) and pollLoop (consumer).
        // _SlotSignal (Mutex + CheckedContinuation) has buffer-of-1 semantics:
        // a notification that arrives while the worker is busy is stored and
        // consumed on the next idle check with no allocation or task creation.
        let notifySignal = _SlotSignal()

        try await withTaskCancellationOrGracefulShutdownHandler {
            do {
                // heartbeatLoop and leaseExpiryLoop exit *voluntarily* when
                // Task.isShuttingDownGracefully becomes true (to avoid runTimer
                // continuation leaks on their internal sleeps).  A regular
                // withThrowingTaskGroup + group.next() would treat those normal
                // returns as the first child completion and immediately call
                // group.cancelAll(), killing the shutdown task's sleep before
                // the grace period could run.
                //
                // A discarding group silently discards normal completions; only
                // a *throw* exits the group.  The shutdown task throws after the
                // full gracefulShutdownTimeout, which cancels any still-running
                // children (pollLoop, listenLoop) and lets run() return cleanly.
                try await withThrowingDiscardingTaskGroup { group in
                    group.addTask { try await self.pollLoop(workerID: workerID, notifySignal: notifySignal, running: running) }
                    let myPayload = StrandChannels.Notification(
                        namespace: self.namespace,
                        queue: self.options.queue
                    ).payload
                    group.addTask {
                        // cancelWhenGracefulShutdown: exit the stream loop immediately
                        // on graceful shutdown rather than waiting for the notifier
                        // to shut down and finish the stream.  Mirrors the pattern
                        // used by heartbeatLoop and leaseExpiryLoop.
                        await cancelWhenGracefulShutdown {
                            for await payload in self.notifier.stream(for: StrandChannels.tasks) {
                                if payload == myPayload { notifySignal.signal() }
                            }
                        }
                        // Returns normally — discarded by withThrowingDiscardingTaskGroup.
                    }
                    group.addTask { try await self.heartbeatLoop(workerID: workerID, notifySignal: notifySignal, running: running) }
                    group.addTask { try await self.leaseExpiryLoop() }
                    group.addTask {
                        // Wait for the graceful-shutdown signal from
                        // onCancelOrGracefulShutdown below.
                        await stream.first { _ in true }

                        // Wake pollLoop if it is parked in notifySignal.wait() so
                        // it checks Task.isShuttingDownGracefully and exits its
                        // while loop, letting in-flight runTask children finish.
                        notifySignal.signal()

                        // Immediately expire all in-flight runs for this worker so
                        // the next worker's leaseExpiryLoop picks them up on its
                        // first sweep rather than waiting up to claimTimeout.
                        // Expire in-flight run leases + remove worker heartbeat row
                        // in one round-trip so the next worker's leaseExpiryLoop
                        // picks up the runs immediately and the dashboard stops
                        // showing this worker at the same instant.
                        try? await Queries.shutdownWorker(
                            on: self.postgres,
                            workerID: workerID,
                            namespaceID: self.namespace,
                            queue: self.options.queue,
                            logger: self.logger
                        )

                        // Grace period: give in-flight tasks time to finish.
                        // Task.sleep responds to task *cancellation* (forced
                        // shutdown / ServiceGroup timeout) by throwing
                        // CancellationError, which exits the group immediately.
                        // On graceful shutdown the sleep runs to completion;
                        // the explicit throw below then drives the group exit.
                        try await Task.sleep(for: self.options.gracefulShutdownTimeout)

                        // Reached only after the full graceful grace period.
                        // Throwing from a discarding-group child cancels all
                        // remaining siblings (pollLoop if still draining) and
                        // propagates out — caught below.
                        throw CancellationError()
                    }
                }
            } catch is CancellationError {}
        } onCancelOrGracefulShutdown: {
            cont.finish()  // unblocks the shutdown task in the group above
        }
    }

    // MARK: - Poll loop

    /// Continuously claims and executes tasks using a slot-aware dispatch loop.
    ///
    /// The loop runs as the body of a `withThrowingDiscardingTaskGroup`. On each
    /// iteration it claims up to `free = maxConcurrency - running` tasks and starts
    /// each as an independent group child. When a child finishes it decrements the
    /// counter and signals `_SlotSignal`, waking the loop to claim the next batch
    /// without waiting for other in-flight tasks to complete.
    ///
    /// When all slots are occupied the loop parks on `_SlotSignal` — a
    /// `Mutex`-backed async wakeup that resumes as soon as any slot is freed.
    private func pollLoop(workerID: String, notifySignal: _SlotSignal, running: _RunningCounter) async throws {
        let queueName = options.queue
        let maxConcurrency =
            options.batchSize ?? (options.workflowConcurrency + options.activityConcurrency)
        let claimSecs = Int(options.claimTimeout.components.seconds)

        // slotFreeSignal is local to pollLoop — used to wake the dispatch body
        // when a running task finishes and frees a slot.  `running` is shared
        // with heartbeatLoop (injected via parameter) so it can report live counts.
        let slotFreeSignal = _SlotSignal()

        // Dispatch body: claims work when slots are available, parks when full.
        // Execution tasks are added as independent children of the same group
        // so cancellation propagates cleanly on graceful shutdown.
        try await withThrowingDiscardingTaskGroup { group in
            // When graceful shutdown fires the shutdown task signals notifySignal
            // to unblock this loop, then we detect isShuttingDownGracefully here
            // and exit the while loop.  withThrowingDiscardingTaskGroup then waits
            // for all in-flight runTask children to complete before pollLoop returns.
            while !Task.isShuttingDownGracefully && !Task.isCancelled {
                try Task.checkCancellation()

                let free = maxConcurrency - running.value

                // ── All slots occupied: wait for a completion ──────────────────
                if free <= 0 {
                    try await slotFreeSignal.wait()
                    continue
                }

                // ── Claim up to `free` tasks ───────────────────────────────────
                let claimed: [ClaimedTask]
                do {
                    claimed = try await Queries.claimTasks(
                        on: postgres,
                        namespaceID: namespace,
                        queue: queueName,
                        workerID: workerID,
                        claimTimeoutSeconds: claimSecs,
                        qty: free,
                        logger: logger
                    )
                } catch {
                    if let handler = options.onError {
                        await handler(error)
                    } else {
                        logger.error(
                            "poll error",
                            metadata: .forError(error) + ["strand.queue": .string(queueName)]
                        )
                    }
                    try? await cancelWhenGracefulShutdown {
                        try await Task.sleep(for: options.pollInterval)
                    }
                    continue
                }

                if claimed.isEmpty {
                    // Park until either listenLoop (NOTIFY) or heartbeatLoop
                    // (periodic fallback) signals. Both are structured siblings
                    // in the same task group — no sibling-cancel of Task.sleep,
                    // no unstructured tasks, no runTimer leak.
                    try await notifySignal.wait()
                    // Apply jitter on every wakeup to spread thundering herd.
                    // Heartbeat wakeups are naturally staggered (each worker's
                    // timer starts when it first goes idle, so different workers
                    // fire at different offsets) — jitter is harmless there too.
                    let jitter = options.notifyJitter
                    if jitter > .zero {
                        let maxMs =
                            jitter.components.seconds * 1_000
                            + jitter.components.attoseconds / 1_000_000_000_000_000
                        // try? so a graceful-shutdown CancellationError from
                        // cancelWhenGracefulShutdown doesn't propagate into the
                        // inner discarding group and kill in-flight runTasks.
                        try? await cancelWhenGracefulShutdown {
                            try await Task.sleep(for: .milliseconds(Int64.random(in: 0...maxMs)))
                        }
                    }
                    continue
                }

                // If shutdown arrived while waiting for claimTasks, fast-expire
                // the claimed runs so the next worker picks them up immediately.
                try Task.checkCancellation()

                _metrics.value
                    .makeCounter(
                        label: StrandMetrics.tasksClaimed,
                        dimensions: [("queue", queueName)]
                    )
                    .increment(by: Int64(claimed.count))

                // ── Start each task as an independent group child ──────────────
                // Increment BEFORE addTask so freeSlots is correct on the next
                // loop iteration before any task has had a chance to finish.
                for claimedTask in claimed {
                    running.increment()
                    group.addTask {
                        defer {
                            running.decrement()
                            slotFreeSignal.signal()
                        }
                        await self.runTask(claimedTask)
                    }
                }
                // No explicit sleep: fall through to re-poll immediately.
                // If claimed.count < free there is still open capacity for another
                // batch. If claimed.count == free the next iteration finds free == 0
                // and blocks on slotFreeSignal until a running task finishes.
            }
        }
    }

    // MARK: - Lease expiry sweep

    private func leaseExpiryLoop() async throws {
        let queueName = options.queue

        while !Task.isShuttingDownGracefully && !Task.isCancelled {
            // try? for the same reason as heartbeatLoop: cancelWhenGracefulShutdown
            // throws on graceful shutdown, and we must not let that propagate out
            // of this function into the discarding group.
            try? await cancelWhenGracefulShutdown {
                try await Task.sleep(for: self.options.leaseExpiryInterval)
            }
            // Re-check after the sleep — shutdown may have fired mid-interval.
            guard !Task.isShuttingDownGracefully && !Task.isCancelled else { break }
            do {
                try await Queries.sweepExpiredLeases(
                    on: postgres,
                    namespaceID: namespace,
                    queue: queueName,
                    logger: logger
                )
            } catch {
                logger.error(
                    "lease sweep error",
                    metadata: .forError(error) + ["strand.queue": .string(queueName)]
                )
            }
        }
    }

    // MARK: - Heartbeat loop

    /// Fires `notifySignal` every `pollInterval` so the poll loop wakes to claim
    /// tasks that became PENDING via paths that don’t send NOTIFY — SLEEPING
    /// timer expiry and brief LISTEN reconnect windows.
    ///
    /// Running as a structured sibling in the same task group means its
    /// `Task.sleep` is cancelled once by the parent group on shutdown, not
    /// repeatedly by sibling-cancel (which leaks the `runTimer` continuation).
    private func heartbeatLoop(workerID: String, notifySignal: _SlotSignal, running: _RunningCounter) async throws {
        while !Task.isShuttingDownGracefully && !Task.isCancelled {
            // try? is essential: cancelWhenGracefulShutdown throws CancellationError
            // on graceful shutdown.  Without try? that error propagates out of this
            // function and into withThrowingDiscardingTaskGroup, which then cancels
            // all siblings (including the shutdown task's grace-period sleep)
            // before the timeout can run.
            try? await cancelWhenGracefulShutdown {
                try await Task.sleep(for: self.options.pollInterval)
            }
            notifySignal.signal()
            // Upsert heartbeat row with current running count.
            // try? so a transient DB blip doesn't abort the worker.
            try? await Queries.upsertWorker(
                on: postgres,
                workerID: workerID,
                namespaceID: namespace,
                queue: options.queue,
                concurrency: options.workflowConcurrency + options.activityConcurrency,
                running: running.value,
                logger: logger
            )
            // Sweep stale worker rows left by crashed peers
            // (threshold: 3× pollInterval, floor 30 s).
            let stalenessSeconds = Int(max(30, options.pollInterval.components.seconds * 3))
            try? await Queries.sweepStaleWorkers(
                on: postgres,
                olderThanSeconds: stalenessSeconds,
                logger: logger
            )
        }
    }

    // MARK: - LISTEN/NOTIFY loop

    /// Holds one dedicated Postgres connection and listens on `strand_tasks`.
    /// Whenever a notification arrives with our namespace/queue as payload,
    /// it signals `wakeSignal` so the poll loop claims immediately instead of
    /// sleeping the full poll interval.
    ///
    /// Reconnects automatically on connection loss (network hiccup, Postgres
    /// restart). Cancellation tears down the connection cleanly via the
    /// structured-concurrency cancel path.
    private func listenLoop(notifySignal: _SlotSignal) async throws {
        let channel = StrandChannels.tasks
        let myNotification = StrandChannels.Notification(namespace: namespace, queue: options.queue)

        // cancelWhenGracefulShutdown is used for two reasons:
        //
        // 1. Fast voluntary exit on graceful shutdown.
        //    cancelWhenGracefulShutdown detects Task.isShuttingDownGracefully
        //    and cancels the postgres.withConnection body via an inner task
        //    group.  Without it the loop would keep the connection open until
        //    the while-condition check on the next iteration (up to the full
        //    reconnect / poll cycle).
        //
        // 2. NIO runTimer continuation safety.
        //    When cancelWhenGracefulShutdown cancels the inner scope, the
        //    *outer* listenLoop task is still alive (it will execute the
        //    catch block and return).  NIO's event-loop cleanup callbacks —
        //    including any runTimer continuations scheduled during connection
        //    teardown — have time to fire within this window.  If the outer
        //    task were torn down at the same moment (e.g. by the grace-period
        //    throw after gracefulShutdownTimeout), those continuations would
        //    be leaked.
        //
        // The reconnect sleep uses the same wrapper for reason 2.
        while !Task.isShuttingDownGracefully && !Task.isCancelled {
            do {
                try await cancelWhenGracefulShutdown {
                    try await self.postgres.withConnection { conn in
                        try await conn.listen(on: channel) { notifications in
                            for try await note in notifications {
                                if note.payload == myNotification.payload {
                                    notifySignal.signal()
                                }
                            }
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                logger.warning(
                    "LISTEN connection lost — reconnecting",
                    metadata: .forError(error)
                )
                // Wrap the reconnect sleep for the same reason: a raw
                // group.cancelAll() mid-sleep leaks the runTimer continuation.
                try await cancelWhenGracefulShutdown {
                    try await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    // MARK: - Task execution

    private func runTask(_ claimed: ClaimedTask) async {
        // Scope the logger to this specific task/run for structured log output.
        let taskLogger = logger.withTaskContext(claimed)

        // Unknown task name — defer with jittered backoff so a rolling deploy that adds
        // a new task type doesn't spin-loop on workers that haven't updated yet.
        guard let reg = _registry.lookup(claimed.taskName) else {
            let delay = unknownTaskDelay(seed: claimed.runID.uuidString)
            let wakeAt = Date.now.addingTimeInterval(Double(delay.components.seconds))
            do {
                try await Queries.scheduleRun(
                    on: postgres,
                    namespaceID: namespace,
                    runID: claimed.runID,
                    taskID: claimed.taskID,
                    wakeAt: wakeAt,
                    logger: taskLogger
                )
            } catch {
                taskLogger.error("failed to defer unknown task", metadata: .forError(error))
            }
            return
        }

        // Per-task timeout takes precedence for the fatal deadline.
        // Zero is treated as nil ("use worker default") so that a user who
        // accidentally passes 0 doesn't get an immediately-expired deadline.
        let fatalDeadlineTimeout: Duration
        if let taskTimeoutSecs = claimed.timeoutSeconds, taskTimeoutSecs > 0 {
            fatalDeadlineTimeout = .seconds(taskTimeoutSecs)
        } else {
            fatalDeadlineTimeout = options.claimTimeout + options.claimTimeout
        }
        let fatalDeadline = TaskDeadline(timeout: fatalDeadlineTimeout)

        let taskStart = ContinuousClock.now
        let taskStartWall = Date.now  // wall clock for wait_time
        let taskDims: [(String, String)] = [
            ("task_name", claimed.taskName),
            ("queue", options.queue),
        ]

        // ── Race execution against 2× timeout ─────────────────────────
        // Execution and deadline enforcement run as structured children of the
        // same group — whichever finishes first cancels the other cleanly.
        do {
            let resultBuf: ByteBuffer? = try await withThrowingTaskGroup(of: ByteBuffer?.self) {
                group in

                // Task 1: actual task execution.
                group.addTask {
                    defer {
                        let elapsed = ContinuousClock.now - taskStart
                        self._metrics.value
                            .makeTimer(label: StrandMetrics.taskDuration, dimensions: taskDims)
                            .recordNanoseconds(elapsed.nanoseconds)
                        // execMs is read after the task group exits via
                        // (ContinuousClock.now - taskStart).  The ~1-2 ms overhead
                        // from group teardown is negligible for p50/p95/p99.
                    }
                    // OTel span: one span per task execution attempt.
                    //
                    // Extract the W3C trace context from the task headers and use it
                    // as the *parent* span.  This creates a proper parent-child
                    // relationship in Jaeger / OTLP collectors:
                    //
                    //   • Activities / child-workflows enqueued by a workflow carry the
                    //     workflow activation’s span (injected in applyScheduleCommands)
                    //     → they appear nested under the workflow span.
                    //
                    //   • Root tasks enqueued directly (e.g. from an HTTP handler) carry
                    //     the producer span (injected by StrandClient._enqueue)
                    //     → they appear nested under the HTTP request span.
                    //
                    // OTel parent-child is causal, not temporal: the child span may start
                    // after the parent ends.  This is standard async-messaging propagation
                    // (Kafka, SQS, AMQP) and is handled correctly by all major collectors.
                    //
                    // Zero-cost no-op when no tracing backend is bootstrapped.
                    var parentCtx = ServiceContext.topLevel
                    InstrumentationSystem.tracer.extract(
                        claimed.headers,
                        into: &parentCtx,
                        using: DictionaryExtractor()
                    )

                    // ── Trace continuity (zero DB cost) ──────────────────────────
                    // Workflows enqueued outside an HTTP context (seeders, cron)
                    // have NULL headers — no traceparent at enqueue time — so
                    // each activation creates a fresh root span in a different
                    // Jaeger trace. The user sees one span per trace instead of
                    // the full workflow history.
                    //
                    // Fix: derive a synthetic traceparent directly from the task
                    // UUID (128 bits ≡ OTel trace ID). Because the UUID is stable
                    // across every activation, all activations and their spawned
                    // activities share the same trace ID → one complete trace in
                    // Jaeger. No DB write, no extra round-trip.
                    //
                    // Workflows enqueued from an HTTP handler already have a real
                    // traceparent extracted above; this block is skipped for them.
                    if claimed.kind == .workflow && claimed.headers.isEmpty {
                        // UUIDv7 hex (32 chars) = OTel trace ID (16 bytes).
                        // Span ID (8 bytes) = first 16 hex chars of the UUID.
                        // The synthetic “parent” span does not physically exist in
                        // Jaeger; collectors treat these spans as trace roots while
                        // still grouping them under the shared trace ID.
                        let hex = claimed.taskID.uuidString
                            .lowercased()
                            .replacing("-", with: "")
                        let syntheticParent = "00-\(hex)-\(hex.prefix(16))-01"
                        InstrumentationSystem.tracer.extract(
                            ["traceparent": syntheticParent],
                            into: &parentCtx,
                            using: DictionaryExtractor()
                        )
                    }

                    return try await withSpan(claimed.taskName, context: parentCtx, ofKind: .consumer) { span in
                        span.attributes[StrandLogKeys.taskName] = SpanAttribute.string(
                            claimed.taskName
                        )
                        span.attributes[StrandLogKeys.taskKind] = SpanAttribute.string(
                            claimed.kind.rawValue
                        )
                        span.attributes[StrandLogKeys.taskID] = SpanAttribute.string(
                            claimed.taskID.uuidString.lowercased()
                        )
                        span.attributes[StrandLogKeys.runID] = SpanAttribute.string(
                            claimed.runID.uuidString.lowercased()
                        )
                        span.attributes[StrandLogKeys.queue] = SpanAttribute.string(options.queue)
                        span.attributes[StrandLogKeys.attempt] = SpanAttribute.int(
                            Int64(claimed.attempt)
                        )
                        return try await reg.run(claimed, fatalDeadline)
                    }
                }

                // Task 2: deadline poller — two escalating thresholds:
                //   1× claimTimeout → log a warning (task is running long)
                //   2× claimTimeout → cancel execution (fatalDeadline expired)
                group.addTask {
                    var warnedSlow = false
                    do {
                        while true {
                            try Task.checkCancellation()
                            try await Task.sleep(for: .milliseconds(500))
                            let elapsed = ContinuousClock.now - taskStart
                            // 1× warning — fires once when task exceeds claimTimeout
                            if !warnedSlow, elapsed > options.claimTimeout {
                                warnedSlow = true
                                taskLogger.warning(
                                    "task \(claimed.taskName) (\(claimed.taskID)) exceeded claim timeout (\(options.claimTimeout)) — still running"
                                )
                            }
                            // 2× fatal — cancel execution
                            if fatalDeadline.isExpired {
                                taskLogger.critical(
                                    "task \(claimed.taskName) (\(claimed.taskID)) exceeded 2× claim timeout — cancelling"
                                )
                                throw ClaimTimeoutError()
                            }
                        }
                    } catch is CancellationError {
                        return nil  // Task 1 won the race — exit cleanly
                    }
                    // ClaimTimeoutError propagates out to the group
                }

                // First child to finish wins; cancel the other.
                let result = try await group.next()
                group.cancelAll()
                return result ?? nil
            }

            if let buf = resultBuf {
                // Run produced a result — mark COMPLETED with CAS on version.
                try await Queries.completeRun(
                    on: postgres,
                    namespaceID: namespace,
                    runID: claimed.runID,
                    version: claimed.version,
                    resultBuffer: buf,
                    logger: logger
                )
            }
            _metrics.value.makeCounter(label: StrandMetrics.tasksCompleted, dimensions: taskDims)
                .increment(by: 1)
            // Record to DDSketch buffer with known state.
            // nil result means the workflow suspended cleanly — still a "completed" execution
            // from the worker’s perspective (it ran and handed off cleanly).
            metricsBuffer?.record(
                queue: options.queue,
                taskName: claimed.taskName,
                state: .completed,
                execMs: Double((ContinuousClock.now - taskStart).nanoseconds) / 1_000_000.0,
                waitMs: max(0, taskStartWall.timeIntervalSince(claimed.availableAt) * 1000)
            )
        } catch is CancellationError {
            // Worker is shutting down (graceful SIGTERM or forced cancellation).
            // Leave the run in RUNNING state — the leaseExpiryLoop sweep will
            // call failRun when lease_expires_at elapses (within leaseExpiryInterval).
            // This avoids incrementing the attempt counter for a shutdown that is
            // not a task failure.
        } catch InternalError.cancelled {
            _metrics.value.makeCounter(label: StrandMetrics.tasksSuspended, dimensions: taskDims)
                .increment(by: 1)
            // Task was cancelled externally (e.g. heartbeat found state != RUNNING).
        } catch let signal as _ContinueAsNewSignal {
            _metrics.value.makeCounter(
                label: StrandMetrics.tasksContinuedAsNew,
                dimensions: taskDims
            ).increment(by: 1)
            do {
                if claimed.parentWorkflowID != nil {
                    // ── Child workflow ────────────────────────────────────────────────
                    // Reuse the same task_id so the parent's event_wait (child_task_id)
                    // keeps tracking this task. The parent stays
                    // WAITING; when the chain terminates with a real result, completeRun
                    // fires emitTaskCompletionSignal and the parent receives it.
                    try await Queries.continueChildWorkflowAsNew(
                        on: postgres,
                        namespaceID: signal.namespaceID,
                        taskID: claimed.taskID,
                        currentRunID: claimed.runID,
                        currentVersion: claimed.version,
                        newInput: signal.input,
                        newRunID: UUID.v7(),
                        logger: logger
                    )
                } else {
                    // ── Root workflow ─────────────────────────────────────────────────
                    // No parent is tracking this task_id, so a fresh task is fine.
                    _ = try await Queries.enqueueTask(
                        on: postgres,
                        namespaceID: signal.namespaceID,
                        queue: signal.queue,
                        taskName: signal.workflowName,
                        paramsBuffer: signal.input,
                        headersBuffer: nil,
                        retryStrategyBuffer: nil,
                        maxAttempts: nil,
                        cancellationBuffer: nil,
                        idempotencyKey: nil,
                        priority: .normal,
                        scheduledAt: nil,
                        fairnessKey: nil,
                        fairnessWeight: 1.0,
                        kind: .workflow,
                        parentTaskID: nil,
                        logger: logger
                    )
                    try await Queries.completeRun(
                        on: postgres,
                        namespaceID: signal.namespaceID,
                        runID: claimed.runID,
                        version: claimed.version,
                        resultBuffer: nil,
                        logger: logger
                    )
                }
            } catch {
                taskLogger.error("continue-as-new failed", metadata: .forError(error))
            }
        } catch let typed as _TypedActivityFailure {
            // Pre-encoded failure reason from Activity._run — use verbatim.
            await failAndRecord(
                reasonBuffer: typed.reasonBuffer,
                claimed: claimed,
                taskDims: taskDims,
                taskStart: taskStart,
                taskStartWall: taskStartWall,
                logger: taskLogger
            )
        } catch {
            let reason = FailureReason(error: error)
            let buf =
                (try? JSON.encode(reason))
                ?? ByteBuffer(string: #"{"name":"unknown","message":"encoding failed"}"#)
            await failAndRecord(
                reasonBuffer: buf,
                claimed: claimed,
                taskDims: taskDims,
                taskStart: taskStart,
                taskStartWall: taskStartWall,
                logger: taskLogger
            )
        }
    }

    /// Records a task failure in metrics and persists it via `Queries.failRun`.
    ///
    /// Shared by the typed-failure catch (`_TypedActivityFailure`) and the generic
    /// catch in `runTask` — only `reasonBuffer` differs between the two.
    private func failAndRecord(
        reasonBuffer: ByteBuffer,
        claimed: ClaimedTask,
        taskDims: [(String, String)],
        taskStart: ContinuousClock.Instant,
        taskStartWall: Date,
        logger: Logger
    ) async {
        _metrics.value.makeCounter(label: StrandMetrics.tasksFailed, dimensions: taskDims)
            .increment(by: 1)
        metricsBuffer?.record(
            queue: options.queue,
            taskName: claimed.taskName,
            state: .failed,
            execMs: Double((ContinuousClock.now - taskStart).nanoseconds) / 1_000_000.0,
            waitMs: max(0, taskStartWall.timeIntervalSince(claimed.availableAt) * 1000)
        )
        do {
            try await Queries.failRun(
                on: postgres,
                namespaceID: namespace,
                runID: claimed.runID,
                reasonBuffer: reasonBuffer,
                logger: logger
            )
        } catch {
            logger.error(
                "failRun DB call failed — run will be swept by leaseExpiryLoop",
                metadata: .forError(error)
            )
        }
    }
}

// MARK: - Registry

/// Immutable handler registry built once at `StrandWorker.init` time.
///
/// Receives all registrations through its initialiser so the store can be
/// a `let` constant.  A `let [String: AnyRegistration]` on a `final class`
/// is `Sendable` by definition — no `Mutex`, no `nonisolated(unsafe)`,
/// no escape hatch needed.
final class Registry: Sendable {
    private let store: [String: AnyRegistration]

    init(_ registrations: [AnyRegistration]) {
        var s = [String: AnyRegistration](minimumCapacity: registrations.count)
        for r in registrations { s[r.name] = r }
        store = s
    }

    func lookup(_ name: String) -> AnyRegistration? {
        store[name]
    }
}

/// Thrown by the 2× deadline poller (Task 2 inside `runTask`) when the
/// fatal deadline expires. Propagates out of the `withThrowingTaskGroup`,
/// cancels the execution task, and is caught as a general failure.
private struct ClaimTimeoutError: Error {}

// MARK: - FailureReason

/// Structured error record stored in `strand.runs.failure_reason` (BYTEA / JSON).
///
/// Field layout: `name` is the Swift type name, `message` is the human-readable
/// `localizedDescription`, `cause` chains inner errors recursively, and
/// `source` captures the `#fileID` + `#line` of the `WorkflowContext` call that
/// first observed the failure (e.g. which `context.runActivity(...)` line threw).
// A final class (not struct) because `cause` is recursive — Swift value types
// cannot have stored properties that directly contain themselves.
private final class FailureReason: Codable, Sendable {
    let name: String
    let message: String
    let cause: FailureReason?
    let source: SourceLocation?

    struct SourceLocation: Codable, Sendable {
        let fileID: String
        let line: Int
        enum CodingKeys: String, CodingKey {
            case fileID = "file_id"
            case line
        }
    }

    init(error: any Error) {
        // Priority 1: call-site annotation stamped by WorkflowContext.runActivity etc.
        if let annotated = error as? CallSiteAnnotatedError {
            name = String(describing: Swift.type(of: annotated.underlying))
            message = strandErrorMessage(annotated.underlying)
            source = SourceLocation(fileID: annotated.fileID, line: annotated.line)
            cause = FailureReason.makeCause(from: annotated.underlying)
            // Priority 2: error carries its own throw-site via LocatableError.
        } else if let located = error as? any LocatableError {
            name = String(describing: Swift.type(of: error))
            message = strandErrorMessage(error)
            source = SourceLocation(fileID: located.sourceFileID, line: located.sourceLine)
            cause = FailureReason.makeCause(from: error)
        } else {
            name = String(describing: Swift.type(of: error))
            message = strandErrorMessage(error)
            source = nil
            cause = FailureReason.makeCause(from: error)
        }
    }

    /// Recursively extracts a cause for errors that carry an underlying error.
    /// Currently handles `StrandError.database` and `StrandError.serialization`.
    private static func makeCause(from error: any Error) -> FailureReason? {
        guard let se = error as? StrandError else { return nil }
        switch se {
        case .database(let underlying): return FailureReason(error: underlying)
        case .serialization(let underlying): return FailureReason(error: underlying)
        default: return nil
        }
    }
}

// MARK: - Poll loop helpers

/// Running-task counter shared between the dispatch body and each execution
/// task inside `pollLoop`. `Sendable`-conformant: concurrent `increment()` and
/// `decrement()` calls are data-race free via the internal `Mutex`.
///
/// Stored as a `final class` so it can be captured by multiple closures without
/// copying (Swift’s `Mutex` is `~Copyable` and cannot be captured by value).
private final class _RunningCounter: Sendable {
    private let _mutex: Mutex<Int> = Mutex(0)

    var value: Int { _mutex.withLock { $0 } }

    func increment() { _mutex.withLock { $0 += 1 } }
    func decrement() { _mutex.withLock { $0 -= 1 } }
}

/// Single-pending async wakeup signal.
///
/// The poll-loop dispatcher parks here when all concurrency slots are full.
/// Each execution task calls `signal()` from its `defer` block when it
/// finishes, immediately waking the dispatcher so it can claim more work.
///
/// Uses `withTaskCancellationHandler` + explicit `onCancel` that resumes the stored
/// continuation.  This guarantees the continuation is ALWAYS resumed — either
/// by `signal()` or by the cancellation handler — so no `_runTimer`
/// continuation can ever be orphaned.
private final class _SlotSignal: Sendable {
    private struct _State {
        var pending: Bool = false
        var continuation: CheckedContinuation<Void, Never>? = nil
    }
    private let _mutex: Mutex<_State> = Mutex(.init())

    /// Wake one waiting `wait()` call.  If nobody is waiting yet, the signal
    /// is stored and the next `wait()` returns immediately (buffer-of-1).
    func signal() {
        let cont = _mutex.withLock { s -> CheckedContinuation<Void, Never>? in
            if let c = s.continuation {
                s.continuation = nil
                return c
            }
            s.pending = true
            return nil
        }
        cont?.resume()
    }

    /// Suspend until the next `signal()`, or return immediately if one is
    /// already pending.  Throws `CancellationError` when the enclosing task
    /// is cancelled while waiting — the cancellation handler explicitly
    /// resumes the continuation so it is never leaked.
    func wait() async throws {
        // Fast path 1: task already cancelled before we reach the wait.
        try Task.checkCancellation()

        // Fast path 2: a signal arrived before any waiter was registered.
        let alreadyPending = _mutex.withLock { s -> Bool in
            guard s.pending else { return false }
            s.pending = false
            return true
        }
        if alreadyPending { return }

        // Slow path: park the continuation until signal() or cancellation.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                // Three-way check inside the lock:
                //  1. A signal arrived after the fast-path check above       → resume now
                //  2. Cancellation arrived before onCancel could see the     → resume now
                //     continuation (the narrow window between registering the
                //     onCancel handler and this closure running): onCancel
                //     fired, read continuation = nil, did nothing. Without
                //     this check the continuation would be stored and leaked.
                //  3. Neither → store the continuation for signal()/onCancel.
                var shouldResume = false
                _mutex.withLock { s in
                    if s.pending {
                        s.pending = false
                        shouldResume = true
                    } else if Task.isCancelled {
                        shouldResume = true  // onCancel already missed us
                    } else {
                        s.continuation = cont
                    }
                }
                if shouldResume { cont.resume() }
            }
        } onCancel: {
            // Resume synchronously from the canceller's thread so the
            // dispatcher unblocks and can propagate CancellationError.
            let cont = _mutex.withLock { s -> CheckedContinuation<Void, Never>? in
                let c = s.continuation
                s.continuation = nil
                return c
            }
            cont?.resume()
        }

        // After waking from cancellation, throw so the dispatch loop exits.
        try Task.checkCancellation()
    }

}
