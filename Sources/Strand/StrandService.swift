import Logging
public import PostgresNIO
public import ServiceLifecycle

// ── StrandService ─────────────────────────────────────────────────────────────

/// Zero-boilerplate bootstrap for Strand.
///
/// `StrandService` wires `StrandNotifier`, `AggregatedMetricsBuffer`,
/// `StrandMetricsLoop`, N × `StrandWorker`, an optional `StrandPruner`, and
/// an optional `StrandScheduler` into a single `Service`.
///
/// The `StrandNotifier` is created at init time and exposed as `notifier` so
/// that other services — e.g. `MetricsBroadcastListener` for the Loom dashboard
/// — can subscribe to the same Postgres LISTEN connection without opening an
/// extra one:
///
/// ```swift
/// var strand = StrandService(postgres: postgres, options: .init(queues: [...]))
/// strand.addSchedule(.workflow("nightly", pattern: .cron("0 2 * * *"), ...))
///
/// // Dashboard reuses the shared notifier — no extra LISTEN connection.
/// let metricsCache = MetricsCache()
/// let listener = MetricsBroadcastListener(notifier: strand.notifier,
///                                         cache: metricsCache, logger: logger)
/// let dashboard = StrandServer(client: strand.client(queue: "orders"),
///                              postgres: postgres)
///
/// let group = ServiceGroup(services: [postgres, strand, listener, dashboard],
///                          logger: logger)
/// try await group.run()
/// ```
///
/// All explicit types (`StrandWorker`, `StrandNotifier`, etc.) remain fully
/// supported; `StrandService` is the ergonomic on-ramp for the common case.
public struct StrandService: Service {

    // MARK: - Options

    public struct Options: Sendable {
        /// One entry per logical worker. At least one queue is required.
        public var queues: [QueueConfig]
        /// Automatic task pruning. `nil` disables the pruner.
        /// Use `StrandPrunerOptions()` for defaults; all five fields are
        /// available (`interval`, `maxAge`, `limit`, `queue`, `advisoryLockKey`).
        public var pruner: StrandPrunerOptions?
        /// Scheduler options. `nil` disables the scheduler.
        /// Add schedules with ``StrandService/addSchedule(_:)``.
        public var scheduler: SchedulerConfig?
        /// Logger used by all sub-services unless they override it.
        public var logger: Logger

        public init(
            queues: [QueueConfig],
            pruner: StrandPrunerOptions? = nil,
            scheduler: SchedulerConfig? = nil,
            logger: Logger = Logger(label: "dev.strand")
        ) {
            self.queues = queues
            self.pruner = pruner
            self.scheduler = scheduler
            self.logger = logger
        }
    }

    // MARK: - QueueConfig

    /// Configuration for one `StrandWorker`.
    public struct QueueConfig: Sendable {
        public var name: String
        /// Namespace this worker operates in. Default: `"default"`.
        public var namespace: String
        /// Workflow types processed by this worker.
        public var workflows: [any WorkflowRegistrable.Type]
        /// Activity containers — groups of activities sharing a common dependency
        /// (e.g. a database client or API key). Implement `ActivityContainerProtocol`
        /// to bundle related activities and inject shared resources once.
        public var activityContainers: [any ActivityContainerProtocol]
        /// Individual activity instances. Any `ActivityDefinition` satisfies
        /// `ActivityBox` automatically; use this for standalone activities.
        public var activities: [any ActivityBox]
        public var workflowConcurrency: Int
        public var activityConcurrency: Int
        public var pollInterval: Duration
        public var claimTimeout: Duration
        public var leaseExpiryInterval: Duration
        public var notifyJitter: Duration

