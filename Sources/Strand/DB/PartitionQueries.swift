import Logging
import PostgresNIO

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - PartitionQueries

/// DDL helpers for managing monthly range partitions on `strand.runs`,
/// `strand.task_logs`, and `strand.workflow_history`. Called by ``StrandPruner``
/// at startup and every 12 hours.
///
/// ## Why manual ANALYZE matters
///
/// Postgres autovacuum silently skips partitioned **parent** tables — it only
/// processes child partitions. Without a periodic `ANALYZE strand.runs`, the
/// query planner has zero statistics for the parent and produces catastrophically
/// wrong row estimates (Hatchet observed 6 000 000× off in production), causing
/// the claim path to fall back to sequential scans under load. Every function in
/// this file that touches the schema also calls ``analyzeParentTables(on:logger:)``
/// to keep planner statistics current.
///
/// ## DETACH PARTITION CONCURRENTLY
///
/// `DETACH PARTITION … CONCURRENTLY` takes a lighter lock than a plain
/// `DETACH PARTITION` — it does not block concurrent reads or writes on the
/// parent table while running. The trade-off is that it is **non-transactional**
/// and must run on a raw connection (not inside `BEGIN`). If the process crashes
/// mid-detach, an orphaned pending-detach partition is left behind; call
/// ``finalizeOrphanedDetaches(on:logger:)`` to clean those up before retrying.
package enum PartitionQueries {

    /// The partitioned tables that ``StrandPruner`` manages.
    ///
    /// `strand.runs` and `strand.task_logs` are both partitioned by `created_at`
    /// (monthly RANGE). `strand.workflow_history` is intentionally non-partitioned
    /// because its `batchAppendHistory` query uses
    /// `ON CONFLICT (task_id, seq) DO NOTHING` for idempotency — a unique constraint
    /// that cannot exist without the partition key, which would break the ON CONFLICT
    /// clause. Retention for history is handled by cascade DELETE from strand.tasks.
    ///
    /// `task_logs` has no FK to `strand.tasks` — partition DROP TABLE handles
    /// cleanup automatically when StrandPruner drops expired months.
    static let partitionedTables: [String] = ["runs", "task_logs"]

    // MARK: - Ensure partitions exist

    /// Creates monthly partitions for `runs` and `task_logs` covering the current
    /// month plus the next `monthsAhead` months. Idempotent — already-existing
    /// partitions are silently skipped.
    ///
    /// Called at startup and every 12 h by ``StrandPruner``.
    static func ensurePartitions(
        on client: PostgresClient,
        monthsAhead: Int = 2,
        logger: Logger
    ) async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()

        for table in partitionedTables {
            for offset in 0...monthsAhead {
                guard
                    let monthDate = cal.date(
                        byAdding: .month,
                        value: offset,
                        to: cal.startOfDay(for: now)
                    )
                else { continue }
                // Snap to month start
                let components = cal.dateComponents([.year, .month], from: monthDate)
                guard let monthStart = cal.date(from: components) else { continue }

                let stream = try await client.query(
                    "SELECT strand.create_range_partition(\(table), \(monthStart)::DATE)",
                    logger: logger
                )
                if let row = try await stream.first(where: { _ in true }) {
                    var col = row.makeIterator()
                    let created = try col.next()!.decode(Bool.self, context: .default)
                    if created {
                        logger.info(
                            "partition created",
                            metadata: [
                                "strand.table": .string("strand.\(table)"),
                                "strand.partition": .string("\(table)_\(partitionSuffix(monthStart))"),
                            ]
                        )
                    }
                }
            }
        }
    }

    // MARK: - Drop expired partitions

    /// Detaches and drops all monthly partitions whose month is strictly before
    /// `cutoffDate`. Uses `DETACH PARTITION … CONCURRENTLY` (non-transactional,
    /// raw connection) followed by `DROP TABLE`.
    ///
    /// Returns the number of partitions dropped.
    @discardableResult
    static func dropExpiredPartitions(
        on client: PostgresClient,
        olderThan cutoffDate: Date,
        logger: Logger
    ) async throws -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Snap cutoff to month start so we only drop whole months.
        let comps = cal.dateComponents([.year, .month], from: cutoffDate)
        guard let cutoffMonth = cal.date(from: comps) else { return 0 }

        var dropped = 0

        for table in partitionedTables {
            let stream = try await client.query(
                "SELECT partition_name FROM strand.list_partitions_before(\(table), \(cutoffMonth)::DATE)",
                logger: logger
            )
            var names: [String] = []
            for try await row in stream {
                var col = row.makeIterator()
                names.append(try col.next()!.decode(String.self, context: .default))
            }

            for partitionName in names {
                do {
                    try await client.withConnection { conn in
                        try await detachAndDrop(
                            on: conn,
                            parentTable: table,
                            partitionName: partitionName,
                            logger: logger
                        )
                    }
                    dropped += 1
                    logger.info(
                        "partition dropped",
                        metadata: [
                            "strand.table": .string("strand.\(table)"),
                            "strand.partition": .string("strand.\(partitionName)"),
                        ]
                    )
                } catch {
                    // Log and continue — a failed drop is not fatal; it will be
                    // retried on the next cycle. Call finalizeOrphanedDetaches
                    // if CONCURRENTLY leaves a pending-detach orphan.
                    logger.error(
                        "failed to drop partition — will retry next cycle",
                        metadata: [
                            "strand.partition": .string(partitionName),
                            "error": .string(strandErrorMessage(error)),
                        ]
                    )
                }
            }
        }

        return dropped
    }

    // MARK: - ANALYZE parent tables

    /// Runs `ANALYZE` on the partitioned parent tables.
    ///
    /// **Must be called periodically** — Postgres autovacuum never analyzes
    /// partitioned parent tables, only their child partitions. Without this call
    /// the query planner uses stale (or zero) statistics for the parent, producing
    /// wrong row estimates that can degrade the hot claim path to sequential scans.
    ///
    /// Called at startup and every 12 h by ``StrandPruner``.
    static func analyzeParentTables(
        on client: PostgresClient,
        logger: Logger
    ) async throws {
        // ANALYZE cannot run inside a transaction on partitioned tables;
        // client.query starts its own implicit transaction which is fine here.
        // strand.runs and strand.task_logs are partitioned — autovacuum skips their
        // parent tables. workflow_history is a plain table and autovacuum handles it.
        for table in partitionedTables {
            try await client.query(
                "ANALYZE strand.\(unescaped: table)",
                logger: logger
            )
            logger.debug(
                "ANALYZE complete on parent table",
                metadata: ["strand.table": .string("strand.\(table)")]
            )
        }
    }

    // MARK: - Orphan cleanup

    /// Finalizes any partitions left in a pending-detach state by a prior
    /// `DETACH PARTITION … CONCURRENTLY` that was interrupted (e.g. process crash).
    ///
    /// Safe to call on every startup — it is a no-op when there are no orphans.
    static func finalizeOrphanedDetaches(
        on client: PostgresClient,
        logger: Logger
    ) async throws {
        // The pending-detach mechanism changed across major versions:
        //   PG13 and earlier — DETACH PARTITION CONCURRENTLY doesn't exist; skip.
        //   PG14–16          — pg_class.relisbeingdetached tracks pending detach.
        //   PG17+            — pg_inherits.inhdetachpending replaced relisbeingdetached.
        let verStream = try await client.query(
            "SELECT current_setting('server_version_num')::int",
            logger: logger
        )
        guard let verRow = try await verStream.first(where: { _ in true }) else { return }
        var verCol = verRow.makeIterator()
        let versionNum = (try? verCol.next()?.decode(Int.self, context: .default)) ?? 0

        guard versionNum >= 140_000 else {
            logger.debug("pruner: PostgreSQL < 14 — skipping orphaned-detach finalization")
            return
        }

        // Build a version-appropriate WHERE predicate for pending-detach state.
        let pendingFilter = versionNum >= 170_000
            ? "i.inhdetachpending = TRUE"      // PG17+
            : "child.relisbeingdetached = TRUE" // PG14–16

        let stream = try await client.query(
            """
            SELECT n.nspname || '.' || parent.relname AS parent_name,
                   n.nspname || '.' || child.relname  AS child_name
            FROM   pg_inherits i
            JOIN   pg_class parent ON parent.oid = i.inhparent
            JOIN   pg_class child  ON child.oid  = i.inhrelid
            JOIN   pg_namespace n  ON n.oid      = parent.relnamespace
            WHERE  \(unescaped: pendingFilter)
              AND  n.nspname = 'strand'
            """,
            logger: logger
        )
        var orphans: [(parent: String, child: String)] = []
        for try await row in stream {
            var col = row.makeIterator()
            let parent = try col.next()!.decode(String.self, context: .default)
            let child = try col.next()!.decode(String.self, context: .default)
            orphans.append((parent: parent, child: child))
        }

        for orphan in orphans {
            logger.warning(
                "finalizing orphaned partition detach",
                metadata: [
                    "strand.parent": .string(orphan.parent),
                    "strand.partition": .string(orphan.child),
                ]
            )
            try await client.withConnection { conn in
                // FINALIZE completes the interrupted CONCURRENTLY detach.
                // values come from pg_class (system catalog), not user input.
                try await conn.query(
                    "ALTER TABLE \(unescaped: orphan.parent) DETACH PARTITION \(unescaped: orphan.child) FINALIZE",
                    logger: logger
                )
                // Extract the unqualified partition name for the safe SQL function.
                let childName = orphan.child.split(separator: ".").last.map(String.init) ?? orphan.child
                let parentName = orphan.parent.split(separator: ".").last.map(String.init) ?? orphan.parent
                try await conn.query(
                    "SELECT strand.drop_partition(\(parentName), \(childName))",
                    logger: logger
                )
            }
        }
    }

    // MARK: - Private

    /// `DETACH PARTITION … CONCURRENTLY` + `DROP TABLE` on a raw connection.
    ///
    /// Must NOT be called inside a transaction — CONCURRENTLY is non-transactional.
    ///
    /// ## Why DETACH uses `\(unescaped:)`
    ///
    /// PostgreSQL's bind-parameter syntax (`$1`, `$2`) only works for **data
    /// values**, never for identifiers (schema/table names). There is no
    /// parameterized form for `ALTER TABLE … DETACH PARTITION`.
    /// Additionally, `DETACH PARTITION CONCURRENTLY` is banned inside any
    /// PL/pgSQL function (Postgres raises "ERROR: DETACH PARTITION CONCURRENTLY
    /// cannot run inside a transaction block"), so we cannot route it through a
    /// server-side SQL function either.
    ///
    /// PostgresNIO's `\(unescaped: value)` interpolation appends the string
    /// directly to the SQL without creating a bind parameter — the right tool
    /// for identifier injection. The values are safe because both `parentTable`
    /// and `partitionName` come exclusively from `strand.list_partitions_before`,
    /// which reads from the `pg_inherits` system catalog, not from user input.
    /// The DROP TABLE step delegates to `strand.drop_partition()` which uses
    /// `format('%I', …)` for proper server-side identifier quoting.
    private static func detachAndDrop(
        on conn: PostgresConnection,
        parentTable: String,
        partitionName: String,  // e.g. "runs_202601"
        logger: Logger
    ) async throws {
        // Step 1: DETACH CONCURRENTLY — use \(unescaped:) for identifier injection.
        // Values are from pg_inherits (system catalog), not user input.
        try await conn.query(
            "ALTER TABLE strand.\(unescaped: parentTable) DETACH PARTITION strand.\(unescaped: partitionName) CONCURRENTLY",
            logger: logger
        )
        // Step 2: DROP via the server-side function which uses format('%I').
        try await conn.query(
            "SELECT strand.drop_partition(\(parentTable), \(partitionName))",
            logger: logger
        )
    }

    /// Returns the `YYYYMM` suffix for a month-start date.
    private static func partitionSuffix(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d%02d", comps.year ?? 0, comps.month ?? 0)
    }
}
