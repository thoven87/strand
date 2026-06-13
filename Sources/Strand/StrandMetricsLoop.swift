import Logging
import NIOCore
public import ServiceLifecycle

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Broadcast payload

/// Live task-count snapshot for one namespace, broadcast every
/// ``StrandMetricsOptions/interval`` via `pg_notify('strand_metrics', ...)`.
///
/// Consumed by ``MetricsBroadcastListener`` in the dashboard server so
/// ``MetricsRoutes`` never issues on-demand COUNT queries.
public struct StrandMetricsBroadcast: Codable, Sendable {
    /// The namespace these counts belong to.
    public let namespace: String
    /// Unix timestamp (seconds since 1970) when this snapshot was computed.
    public let at: Double
    /// One entry per active queue — live task counts.
    public let queues: [QueueSnapshot]
    /// Per-(queue, task) execution-time distributions flushed since the last
    /// broadcast.  `nil` when no tasks completed in this cycle.
    public let timings: [TimingSnapshot]?

    /// Explicit public memberwise initializer required because Swift only
    /// synthesises an `internal` memberwise init for public structs.
    public init(
        namespace: String,
        at: Double,
        queues: [QueueSnapshot],
        timings: [TimingSnapshot]?
    ) {
        self.namespace = namespace
        self.at = at
        self.queues = queues
        self.timings = timings
    }

    public struct QueueSnapshot: Codable, Sendable {
        public let queue: String
        public let pending: Int
        public let running: Int
        public let sleeping: Int
        public let waiting: Int
        /// Tasks completed or failed per second in the most recent broadcast cycle.
        /// `nil` when no ``AggregatedMetricsBuffer`` is wired into ``StrandMetricsLoop``.
        public let throughputPerSec: Double?
    }

    /// Execution-time distribution for one (queue, task name, state) triple.
    ///
    /// Completed and failed tasks are tracked separately so a task that
    /// always fails in 2 ms doesn't pollute the p95 of successful runs.
    public struct TimingSnapshot: Codable, Sendable {
        public let queue: String
        public let taskName: String
        /// Terminal status — `.completed` or `.failed`.
        public let state: TaskStatus
        /// Number of executions recorded in this cycle.
        public let count: Int
        /// Throughput rate for this (queue, task, state) in the current cycle.
        /// Computed as `count / broadcastIntervalSeconds`.
        public let ratePerSec: Double
        /// DDSketch of execution durations (milliseconds, ±2 % error).
        public let execTime: DDSketch.Serialized
        /// DDSketch of queue-wait durations — time from when the run became
        /// PENDING to when a worker claimed it.  `nil` when not available.
        public let waitTime: DDSketch.Serialized?
    }
}

// MARK: - Options

/// Configuration for ``StrandMetricsLoop``.
public struct StrandMetricsOptions: Sendable {
    /// How often to recompute and broadcast counts. Default: 5 s.
    public var interval: Duration
    /// Row-count threshold above which the loop switches from exact
    /// `COUNT(*)` to `strand.count_estimate()` (query-planner estimate,
    /// ~0.1 ms regardless of table size). Default: 50,000.
    public var estimateThreshold: Int
    /// Maximum number of (queue, task) timing entries included in each
    /// broadcast, sorted by execution count descending so the busiest tasks
    /// are always present.  Default: 20.
    public var maxTimingEntries: Int

    public init(
        interval: Duration = .seconds(5),
        estimateThreshold: Int = 50_000,
        maxTimingEntries: Int = 20
    ) {
        self.interval = interval
        self.estimateThreshold = estimateThreshold
        self.maxTimingEntries = maxTimingEntries
    }
}

// MARK: - Service