        public init(
            name: String = "default",
            namespace: String = "default",
            workflows: [any WorkflowRegistrable.Type] = [],
            activityContainers: [any ActivityContainerProtocol] = [],
            activities: [any ActivityBox] = [],
            workflowConcurrency: Int = 4,
            activityConcurrency: Int = 8,
            pollInterval: Duration = .seconds(5),
            claimTimeout: Duration = .seconds(60),
            leaseExpiryInterval: Duration = .seconds(5),
            notifyJitter: Duration = .milliseconds(50)
        ) {
            self.name = name
            self.namespace = namespace
            self.workflows = workflows
            self.activityContainers = activityContainers
            self.activities = activities
            self.workflowConcurrency = workflowConcurrency
            self.activityConcurrency = activityConcurrency
            self.pollInterval = pollInterval
            self.claimTimeout = claimTimeout
            self.leaseExpiryInterval = leaseExpiryInterval
            self.notifyJitter = notifyJitter
        }
    }

    // MARK: - SchedulerConfig

    /// Scheduler configuration for `StrandService`.
    ///
    /// Wraps `SchedulerOptions` (which owns `sleepCap`, `maxCatchupSlots`,
    /// `pollLimit`) and adds the two `StrandService`-specific fields that
    /// select which queue's internal client the scheduler uses.
    public struct SchedulerConfig: Sendable {
        /// Forwarded directly to `StrandScheduler`.
        public var options: SchedulerOptions
        /// Queue whose client the scheduler uses. Defaults to the first queue.
        public var queue: String?
        /// Namespace for the scheduler client. Defaults to the chosen queue's namespace.
        public var namespace: String?

        public init(
            options: SchedulerOptions = .init(),
            queue: String? = nil,
            namespace: String? = nil
        ) {
            self.options = options
            self.queue = queue
            self.namespace = namespace
        }
    }

    // MARK: - Stored state

    private let postgres: PostgresClient
    private let options: Options
    /// Pre-built clients keyed by "namespace/queue" — avoids struct allocation on
    /// every `client(queue:namespace:)` call. Queues not in this map fall back to
    /// creating a fresh `StrandClient` (correct for cross-service enqueueing).
    private let _clients: [String: StrandClient]

    /// The shared LISTEN/NOTIFY hub for this service.
    ///
    /// Subscribes to both `strand_tasks` (worker wake-ups) and `strand_metrics`
    /// (DDSketch broadcast) so external services — e.g. `MetricsBroadcastListener`
    /// for the Loom dashboard — can reuse this connection without opening another.
    ///
    /// Created at `init` time; `run()` adds it to the inner service group.
    public let notifier: StrandNotifier

    /// Schedules accumulated via ``addSchedule(_:)`` before ``run()`` is called.
    private var _schedules: [StrandSchedule] = []

    // MARK: - Init

    public init(postgres: PostgresClient, options: Options) {
        self.postgres = postgres
        self.options = options
        // Pre-build one StrandClient per configured queue so client(queue:namespace:)
        // is a dictionary lookup rather than a fresh struct allocation each call.
        var clients: [String: StrandClient] = [:]
        let strandOpts = StrandOptions(logger: options.logger)
        for q in options.queues {
            clients["\(q.namespace)/\(q.name)"] = StrandClient(
                postgres: postgres,
                queue: q.name,
                namespace: q.namespace,
                options: strandOpts
            )
        }
        self._clients = clients
        // Both channels are always active: tasksChannel wakes workers,
        // metricsChannel lets MetricsBroadcastListener (if attached) receive
        // DDSketch broadcasts without opening a second LISTEN connection.
        self.notifier = StrandNotifier(
            postgres: postgres,
            channels: [StrandNotifier.tasksChannel, StrandNotifier.metricsChannel],
            logger: options.logger
        )
    }

    // MARK: - Schedule registration

    /// Adds a schedule that is upserted when ``run()`` starts.
    ///
    /// Mirrors `StrandScheduler`'s `schedules:` parameter — the scheduler
    /// calls `upsertSchedule` for every entry before its poll loop begins.
    /// Must be called before the `ServiceGroup` that owns this service is run.
    public mutating func addSchedule(_ schedule: StrandSchedule) {
        _schedules.append(schedule)
    }

    // MARK: - Client accessor

