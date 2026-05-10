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
        /// Terminal state — `.completed` or `.failed`.
        public let state: TaskState
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

        while !Task.isShuttingDownGracefully && !Task.isCancelled {
            // cancelWhenGracefulShutdown exits the sleep quickly on shutdown
            // without leaking the NIO runTimer continuation.
            try? await cancelWhenGracefulShutdown {
                try await Task.sleep(for: self.options.interval)
            }
            guard !Task.isShuttingDownGracefully && !Task.isCancelled else { break }

            do {
                try await broadcast(previousCounts: &previousCounts)
            } catch {
                logger.error(
                    "metrics loop broadcast failed",
                    metadata: ["error": "\(String(reflecting: error))"]
                )
            }
        }
    }

    // MARK: - Private

    private func broadcast(previousCounts: inout [String: Int]) async throws {
        let queues = try await client.listQueues()
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
        }

        // ── Queue count snapshots (async DB queries) ──────────────────────────
        var snapshots: [StrandMetricsBroadcast.QueueSnapshot] = []

        for queue in queues {
            async let pending = countState(.pending, queue: queue, prev: previousCounts)
            async let running = countState(.running, queue: queue, prev: previousCounts)
            async let sleeping = countState(.sleeping, queue: queue, prev: previousCounts)
            async let waiting = countState(.waiting, queue: queue, prev: previousCounts)

            let (p, r, sl, w) = try await (pending, running, sleeping, waiting)

            // Update the previous-counts table for next cycle.
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
                    // nil when no metricsBuffer is wired; 0.0 when wired but idle
                    throughputPerSec: metricsBuffer != nil
                        ? queueThroughput[queue, default: 0]
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
                    let state = TaskState(rawValue: String(parts[2]))
                else { return nil }
                return StrandMetricsBroadcast.TimingSnapshot(
                    queue: String(parts[0]),
                    taskName: String(parts[1]),
                    state: state,
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

    /// Returns the count for the given state/queue, choosing between exact
    /// COUNT(*) and the planner estimate based on the previous measurement.
    private func countState(
        _ state: TaskState,
        queue: String,
        prev: [String: Int]
    ) async throws -> Int {
        let previous = prev["\(queue)/\(state.rawValue)", default: 0]

        if previous < options.estimateThreshold {
            return try await exactCount(state: state, queue: queue)
        } else {
            return try await estimatedCount(state: state, queue: queue)
        }
    }

    private func exactCount(state: TaskState, queue: String) async throws -> Int {
        let stream = try await client.postgres.query(
            """
            SELECT COUNT(*)::integer
            FROM strand.tasks
            WHERE namespace_id = \(client.namespaceID)
              AND queue = \(queue)
              AND state = \(state)
            """,
            logger: client.logger
        )
        guard let row = try await stream.first(where: { _ in true }) else { return 0 }
        var col = row.makeIterator()
        return try col.next()!.decode(Int.self, context: .default)
    }

    private func estimatedCount(state: TaskState, queue: String) async throws -> Int {
        let stream = try await client.postgres.query(
            "SELECT strand.count_estimate(\(client.namespaceID), \(queue), \(state))",
            logger: client.logger
        )
        guard let row = try await stream.first(where: { _ in true }) else { return 0 }
        var col = row.makeIterator()
        return (try col.next()!.decode(Int?.self, context: .default)) ?? 0
    }
}