/// Background service that pre-computes live task counts and broadcasts them
/// via `pg_notify('strand_metrics', ...)` every ``StrandMetricsOptions/interval``.
///
/// Add it to your `ServiceGroup` alongside your workers and scheduler:
///
/// ```swift
/// let metricsLoop = StrandMetricsLoop(client: client)
///
/// let group = ServiceGroup(services: [
///     postgres, worker, scheduler, metricsLoop
/// ])
/// ```
///
/// The ``MetricsBroadcastListener`` in the dashboard server subscribes to the
/// broadcast and keeps an in-memory cache so ``MetricsRoutes`` never issues
/// COUNT queries per dashboard request.
///
/// ## Adaptive counting
///
/// For each `(queue, state)` pair, the loop remembers the previous measurement:
/// - Previous count < ``StrandMetricsOptions/estimateThreshold``:
///   exact `COUNT(*)` — fast via partial indexes for small tables.
/// - Previous count ≥ threshold: `strand.count_estimate()` — the query
///   planner's own statistics, sub-millisecond at any table size.
///
/// The threshold decision is updated each cycle, so queues that grow large
/// automatically migrate to the estimate path without any configuration change.
public struct StrandMetricsLoop: Service {
    private let client: StrandClient
    private let options: StrandMetricsOptions
    /// Shared buffer written by ``StrandWorker`` after each task completes.
    /// Flushed once per broadcast cycle and included in the payload.
    private let metricsBuffer: AggregatedMetricsBuffer?

    public init(
        client: StrandClient,
        options: StrandMetricsOptions = .init(),
        metricsBuffer: AggregatedMetricsBuffer? = nil
    ) {
        self.client = client
        self.options = options
        self.metricsBuffer = metricsBuffer
    }

    public func run() async throws {
        let logger = client.logger
        logger.info("metrics loop starting")
        defer { logger.info("metrics loop stopped") }

        // Per "queue/state" count from the previous cycle — drives the
        // exact-vs-estimate decision on the next one.
        var previousCounts: [String: Int] = [:]

        // EWMA-smoothed throughput rate per queue (tasks/second).
        // α = 0.25 → effective window ≈ (1-α)/α × interval = 3 × 5 s = 15 s.
        // A raw 5 s window is too noisy for low-throughput jobs (e.g. one 11 s
        // VoiceTraining job completes every other cycle, so the unsmoothed rate
        // alternates between 0/s and 0.4/s). EWMA shows a stable ~0.2/s.
        var smoothedRates: [String: Double] = [:]

        while !Task.isShuttingDownGracefully && !Task.isCancelled {
            // cancelWhenGracefulShutdown exits the sleep quickly on shutdown
            // without leaking the NIO runTimer continuation.
            try? await cancelWhenGracefulShutdown {
                try await Task.sleep(for: self.options.interval)
            }
            guard !Task.isShuttingDownGracefully && !Task.isCancelled else { break }

            do {
                try await broadcast(previousCounts: &previousCounts, smoothedRates: &smoothedRates)
            } catch {
                logger.error(
                    "metrics loop broadcast failed",
                    metadata: ["error": "\(String(reflecting: error))"]
                )
            }
        }
    }

    // MARK: - Private

