import Hummingbird
import Logging
import PostgresNIO
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct MetricsResponse: Codable, Sendable {
    struct Bucket: Codable, Sendable {
        /// ISO 8601 hour string e.g. "2026-05-01T14:00:00Z"
        let hour: String
        let count: Int
    }
    struct TaskTiming: Codable, Sendable {
        let queue: String
        let taskName: String
        let state: TaskState
        let count: Int
        /// Executions per second for this (queue, task, state) in the last broadcast cycle.
        /// `nil` when no ``AggregatedMetricsBuffer`` is wired in.
        let ratePerSec: Double?
        /// p50 execution time in milliseconds (±2 % relative error).
        let p50Ms: Double?
        /// p95 execution time in milliseconds.
        let p95Ms: Double?
        /// p99 execution time in milliseconds.
        let p99Ms: Double?
        /// p50 queue-wait time (time from PENDING to claimed), milliseconds.
        let p50WaitMs: Double?
        /// p95 queue-wait time, milliseconds.
        let p95WaitMs: Double?
    }
    let completed: Int
    let failed: Int
    let cancelled: Int
    let pending: Int
    let running: Int
    let avgDurationMs: Int?
    /// Total tasks completed or failed per second across all queues in the last broadcast cycle.
    /// `nil` when no ``AggregatedMetricsBuffer`` is wired in or the broadcast cache is stale.
    let throughputPerSec: Double?
    /// Completed tasks per hour for the last 24 h.
    let throughputPerHour: [Bucket]
    /// Failed tasks per hour for the last 24 h.
    let errorRatePerHour: [Bucket]
    /// Per-(queue, task) latency percentiles from DDSketch.
    /// Present only when ``StrandMetricsLoop`` and ``AggregatedMetricsBuffer``
    /// are wired in and at least one task completed since the last broadcast.
    let taskTimings: [TaskTiming]?
    /// The time window in hours for terminal counts and charts (1, 6, 24, or 168).
    let windowHours: Int
}
extension MetricsResponse: ResponseCodable {}

struct MetricsRoutes {
    let postgres: PostgresClient
    let defaultNamespaceID: String
    let logger: Logger
    let cache: MetricsCache?

