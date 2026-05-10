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
        var broadcast: StrandMetricsBroadcast?
        var receivedAt: Date = .distantPast
    }

    private let _mutex: Mutex<_State> = Mutex(_State())

    /// Maximum age of a cached broadcast before it is considered stale.
    /// Default: 30 s — comfortably longer than the default 5 s broadcast
    /// interval, so a single missed cycle never forces a live query.
    public let ttl: Duration

    public init(ttl: Duration = .seconds(30)) {
        self.ttl = ttl
    }

    /// Replaces the cached broadcast with a freshly received one.
    func update(_ broadcast: StrandMetricsBroadcast) {
        _mutex.withLock { s in
            s.broadcast = broadcast
            s.receivedAt = Date.now
        }
    }

    /// Returns the cached broadcast if one exists and is younger than ``ttl``,
    /// otherwise `nil` (routes should fall back to live DB queries).
    public func current() -> StrandMetricsBroadcast? {
        _mutex.withLock { s in
            guard let b = s.broadcast else { return nil }
            let age = Date.now.timeIntervalSince(s.receivedAt)
            guard age < Double(ttl.components.seconds) else { return nil }
            return b
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