    private func broadcast(
        previousCounts: inout [String: Int],
        smoothedRates: inout [String: Double]
    ) async throws {
        // listQueues + task counts in one round-trip — see allQueueCounts.
        let (queues, counts) = try await allQueueCounts(prev: previousCounts)
        guard !queues.isEmpty else { return }

        // ── Interval ─────────────────────────────────────────────────────────
        // Used to convert accumulated counts into per-second rates.
        // Guarded at 1 s so a misconfigured zero interval never causes division
        // by zero (rate would just be inflated rather than crashing).
        let intervalSecs = max(
            1.0,
            Double(options.interval.components.seconds)
                + Double(options.interval.components.attoseconds) / 1e18
        )

        // ── Flush timing buffer BEFORE the queue DB queries ───────────────────
        // Flushing first guarantees the per-queue throughput numbers and the
        // individual timing snapshots come from the same buffer drain — no
        // interleaving with the next cycle's records.
        var flushedTimings: [String: AggregatedMetricsBuffer._Entry] = [:]
        var queueThroughput: [String: Double] = [:]
        if let buffer = metricsBuffer {
            flushedTimings = buffer.flush()
            for (key, entry) in flushedTimings where entry.execTime.count > 0 {
                // Key format: "queue/taskName/state"
                let parts = key.split(separator: "/", maxSplits: 2)
                guard parts.count == 3 else { continue }
                let q = String(parts[0])
                queueThroughput[q, default: 0] += Double(entry.execTime.count) / intervalSecs
            }

            // Apply EWMA smoothing per queue so quiet 5 s windows don't
            // spike the rate to 0 when a longer-running job happens to not
            // complete in this exact window.
            // α = 0.25 → effective window ≈ 15 s at the default 5 s interval.
            let alpha = 0.25
            for queue in queues {
                let raw = queueThroughput[queue, default: 0]
                if let prev = smoothedRates[queue] {
                    smoothedRates[queue] = alpha * raw + (1 - alpha) * prev
                } else {
                    // First cycle: seed with the raw rate (no prior to average against).
                    smoothedRates[queue] = raw
                }
            }
        }

        var snapshots: [StrandMetricsBroadcast.QueueSnapshot] = []

        for queue in queues {
            let p = counts["\(queue)/\(TaskState.pending.rawValue)", default: 0]
            let r = counts["\(queue)/\(TaskState.running.rawValue)", default: 0]
            let sl = counts["\(queue)/\(TaskState.sleeping.rawValue)", default: 0]
            let w = counts["\(queue)/\(TaskState.waiting.rawValue)", default: 0]

            // Update previous-counts for next cycle.
            previousCounts["\(queue)/\(TaskState.pending.rawValue)"] = p
            previousCounts["\(queue)/\(TaskState.running.rawValue)"] = r
            previousCounts["\(queue)/\(TaskState.sleeping.rawValue)"] = sl
            previousCounts["\(queue)/\(TaskState.waiting.rawValue)"] = w

            snapshots.append(
                .init(
                    queue: queue,
                    pending: p,
                    running: r,
                    sleeping: sl,
                    waiting: w,
                    throughputPerSec: metricsBuffer != nil
                        ? smoothedRates[queue, default: 0]
                        : nil
                )
            )
        }

        // ── Timing snapshots (from the pre-flushed buffer) ────────────────────
        // Sort by count descending and cap at maxTimingEntries so the busiest
        // tasks always appear and payload size stays bounded.
        let timingSnapshots: [StrandMetricsBroadcast.TimingSnapshot]?
        if !flushedTimings.isEmpty {
            let built = flushedTimings.compactMap { key, entry -> StrandMetricsBroadcast.TimingSnapshot? in
                guard entry.execTime.count > 0 else { return nil }
                let parts = key.split(separator: "/", maxSplits: 2)
                guard parts.count == 3,
                    let internalState = TaskState(rawValue: String(parts[2]))
                else { return nil }
                return StrandMetricsBroadcast.TimingSnapshot(
                    queue: String(parts[0]),
                    taskName: String(parts[1]),
                    state: internalState.taskStatus,
                    count: entry.execTime.count,
                    ratePerSec: Double(entry.execTime.count) / intervalSecs,
                    execTime: DDSketch.Serialized(from: entry.execTime),
                    waitTime: entry.waitTime.count > 0
                        ? DDSketch.Serialized(from: entry.waitTime)
                        : nil
                )
            }
            .sorted { $0.count > $1.count }  // busiest first
            .prefix(options.maxTimingEntries)

            timingSnapshots = built.isEmpty ? nil : Array(built)
        } else {
            timingSnapshots = nil
        }

        let payload = StrandMetricsBroadcast(
            namespace: client.namespaceID,
            at: Date.now.timeIntervalSince1970,
            queues: snapshots,
            timings: timingSnapshots
        )

        // ── Compress + encode ────────────────────────────────────────────────────────────────
        // DDSketch JSON compresses 5–10× under gzip, keeping the payload well
        // within Postgres’s 8 000-byte pg_notify hard limit. The subscriber
        // (MetricsBroadcastListener) tries base64 first; if decoding fails it
        // falls back to plain JSON.
        //
        // Foundation.Compression is available on Apple platforms; on Linux
        // swift-corelibs-foundation provides NSData.compressed(using:) since
        // Swift 5.7. We use the raw ZLIB deflate API via NIOFoundationCompat
        // to stay cross-platform without adding a new dependency.
        let rawJSON = try JSON.encode(payload)
        let notifyPayload: String
        if let compressed = _zlibDeflate(rawJSON) {
            notifyPayload = compressed
        } else {
            // Compression unavailable — send plain JSON and hope it fits.
            notifyPayload = String(buffer: rawJSON)
        }

        try await client.postgres.query(
            "SELECT pg_notify(\(StrandChannels.metrics), \(notifyPayload))",
            logger: client.logger
        )

        client.logger.debug(
            "metrics broadcast sent",
            metadata: [
                "strand.namespace": .string(client.namespaceID),
                "strand.queue_count": .stringConvertible(snapshots.count),
                "strand.payload_bytes": .stringConvertible(notifyPayload.utf8.count),
            ]
        )
    }

