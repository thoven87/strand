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
        /// Exact minimum execution time in milliseconds from DDSketch.
        let minMs: Double?
        /// Exact maximum execution time in milliseconds from DDSketch.
        let maxMs: Double?
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

            // ── Terminal counts + hourly charts — three concurrent DB queries ─────────────
            async let summaryTask = ManagementQueries.metricsSummary(
                on: self.postgres, namespaceID: ns, since: cutoff, logger: self.logger)
            async let throughputTask = ManagementQueries.metricsThroughput(
                on: self.postgres, namespaceID: ns, since: cutoff, useDaily: useDaily,
                logger: self.logger)
            async let errorTask = ManagementQueries.metricsErrorRate(
                on: self.postgres, namespaceID: ns, since: cutoff, useDaily: useDaily,
                logger: self.logger)

            let (summaryTuple, throughputBuckets, errorBuckets) =
                try await (summaryTask, throughputTask, errorTask)

            let completed  = summaryTuple.completed
            let failed     = summaryTuple.failed
            let cancelled  = summaryTuple.cancelled
            var avgDurationMs: Int? = nil

            let throughput = throughputBuckets.map {
                MetricsResponse.Bucket(hour: $0.bucket.ISO8601Format(), count: $0.count)
            }
            let errors = errorBuckets.map {
                MetricsResponse.Bucket(hour: $0.bucket.ISO8601Format(), count: $0.count)
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
                            p95WaitMs: t.waitTime?.quantile(0.95),
                            minMs: t.execTime.min,
                            maxMs: t.execTime.max
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

        // GET /api/:namespace/metrics/task/:taskName
        // Returns per-task DDSketch percentiles and counts for the named task.
        // Sourced from the broadcast cache (zero DB queries when cache is warm).
        router.get("metrics/task/:taskName") { _, ctx -> TaskMetricsResponse in
            let taskName = try ctx.parameters.require("taskName")
            let ns = ctx.namespaceID

            var execSketches: [DDSketch.Serialized] = []
            var waitSketches: [DDSketch.Serialized] = []
            var completedCount = 0
            var failedCount = 0
            var ratePerSec: Double = 0

            if let broadcast = self.cache?.current(forNamespace: ns),
                let timings = broadcast.timings
            {
                for t in timings where t.taskName == taskName {
                    switch t.state {
                    case .completed:
                        execSketches.append(t.execTime)
                        if let wt = t.waitTime { waitSketches.append(wt) }
                        completedCount += t.count
                        ratePerSec += t.ratePerSec
                    case .failed:
                        failedCount += t.count
                    default:
                        break
                    }
                }
            }

            let exec = DDSketch.Serialized.merged(execSketches)
            let wait = DDSketch.Serialized.merged(waitSketches)

            return TaskMetricsResponse(
                taskName: taskName,
                completedCount: completedCount,
                failedCount: failedCount,
                p50Ms: exec?.quantile(0.50),
                p95Ms: exec?.quantile(0.95),
                p99Ms: exec?.quantile(0.99),
                p50WaitMs: wait?.quantile(0.50),
                p95WaitMs: wait?.quantile(0.95),
                ratePerSec: ratePerSec > 0 ? ratePerSec : nil
            )
        }

        // GET /api/:namespace/metrics/latency
        // Returns exact OLAP latency percentiles from `strand.trace_spans` via
        // PERCENTILE_CONT, plus a time-bucketed series for trend charts.
        // Query parameters:
        //   hours     – lookback window in hours (1, 6, 24, 168); default 24
        //   limit     – max task names to return (default 50, capped at 500)
        //   taskName  – optional filter to a single task definition
        router.get("metrics/latency") { req, ctx -> LatencyResponse in
            let ns = ctx.namespaceID
            let rawHours = req.uri.queryParameters.get("hours").flatMap(Int.init) ?? 24
            let validHours = [1, 6, 24, 168]
            let hours = validHours.min(by: { abs($0 - rawHours) < abs($1 - rawHours) }) ?? 24
            let limit = req.uri.queryParameters.get("limit").flatMap(Int.init) ?? 50
            let taskName = req.uri.queryParameters.get("taskName")

            do {
                async let perTaskRows = ManagementQueries.latencyPercentiles(
                    on: self.postgres,
                    namespaceID: ns,
                    hours: hours,
                    limit: limit,
                    logger: self.logger
                )
                async let bucketRows = ManagementQueries.latencyTimeSeries(
                    on: self.postgres,
                    namespaceID: ns,
                    hours: hours,
                    taskName: taskName,
                    logger: self.logger
                )

                let (tasks, buckets) = try await (perTaskRows, bucketRows)

                return LatencyResponse(
                    tasks: tasks.map(LatencyTaskResponse.init(from:)),
                    timeSeries: buckets.map(LatencyBucketResponse.init(from:)),
                    windowHours: hours
                )
            } catch {
                ctx.logger.error(
                    "Failed to get metrics",
                    metadata: ["error": "\(String(reflecting: error))"]
                )
                throw HTTPError(.internalServerError, message: "Failed to get metrics: \(error)")
            }
        }
    }
}
