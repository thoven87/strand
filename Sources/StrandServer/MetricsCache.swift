import Logging
public import PostgresNIO
public import ServiceLifecycle
@_spi(Internal) public import Strand
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Cache

/// Thread-safe in-memory cache of the latest ``StrandMetricsBroadcast``.
///
/// Updated by ``MetricsBroadcastListener`` when a `strand_metrics` pg_notify
/// arrives. Read by ``MetricsRoutes`` to avoid per-request COUNT queries.
///
/// Broadcasts older than ``ttl`` are treated as stale; routes fall back to
/// live DB queries until the next broadcast arrives.
public final class MetricsCache: Sendable {

    private struct _State {
        var entries: [String: (broadcast: StrandMetricsBroadcast, receivedAt: Date)] = [:]
        /// Last non-nil timings per namespace, preserved for up to `timingsTTL`
        /// so a quiet broadcast window doesn't evict good DDSketch data.
        var lastTimings: [String: (timings: [StrandMetricsBroadcast.TimingSnapshot], preservedAt: Date)] = [:]
    }

    private let _mutex: Mutex<_State> = Mutex(_State())

    /// Maximum age of a cached broadcast before it is considered stale.
    /// Default: 30 s — comfortably longer than the default 5 s broadcast
    /// interval, so a single missed cycle never forces a live query.
    public let ttl: Duration

    /// Time-to-live for preserved timings when broadcasts emit nil timings.
    /// Longer than `ttl` so a few quiet 5 s windows never evict good data.
    public let timingsTTL: Duration

    public init(ttl: Duration = .seconds(30), timingsTTL: Duration = .seconds(120)) {
        self.ttl = ttl
        self.timingsTTL = timingsTTL
    }

    /// Replaces the cached broadcast for its namespace with a freshly received one.
    /// When the broadcast carries nil timings, merges in the last preserved
    /// timings (if within `timingsTTL`) so a quiet window never evicts good data.
    func update(_ broadcast: StrandMetricsBroadcast) {
        _mutex.withLock { s in
            // Persist any non-nil timings so quiet windows don't evict them.
            if let newTimings = broadcast.timings {
                s.lastTimings[broadcast.namespace] = (newTimings, Date.now)
            }

            // Merge: use the broadcast's own timings if present; fall back to
            // last preserved timings (provided they are within timingsTTL).
            let mergedTimings: [StrandMetricsBroadcast.TimingSnapshot]?
            if let preserved = s.lastTimings[broadcast.namespace] {
                let age = Date.now.timeIntervalSince(preserved.preservedAt)
                let ttlSecs = Double(timingsTTL.components.seconds)
                mergedTimings = (age < ttlSecs) ? (broadcast.timings ?? preserved.timings) : broadcast.timings
            } else {
                mergedTimings = broadcast.timings
            }

            let merged = StrandMetricsBroadcast(
                namespace: broadcast.namespace,
                at: broadcast.at,
                queues: broadcast.queues,
                timings: mergedTimings
            )
            s.entries[broadcast.namespace] = (merged, Date.now)
        }
    }

    /// Returns the cached broadcast for `namespace` if it is younger than ``ttl``.
    public func current(forNamespace namespace: String) -> StrandMetricsBroadcast? {
        _mutex.withLock { s in
            guard let entry = s.entries[namespace] else { return nil }
            let age = Date.now.timeIntervalSince(entry.receivedAt)
            guard age < Double(ttl.components.seconds) else { return nil }
            return entry.broadcast
        }
    }

    /// Returns the most recently received broadcast across all namespaces if younger than ``ttl``.
    /// Used by callers that do not filter by namespace.
    public func current() -> StrandMetricsBroadcast? {
        _mutex.withLock { s in
            guard let (_, entry) = s.entries.max(by: { $0.value.receivedAt < $1.value.receivedAt })
            else { return nil }
            let age = Date.now.timeIntervalSince(entry.receivedAt)
            guard age < Double(ttl.components.seconds) else { return nil }
            return entry.broadcast
        }
    }
}

