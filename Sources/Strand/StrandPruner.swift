import Logging
public import PostgresNIO
public import ServiceLifecycle

// MARK: - Options

/// Configuration for ``StrandPruner``.
public struct StrandPrunerOptions: Sendable {
    /// How often to run a prune cycle. Default: 30 s.
    public var interval: Duration
    /// Maximum age of terminal tasks before they are deleted.
    /// Default: `nil` — ``ManagementQueries/cleanupTasks`` reads the namespace
    /// `retention_days` column when this is `nil`.
    public var maxAge: Duration?
    /// Maximum number of rows deleted per cycle (batched to avoid long locks).
    /// Default: 10,000.
    public var limit: Int
    /// Queue to prune. `nil` = all queues in the namespace. Default: `nil`.
    public var queue: String?
    /// Postgres advisory lock key used for leader election.
    /// Must be identical across every ``StrandPruner`` instance in the cluster
    /// so only one instance runs cleanup per cycle.
    /// Default: a stable constant derived from "StrandPN".
    public var advisoryLockKey: Int64

    public init(
        interval: Duration = .seconds(30),
        maxAge: Duration? = nil,
        limit: Int = 10_000,
        queue: String? = nil,
        advisoryLockKey: Int64 = 0x5374_7261_6E64_504E  // "StrandPN"
    ) {
        self.interval = interval
        self.maxAge = maxAge
        self.limit = limit
        self.queue = queue
        self.advisoryLockKey = advisoryLockKey
    }
}

// MARK: - Service

/// Background service that periodically deletes terminal (completed/failed/cancelled)
/// tasks older than a configurable age.
///
/// Add ``StrandPruner`` to your `ServiceGroup` to keep `strand.tasks` from growing
/// unboundedly without requiring manual cleanup calls.
///
/// Only one instance in the cluster runs each cycle — leader election is via
/// `pg_try_advisory_lock`. Non-leaders log a debug message and skip that cycle.
///
/// ```swift
/// let pruner = StrandPruner(
///     postgres: postgres,
///     namespaceID: "default",
///     options: StrandPrunerOptions(maxAge: .seconds(7 * 24 * 3600)) // 7 days
/// )
/// let group = ServiceGroup(services: [postgres, worker, pruner])
/// ```
public struct StrandPruner: Service {
    private let postgres: PostgresClient
    private let namespaceID: String
    private let options: StrandPrunerOptions
    private let logger: Logger

    public init(
        postgres: PostgresClient,
        namespaceID: String = "default",
        options: StrandPrunerOptions = .init(),
        logger: Logger = Logger(label: "dev.strand.pruner")
    ) {
        self.postgres = postgres
        self.namespaceID = namespaceID
        self.options = options
        self.logger = logger
    }

    // MARK: - Service

    public func run() async throws {
        logger.info(
            "pruner starting",
            metadata: [
                "strand.namespace": .string(namespaceID),
                "strand.interval": .string("\(options.interval)"),
                "strand.limit": .stringConvertible(options.limit),
            ]
        )
        defer { logger.info("pruner stopped") }

        while !Task.isShuttingDownGracefully && !Task.isCancelled {
            try? await cancelWhenGracefulShutdown {
                try await Task.sleep(for: self.options.interval)
            }
            guard !Task.isShuttingDownGracefully && !Task.isCancelled else { break }

            do {
                try await tryPrune()
            } catch {
                logger.error(
                    "pruner cycle failed",
                    metadata: ["error": .string(String(reflecting: error))]
                )
            }
        }
    }

    // MARK: - Private

    private func tryPrune() async throws {
        // Hold a dedicated connection for the duration of the advisory lock so
        // Postgres releases it automatically when the connection is returned,
        // even if tryPrune throws.
        try await postgres.withConnection { conn in
            // pg_try_advisory_lock: non-blocking; returns true if we became leader.
            let lockStream = try await conn.query(
                "SELECT pg_try_advisory_lock(\(options.advisoryLockKey))",
                logger: logger
            )
            guard let lockRow = try await lockStream.first(where: { _ in true }) else { return }
            var lockCol = lockRow.makeIterator()
            let acquired = try lockCol.next()!.decode(Bool.self, context: .default)

            guard acquired else {
                logger.debug(
                    "pruner: not leader — skipping this cycle",
                    metadata: ["strand.namespace": .string(namespaceID)]
                )
                return
            }

            // We are the leader for this cycle. Run cleanup on the main pool
            // (it will use a separate connection from the pool; that's fine — the
            // advisory lock is held here just to prevent other instances from
            // starting a concurrent cleanup).
            let ageSeconds: Int?
            if let maxAge = options.maxAge {
                ageSeconds = Int(maxAge.components.seconds)
            } else {
                ageSeconds = nil  // ManagementQueries.cleanupTasks reads namespace retention_days
            }

            _ = try await ManagementQueries.cleanupTasks(
                on: postgres,
                namespaceID: namespaceID,
                queue: options.queue,
                ageSeconds: ageSeconds,
                limit: options.limit,
                logger: logger
            )

            // Explicitly release the advisory lock so other instances can
            // become leader on the next cycle (rather than waiting for the
            // connection to be returned to the pool).
            _ = try await conn.query(
                "SELECT pg_advisory_unlock(\(options.advisoryLockKey))",
                logger: logger
            )
        }
    }
}