    func register(on router: some RouterMethods<StrandRequestContext>) {

        // GET /api/:namespace/metrics
        router.get("metrics") { req, ctx -> MetricsResponse in
            let ns = ctx.namespaceID

            // Time window for terminal counts and hourly charts.
            // Valid values: 1, 6, 24, 168 (7 days). Default: 24.
            let rawHours = req.uri.queryParameters.get("hours").flatMap(Int.init) ?? 24
            let validHours = [1, 6, 24, 168]
            let hours = validHours.min(by: { abs($0 - rawHours) < abs($1 - rawHours) }) ?? 24
            let cutoff = Date(timeIntervalSinceNow: -Double(hours) * 3600)
            let useDaily = hours > 24

            // ── Live counts: cache XOR DB ─────────────────────────────────────────────────────
            //
            // StrandMetricsLoop broadcasts PENDING/RUNNING/SLEEPING/WAITING
            // counts for every queue every 5 s.  MetricsBroadcastListener
            // receives and caches them.  When the cache is fresh we serve
            // live counts from memory with zero DB queries.
            //
            // The broadcast is scoped to a namespace (broadcast.namespace).
            // We sum across all queues in the broadcast to get namespace totals.
            let pending: Int
            let running: Int

            if let broadcast = self.cache?.current(forNamespace: ns) {
                // Cache hit — no DB query at all for live counts.
                pending = broadcast.queues.reduce(0) { $0 + $1.pending }
                running = broadcast.queues.reduce(0) {
                    $0 + $1.running + $1.sleeping + $1.waiting
                }
            } else {
                // Cache miss or stale — query DB directly.
                // Both states use strand_tasks_ns_queue_state_idx.
                let liveStream = try await self.postgres.query(
                    """
                    SELECT
                      (SELECT COUNT(*) FROM strand.tasks
                       WHERE namespace_id = \(ns) AND state = 'PENDING') AS pending,
                      (SELECT COUNT(*) FROM strand.tasks
                       WHERE namespace_id = \(ns)
                         AND state IN ('RUNNING','SLEEPING','WAITING')) AS running
                    """,
                    logger: self.logger
                )
                if let row = try await liveStream.first(where: { _ in true }) {
                    var col = row.makeIterator()
                    pending = try col.next()!.decode(Int.self, context: .default)
                    running = try col.next()!.decode(Int.self, context: .default)
                } else {
                    pending = 0
                    running = 0
                }
            }

            // ── Terminal counts + avg duration (last 24 h) ──────────────────────────
            //
            // Always queried from the DB: the 24 h window is bounded and each
            // state uses its own partial index so these are fast regardless of
            // total table size:
            //   COMPLETED → completed_at  strand_tasks_completed_at_idx
            //   FAILED    → created_at    strand_tasks_failed_idx
            //   CANCELLED → cancelled_at  strand_tasks_cancelled_at_idx
            let summaryStream = try await self.postgres.query(
                """
                SELECT
                  (SELECT COUNT(*) FROM strand.tasks
                   WHERE namespace_id = \(ns)
                     AND state = 'COMPLETED'
                     AND completed_at >= \(cutoff)) AS completed,

                  (SELECT COUNT(*) FROM strand.tasks
                   WHERE namespace_id = \(ns)
                     AND state = 'FAILED'
                     AND created_at >= \(cutoff)) AS failed,

                  (SELECT COUNT(*) FROM strand.tasks
                   WHERE namespace_id = \(ns)
                     AND state = 'CANCELLED'
                     AND cancelled_at >= \(cutoff)) AS cancelled,

                  (SELECT AVG(EXTRACT(EPOCH FROM (completed_at - created_at)) * 1000)::bigint
                   FROM strand.tasks
                   WHERE namespace_id = \(ns)
                     AND state = 'COMPLETED'
                     AND completed_at >= \(cutoff)) AS avg_ms
                """,
                logger: self.logger
            )

            var completed = 0
            var failed = 0
            var cancelled = 0
            var avgDurationMs: Int? = nil
            if let row = try await summaryStream.first(where: { _ in true }) {
                var col = row.makeIterator()
                completed = try col.next()!.decode(Int.self, context: .default)
                failed = try col.next()!.decode(Int.self, context: .default)
                cancelled = try col.next()!.decode(Int.self, context: .default)
                avgDurationMs = try col.next()!.decode(Int?.self, context: .default)
            }

            // ── Hourly throughput (completed tasks) ───────────────────────────────────────
            //
            // Bucket by completed_at (not created_at) so the partial index is
            // usable and so the bucket represents when tasks *finished*, not
            // when they were enqueued.
            let throughputQuery: PostgresQuery
            if useDaily {
                throughputQuery = """
                    SELECT date_trunc('day', completed_at) AS bucket, COUNT(*) AS cnt
                    FROM strand.tasks
                    WHERE namespace_id = \(ns)
                      AND state = 'COMPLETED'
                      AND completed_at >= \(cutoff)
                    GROUP BY 1 ORDER BY 1
                    """
            } else {
                throughputQuery = """
                    SELECT date_trunc('hour', completed_at) AS bucket, COUNT(*) AS cnt
                    FROM strand.tasks
                    WHERE namespace_id = \(ns)
                      AND state = 'COMPLETED'
                      AND completed_at >= \(cutoff)
                    GROUP BY 1 ORDER BY 1
                    """
            }
            let throughputStream = try await self.postgres.query(throughputQuery, logger: self.logger)
            var throughput: [MetricsResponse.Bucket] = []
            for try await row in throughputStream {
                var col = row.makeIterator()
                let hour = try col.next()!.decode(Date.self, context: .default)
                let cnt = try col.next()!.decode(Int.self, context: .default)
                throughput.append(.init(hour: hour.ISO8601Format(), count: cnt))
            }

            // ── Hourly error rate (failed tasks) ────────────────────────────────────────────
            //
            // FAILED tasks have no failed_at column so created_at is used;
            // strand_tasks_failed_idx covers (namespace_id, queue, created_at DESC)
            // WHERE state = 'FAILED' so this is index-bound.
            let errorQuery: PostgresQuery
            if useDaily {
                errorQuery = """
                    SELECT date_trunc('day', created_at) AS bucket, COUNT(*) AS cnt
                    FROM strand.tasks
                    WHERE namespace_id = \(ns)
                      AND state = 'FAILED'
                      AND created_at >= \(cutoff)
                    GROUP BY 1 ORDER BY 1
                    """
            } else {
                errorQuery = """
                    SELECT date_trunc('hour', created_at) AS bucket, COUNT(*) AS cnt
                    FROM strand.tasks
                    WHERE namespace_id = \(ns)
                      AND state = 'FAILED'
                      AND created_at >= \(cutoff)
                    GROUP BY 1 ORDER BY 1
                    """
            }
            let errorStream = try await self.postgres.query(errorQuery, logger: self.logger)
            var errors: [MetricsResponse.Bucket] = []
            for try await row in errorStream {
                var col = row.makeIterator()
                let hour = try col.next()!.decode(Date.self, context: .default)
                let cnt = try col.next()!.decode(Int.self, context: .default)
                errors.append(.init(hour: hour.ISO8601Format(), count: cnt))
            }

            // ── DDSketch percentiles ────────────────────────────────────────────────────────
            //
            // Present only when the broadcast includes timing snapshots from
            // the AggregatedMetricsBuffer.  Each snapshot carries a serialised
            // DDSketch; we compute p50/p95/p99 inline (microseconds of CPU).
            // ── avgDurationMs from DDSketch (gap 3) ──────────────────────────────
            // When the cache has fresh timing data use weighted p50 across all
            // completed tasks rather than the DB AVG (which is for last 24h).
            // DB avgDurationMs is already computed above but may be overridden here.
            if let broadcast = self.cache?.current(forNamespace: ns),
                let timings = broadcast.timings
            {
                let completedTimings = timings.filter { $0.state == .completed }
                let totalCount = completedTimings.reduce(0) { $0 + $1.count }
                if totalCount > 0 {
                    let weightedSum = completedTimings.reduce(0.0) { sum, t in
                        sum + (t.execTime.quantile(0.50) ?? 0) * Double(t.count)
                    }
                    avgDurationMs = Int(weightedSum / Double(totalCount))
                }
            }

            // ── Throughput rate + DDSketch percentiles ────────────────────────
            // Both sourced from the broadcast cache so there are zero extra
            // DB queries when the cache is warm.
            var throughputPerSec: Double? = nil
            let taskTimings: [MetricsResponse.TaskTiming]?
            if let broadcast = self.cache?.current(forNamespace: ns) {
                // Namespace-wide throughput: sum queue-level rates from the broadcast.
                let total = broadcast.queues.compactMap(\.throughputPerSec).reduce(0, +)
                throughputPerSec = total > 0 ? total : nil

                if let timings = broadcast.timings, !timings.isEmpty {
                    taskTimings = timings.map { t in
                        MetricsResponse.TaskTiming(
                            queue: t.queue,
                            taskName: t.taskName,
                            state: t.state,
                            count: t.count,
                            ratePerSec: t.ratePerSec,
                            p50Ms: t.execTime.quantile(0.50),
                            p95Ms: t.execTime.quantile(0.95),
                            p99Ms: t.execTime.quantile(0.99),
                            p50WaitMs: t.waitTime?.quantile(0.50),
                            p95WaitMs: t.waitTime?.quantile(0.95)
                        )
                    }
                } else {
                    taskTimings = nil
                }
            } else {
                taskTimings = nil
            }

            return MetricsResponse(
                completed: completed,
                failed: failed,
                cancelled: cancelled,
                pending: pending,
                running: running,
                avgDurationMs: avgDurationMs,
                throughputPerSec: throughputPerSec,
                throughputPerHour: throughput,
                errorRatePerHour: errors,
                taskTimings: taskTimings,
                windowHours: hours
            )
        }
    }
}