// MARK: - Listener service

/// Service that receives ``StrandMetricsBroadcast`` notifications and keeps
/// a ``MetricsCache`` up to date so ``MetricsRoutes`` never issues on-demand
/// COUNT queries.
///
/// **Preferred (one connection)**: pass a ``StrandNotifier`` that already
/// declares `"strand_metrics"` in its channels.  The listener subscribes to
/// the notifier's `AsyncStream` — zero extra Postgres connections.
///
/// ```swift
/// let notifier = StrandNotifier(
///     postgres: postgres,
///     channels: [StrandChannels.tasks, StrandChannels.metrics],
///     logger: logger
/// )
/// let cache    = MetricsCache()
/// let listener = MetricsBroadcastListener(notifier: notifier, cache: cache, logger: logger)
/// // notifier replaces MetricsBroadcastListener's own connection entirely
/// ```
///
/// **Fallback (own connection)**: omit `notifier` and provide `postgres` when
/// the server process runs without a ``StrandNotifier``.
public struct MetricsBroadcastListener: Service {
    private let notifier: StrandNotifier?
    private let postgres: PostgresClient?
    private let cache: MetricsCache
    private let logger: Logger

    private static let channel = StrandChannels.metrics

    /// Initialise with a shared ``StrandNotifier`` (preferred — no extra connection).
    public init(notifier: StrandNotifier, cache: MetricsCache, logger: Logger) {
        self.notifier = notifier
        self.postgres = nil
        self.cache = cache
        self.logger = logger
    }

    /// Initialise with a dedicated Postgres client (fallback when no notifier is available).
    public init(postgres: PostgresClient, cache: MetricsCache, logger: Logger) {
        self.notifier = nil
        self.postgres = postgres
        self.cache = cache
        self.logger = logger
    }

    public func run() async throws {
        logger.debug("metrics broadcast listener starting")
        defer { logger.debug("metrics broadcast listener stopped") }

        if let notifier {
            // Fast path: subscribe to the shared notifier stream.
            // No Postgres connection needed here — the notifier owns it.
            //
            // cancelWhenGracefulShutdown is essential: without it, the for-await
            // loop blocks until the notifier's stream finishes.  The notifier
            // is an earlier service in the ServiceGroup so it shuts down AFTER
            // this listener.  Without the wrapper the ServiceGroup would be stuck
            // waiting for this run() to return, preventing every subsequent
            // service (workers, notifier itself) from receiving their own
            // graceful shutdown signal.
            await cancelWhenGracefulShutdown {
                for await payload in notifier.stream(for: Self.channel) {
                    self.decode(payload)
                }
            }
            return
        }

        // Fallback: own LISTEN connection (no StrandNotifier in this process).
        guard let postgres else { return }

        while !Task.isShuttingDownGracefully && !Task.isCancelled {
            do {
                try await cancelWhenGracefulShutdown {
                    try await postgres.withConnection { conn in
                        try await conn.listen(on: Self.channel) { notifications in
                            for try await notification in notifications {
                                self.decode(notification.payload)
                            }
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                logger.warning(
                    "metrics listener connection lost — reconnecting",
                    metadata: ["error": "\(String(reflecting: error))"]
                )
                try? await cancelWhenGracefulShutdown {
                    try await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func decode(_ payload: String) {
        // _decodeMetricsBroadcast handles both plain JSON ("{...}")
        // and gzip+base64 encoded payloads from _zlibDeflate.
        guard let broadcast = _decodeMetricsBroadcast(payload) else { return }
        cache.update(broadcast)
        logger.debug(
            "metrics cache updated",
            metadata: [
                "strand.namespace": .string(broadcast.namespace),
                "strand.queue_count": .stringConvertible(broadcast.queues.count),
            ]
        )
    }
}