    /// Returns a `StrandClient` for the given queue.
    ///
    /// Equivalent to `StrandClient(postgres: postgres, queue: queue, namespace: namespace)`.
    /// Provided so callers that hold a `StrandService` reference don't need to
    /// keep a separate `PostgresClient`.
    public func client(
        queue: String? = nil,
        namespace: String? = nil
    ) -> StrandClient {
        let q = queue ?? options.queues.first?.name ?? "default"
        let ns =
            namespace
            ?? options.queues.first(where: { $0.name == q })?.namespace
            ?? options.queues.first?.namespace
            ?? "default"
        // Fast path: return the pre-built client for queues owned by this service.
        // Falls back to a fresh StrandClient for queues outside the service config
        // (valid — callers may want a client for a peer queue).
        return _clients["\(ns)/\(q)"]
            ?? StrandClient(
                postgres: postgres,
                queue: q,
                namespace: ns,
                options: StrandOptions(logger: options.logger)
            )
    }

    // MARK: - Service

    public func run() async throws {
        guard let firstQueue = options.queues.first else {
            options.logger.warning("[StrandService] no queues configured — nothing to run")
            return
        }

        let logger = options.logger

        // ── 1. Schema verification ─────────────────────────────────────────────
        // Namespace and queue registration is handled by each sub-service:
        //   • StrandWorker.run() calls registerNamespace + createQueue for its queue.
        //   • StrandScheduler.run() calls registerNamespace before upsert.
        // Both are idempotent; no central pre-registration is needed here.
        try await client().verifySchema()

        // ── 2. Metrics buffer + loop ────────────────────────────────────────────
        // Workers write task timings into the buffer; the loop flushes every 5 s
        // and broadcasts compressed DDSketches via pg_notify on strand_metrics.
        let metricsBuffer = AggregatedMetricsBuffer()
        let metricsLoop = StrandMetricsLoop(
            client: client(),
            metricsBuffer: metricsBuffer
        )

        // ── 3. Workers ──────────────────────────────────────────────────────────
        let workers: [StrandWorker] = options.queues.map { q in
            StrandWorker(
                postgres: postgres,
                options: WorkerOptions(
                    queue: q.name,
                    namespace: q.namespace,
                    workflowConcurrency: q.workflowConcurrency,
                    activityConcurrency: q.activityConcurrency,
                    pollInterval: q.pollInterval,
                    claimTimeout: q.claimTimeout,
                    leaseExpiryInterval: q.leaseExpiryInterval,
                    notifyJitter: q.notifyJitter
                ),
                notifier: notifier,
                metricsBuffer: metricsBuffer,
                workflows: q.workflows,
                activityContainers: q.activityContainers,
                activities: q.activities,
                logger: logger
            )
        }

        // ── 4. Pruner (optional) ────────────────────────────────────────────────
        let pruner: StrandPruner? = options.pruner.map { opts in
            StrandPruner(
                postgres: postgres,
                namespaceID: firstQueue.namespace,
                options: opts,
                logger: logger
            )
        }

        // ── 5. Scheduler (optional) ─────────────────────────────────────────────
        // Schedules accumulated via addSchedule(_:) are passed directly to
        // StrandScheduler, which upserts them before its poll loop begins.
        let scheduledSchedules = _schedules
        let scheduler: StrandScheduler? = options.scheduler.map { sched in
            let schedulerQueueName = sched.queue ?? firstQueue.name
            let schedulerNamespace =
                sched.namespace
                ?? options.queues.first(where: { $0.name == schedulerQueueName })?.namespace
                ?? firstQueue.namespace
            return StrandScheduler(
                client: StrandClient(
                    postgres: postgres,
                    queue: schedulerQueueName,
                    namespace: schedulerNamespace,
                    options: StrandOptions(logger: logger)
                ),
                options: sched.options,
                schedules: scheduledSchedules
            )
        }

        // ── 6. Run ──────────────────────────────────────────────────────────────
        // Empty gracefulShutdownSignals: the outer ServiceGroup (user-created)
        // owns signal handling. Task cancellation from that group cascades here.
        var services: [any Service] = [notifier, metricsLoop]
        services.append(contentsOf: workers)
        if let pruner { services.append(pruner) }
        if let scheduler { services.append(scheduler) }

        let group = ServiceGroup(
            services: services,
            gracefulShutdownSignals: [],
            logger: logger
        )
        try await group.run()
    }
}