    /// Returns the registered queue list and their PENDING/RUNNING/SLEEPING/WAITING
    /// task counts in one round-trip.
    ///
    /// Uses `strand.queues` as the authoritative queue list (LEFT JOIN) so
    /// queues with zero tasks in all states still appear in the result.
    /// The adaptive exact/estimate split is preserved: queues whose previous
    /// maximum count was below `estimateThreshold` use an exact `COUNT(*)`,
    /// others use the planner estimate to avoid full table scans.
    private func allQueueCounts(
        prev: [String: Int]
    ) async throws -> (queues: [String], counts: [String: Int]) {
        let tracked: [TaskState] = [.pending, .running, .sleeping, .waiting]

        // We don't know queue names yet, so classify after the query using
        // previousCounts from the last cycle. On the first cycle all queues
        // go to the exact path (prev is empty → maxPrev = 0 < threshold).
        // We'll split into exact/estimate after we've discovered the queues,
        // but since we need the split BEFORE the query, we use the names from
        // the previous cycle stored in `prev` keys ("queue/STATE" format).
        var seenQueues: Set<String> = []
        for key in prev.keys {
            if let slash = key.firstIndex(of: "/") {
                seenQueues.insert(String(key[key.startIndex..<slash]))
            }
        }
        var exactQueues: [String] = []
        var estimateQueues: [String] = []
        for queue in seenQueues {
            let maxPrev = tracked.map { prev["\(queue)/\($0.rawValue)", default: 0] }.max() ?? 0
            if maxPrev < options.estimateThreshold { exactQueues.append(queue) } else { estimateQueues.append(queue) }
        }
        // New queues (not yet in prev) always use exact counts.
        // They are included via the LEFT JOIN from strand.queues below.

        let stream = try await client.postgres.query(
            """
            WITH
            all_queues AS (
                SELECT name AS queue
                FROM   strand.queues
                WHERE  namespace_id = \(client.namespaceID)
                ORDER  BY name
            ),
            task_counts AS (
                -- Exact COUNT(*) for low-volume queues (or any queue not yet seen)
                SELECT queue, state::text, COUNT(*)::integer AS cnt
                FROM   strand.tasks
                WHERE  namespace_id = \(client.namespaceID)
                  AND  state        IN (\(TaskState.pending), \(TaskState.running),
                                       \(TaskState.sleeping), \(TaskState.waiting))
                  AND  queue        NOT IN (SELECT UNNEST(\(estimateQueues)))
                GROUP  BY queue, state

                UNION ALL

                -- Planner estimate for high-volume queues (avoids full scan)
                SELECT q.queue, s.state,
                       strand.count_estimate(\(client.namespaceID), q.queue, s.state)::integer
                FROM   UNNEST(\(estimateQueues)) AS q(queue)
                       CROSS JOIN UNNEST(ARRAY[\(TaskState.pending)::text,  \(TaskState.running)::text,
                                              \(TaskState.sleeping)::text, \(TaskState.waiting)::text]) AS s(state)
            )
            -- Queue list first (row_type='Q'), counts second ('C').
            -- Ordering puts 'Q' rows before 'C' so the caller can collect
            -- queue names in a first pass if needed; in practice both are
            -- iterated in a single pass and disambiguated by row_type.
            SELECT 'Q'::text AS row_type, q.queue, NULL::text AS state, NULL::integer AS cnt
            FROM   all_queues q
            UNION ALL
            SELECT 'C', tc.queue, tc.state, tc.cnt
            FROM   task_counts tc
            ORDER  BY row_type, queue, state
            """,
            logger: client.logger
        )

        var queues: [String] = []
        var counts: [String: Int] = [:]
        for try await row in stream {
            var col = row.makeIterator()
            let rowType = try col.next()!.decode(String.self, context: .default)
            let queue = try col.next()!.decode(String.self, context: .default)
            let state = try col.next()!.decode(String?.self, context: .default)
            let cnt = try col.next()!.decode(Int?.self, context: .default)
            if rowType == "Q" {
                queues.append(queue)
            } else if let st = state, let n = cnt {
                counts["\(queue)/\(st)"] = n
            }
        }
        return (queues: queues, counts: counts)
    }
}
