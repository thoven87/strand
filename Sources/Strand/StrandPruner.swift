import Logging
import Metrics
public import PostgresNIO
public import ServiceLifecycle

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Options

/// Configuration for ``StrandPruner``.
public struct StrandPrunerOptions: Sendable {
    /// How often to run a fine-grained DELETE prune cycle. Default: 30 s.
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
    /// Postgres advisory lock key used for leader election of the fine-grained
    /// DELETE prune cycle. Must be identical across every ``StrandPruner``
    /// instance in the cluster.
    /// Default: a stable constant derived from "StrandPN".
    public var advisoryLockKey: Int64
    /// Postgres advisory lock key used for leader election of the partition
    /// management cycle (DDL: create/drop partitions, ANALYZE).
    /// Kept separate from ``advisoryLockKey`` so row-level cleanup and DDL
    /// never compete for the same lock.
    /// Default: derived from ``advisoryLockKey`` XOR `"PART"`.
    public var partitionAdvisoryLockKey: Int64
    /// How often to run partition management (create future partitions, drop
    /// expired ones, ANALYZE parent tables). Default: 12 h.
    ///
    /// Partition creation is idempotent so running it more often is safe.
    /// ANALYZE is cheap on empty-ish parent tables; the real work is on child
    /// partitions which autovacuum handles automatically.
    public var partitionManagementInterval: Duration

    public init(
        interval: Duration = .seconds(30),
        maxAge: Duration? = nil,
        limit: Int = 10_000,
        queue: String? = nil,
        advisoryLockKey: Int64 = 0x5374_7261_6E64_504E,  // "StrandPN"
        partitionManagementInterval: Duration = .seconds(12 * 3600)
    ) {
        self.interval = interval
        self.maxAge = maxAge
        self.limit = limit
        self.queue = queue
        self.advisoryLockKey = advisoryLockKey
        self.partitionAdvisoryLockKey = advisoryLockKey ^ 0x5041_5254  // XOR "PART"
        self.partitionManagementInterval = partitionManagementInterval
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
/// `pg_try_advisory_lock`. Non-leaders skip the cycle silently.
///
/// ```swift
/// // Prune all namespaces (default) — retention read from strand.namespaces.retention_days
/// let pruner = StrandPruner(postgres: postgres)
///
/// // Prune a single namespace with an explicit retention override:
/// let pruner = StrandPruner(
///     postgres: postgres,
///     namespaceID: "production",
///     options: StrandPrunerOptions(maxAge: .seconds(7 * 24 * 3_600))
/// )
/// let group = ServiceGroup(services: [postgres, worker, pruner])
/// ```
public struct StrandPruner: Service {
    private let postgres: PostgresClient
    /// Namespace to prune. `nil` = prune every namespace in `strand.namespaces`
    /// each cycle, each using its own `retention_days` setting.
    private let namespaceID: String?
    private let options: StrandPrunerOptions
    private let logger: Logger

    public init(
        postgres: PostgresClient,
        namespaceID: String? = nil,
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
                "strand.namespace": .string(namespaceID ?? "*"),
                "strand.interval": .string("\(options.interval)"),
                "strand.limit": .stringConvertible(options.limit),
                "strand.partition_interval": .string("\(options.partitionManagementInterval)"),
            ]
        )
        defer { logger.info("pruner stopped") }

        // ── Startup: partition housekeeping before serving any traffic ────────
        //
        // 1. Finalize orphaned DETACH CONCURRENTLY operations (crash recovery).
        // 2. Ensure current + next 2 months of partitions exist.
        // 3. ANALYZE parent tables — autovacuum never touches them.
        //    Without this the query planner has zero statistics and falls back
        //    to sequential scans on the claim path.
        do {
            try await PartitionQueries.finalizeOrphanedDetaches(on: postgres, logger: logger)
            try await PartitionQueries.ensurePartitions(on: postgres, logger: logger)
            try await PartitionQueries.analyzeParentTables(on: postgres, logger: logger)
        } catch {
            logger.trace(
                "pruner: startup partition management failed",
                metadata: ["error": .string(strandErrorMessage(error))]
            )
            // Non-fatal: continue, the next cycle will retry.
        }

        // ── Two concurrent loops ──────────────────────────────────────────────
        //
        // • Short loop  (options.interval, default 30 s):
        //     Leader-gated fine-grained DELETE of terminal rows within the
        //     current partition. Handles rows that are within the retention window
        //     but past their age — whole-partition drops can't help here.
        //
        // • Long loop   (options.partitionManagementInterval, default 12 h):
        //     Leader-gated partition creation, DROP TABLE for expired months,
        //     and ANALYZE on parent tables. Low frequency is fine because
        //     partition creation is idempotent and DROP TABLE is instant.

        await withTaskGroup(of: Void.self) { group in
            // Short loop
            group.addTask {
                while !Task.isShuttingDownGracefully && !Task.isCancelled {
                    try? await cancelWhenGracefulShutdown {
                        try await Task.sleep(for: self.options.interval)
                    }
                    guard !Task.isShuttingDownGracefully && !Task.isCancelled else { break }
                    do { try await self.tryPrune() } catch {
                        self.logger.trace(
                            "pruner cycle failed",
                            metadata: ["error": .string(strandErrorMessage(error))]
                        )
                    }
                }
            }

            // Long loop
            group.addTask {
                while !Task.isShuttingDownGracefully && !Task.isCancelled {
                    try? await cancelWhenGracefulShutdown {
                        try await Task.sleep(for: self.options.partitionManagementInterval)
                    }
                    guard !Task.isShuttingDownGracefully && !Task.isCancelled else { break }
                    do { try await self.tryManagePartitions() } catch {
                        self.logger.trace(
                            "pruner: partition management cycle failed",
                            metadata: ["error": .string(strandErrorMessage(error))]
                        )
                    }
                }
            }
        }
    }

    // MARK: - Private

    /// Leader-gated partition management cycle (runs every 12 h):
    ///   1. Create partitions for the current month + next 2 months.
    ///   2. Drop expired whole-month partitions (DETACH CONCURRENTLY + DROP).
    ///   3. ANALYZE parent tables (autovacuum skips them — critical!).
    private func tryManagePartitions() async throws {
        // Hold the advisory lock for the full duration of this function so that
        // concurrent pruner instances cannot race on DDL (partition creation,
        // DETACH PARTITION, DROP TABLE, ANALYZE).
        //
        // The lock is session-level (not transaction-level), so it stays held
        // even when DDL sub-calls open their own connections from the pool —
        // DETACH PARTITION CONCURRENTLY must run outside a transaction block,
        // so those sub-calls use separate raw connections as required.
        try await postgres.withConnection { conn in
            let lockKey = self.options.partitionAdvisoryLockKey

            let lockStream = try await conn.query(
                "SELECT pg_try_advisory_lock(\(lockKey))",
                logger: self.logger
            )
            guard let lockRow = try await lockStream.first(where: { _ in true }) else { return }
            var lockCol = lockRow.makeIterator()
            let acquired = try lockCol.next()!.decode(Bool.self, context: .default)
            guard acquired else {
                self.logger.debug("pruner: not leader — skipping partition management")
                return
            }

            // Explicit unlock when this block exits (success or failure).
            // Session-level locks are also released when the connection is
            // returned to the pool, but explicit unlock is cleaner.
            defer {
                Task {
                    _ = try? await conn.query(
                        "SELECT pg_advisory_unlock(\(lockKey))",
                        logger: self.logger
                    )
                }
            }

            // All DDL runs while the advisory lock is held.
            // ensurePartitions and dropExpiredPartitions open their own
            // connections from the pool (DETACH CONCURRENTLY requirement);
            // that is safe — the advisory lock on `conn` prevents other
            // pruner instances from starting concurrently.
            try await PartitionQueries.ensurePartitions(on: self.postgres, logger: self.logger)

            // Cutoff: options.maxAge takes precedence; otherwise read retention_days.
            // Partition drops affect ALL namespaces simultaneously, so in multi-namespace
            // mode we use the minimum retention_days across all namespaces — a partition
            // cannot be dropped if any namespace still needs data from it.
            let cutoff: Date
            if let maxAge = self.options.maxAge {
                cutoff = Date().addingTimeInterval(-maxAge.timeInterval)
            } else {
                let days: Int
                if let ns = self.namespaceID {
                    days = try await ManagementQueries.retentionDays(
                        namespaceID: ns,
                        on: conn,
                        logger: self.logger
                    )
                } else {
                    days = try await ManagementQueries.minimumRetentionDays(
                        on: conn,
                        logger: self.logger
                    )
                }
                cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            }
            let dropped = try await PartitionQueries.dropExpiredPartitions(
                on: self.postgres,
                olderThan: cutoff,
                logger: self.logger
            )
            if dropped > 0 {
                self.logger.info(
                    "partition management: dropped expired partitions",
                    metadata: [
                        "strand.namespace": .string(self.namespaceID ?? "*"),
                        "strand.dropped": .stringConvertible(dropped),
                    ]
                )
                Counter(
                    label: StrandMetrics.prunerPartitionsDropped,
                    dimensions: [("namespace", self.namespaceID ?? "*")]
                ).increment(by: dropped)
            }

            // ANALYZE parent tables — autovacuum never touches them.
            try await PartitionQueries.analyzeParentTables(on: self.postgres, logger: self.logger)
        }
    }

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
                    metadata: ["strand.namespace": .string(namespaceID ?? "*")]
                )
                return
            }

            // We are the leader for this cycle. Run cleanup on the main pool
            // (it will use a separate connection from the pool; that's fine — the
            // advisory lock is held here just to prevent other instances from
            // starting a concurrent cleanup).
            //
            // Determine which namespaces to prune this cycle. When namespaceID
            // is nil, query the full namespace list and prune each in turn,
            // using each namespace's own retention_days.
            let namespacesToPrune: [String]
            if let ns = namespaceID {
                namespacesToPrune = [ns]
            } else {
                namespacesToPrune = try await ManagementQueries.allNamespaceIDs(
                    on: conn,
                    logger: logger
                )
            }

            for ns in namespacesToPrune {
                let ageSeconds: Int
                if let maxAge = options.maxAge {
                    ageSeconds = Int(maxAge.components.seconds)
                } else {
                    let days = try await ManagementQueries.retentionDays(
                        namespaceID: ns,
                        on: conn,
                        logger: logger
                    )
                    ageSeconds = days * 24 * 3600
                }

                let deletedTasks = try await ManagementQueries.cleanupTasks(
                    on: postgres,
                    namespaceID: ns,
                    queue: options.queue,
                    ageSeconds: ageSeconds,
                    limit: options.limit,
                    logger: logger
                )
                if deletedTasks > 0 {
                    Counter(
                        label: StrandMetrics.prunerTasksDeleted,
                        dimensions: [("namespace", ns)]
                    ).increment(by: deletedTasks)
                }

                // Events are not tied to tasks (no FK), so they are not cascade-
                // deleted when tasks are pruned. Prune them separately.
                let deletedEvents = try await ManagementQueries.cleanupEvents(
                    on: postgres,
                    namespaceID: ns,
                    ageSeconds: ageSeconds,
                    limit: options.limit,
                    logger: logger
                )
                if deletedEvents > 0 {
                    Counter(
                        label: StrandMetrics.prunerEventsDeleted,
                        dimensions: [("namespace", ns)]
                    ).increment(by: deletedEvents)
                }
            }

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
