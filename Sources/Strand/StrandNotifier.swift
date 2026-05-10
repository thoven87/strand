public import Logging
public import PostgresNIO
public import ServiceLifecycle
import Synchronization

// MARK: - StrandNotifier

/// Holds **one** persistent Postgres LISTEN connection and fans out
/// notifications to any number of subscribers via `AsyncStream`.
///
/// Before this type existed every component that needed LISTEN/NOTIFY held its
/// own dedicated connection.  `StrandNotifier` replaces all of them: declare
/// the channels you need at construction time, pass the notifier to every
/// component, and only one connection is ever open.
///
/// ```swift
/// let notifier = StrandNotifier(
///     postgres: postgres,
///     channels: [StrandChannels.tasks, StrandChannels.metrics],
///     logger: logger
/// )
/// let worker   = StrandWorker(postgres: postgres, notifier: notifier, ...)
/// let listener = MetricsBroadcastListener(notifier: notifier, cache: cache, logger: logger)
///
/// let group = ServiceGroup(services: [postgres, notifier, worker, listener, ...])
/// ```
///
/// ## Subscription model
///
/// Call ``stream(for:)`` to receive an `AsyncStream<String>` that yields the
/// raw `pg_notify` payload for every notification on that channel.  When the
/// consumer task exits (normally or by cancellation) its stream's
/// `onTermination` handler automatically removes the subscription — no
/// explicit cleanup required.
///
/// ```swift
/// for await payload in notifier.stream(for: StrandChannels.tasks) {
///     if payload == expectedPayload { notifySignal.signal() }
/// }
/// ```
///
/// ## Connection lifecycle
///
/// ``run()`` holds a single `PostgresConnection` for the lifetime of the
/// service.  On drop (network hiccup, Postgres restart) it reconnects after
/// a 1-second back-off and re-issues `LISTEN` for every declared channel.
/// All `cancelWhenGracefulShutdown` / NIO runTimer guards from `listenLoop`
/// are preserved here.
public final class StrandNotifier: Service, Sendable {

    // MARK: - Internal types

    private struct _State {
        /// Channel → { subscriber-id → continuation }.
        ///
        /// Dictionary keying gives O(1) removal on task cancellation
        /// (vs O(N) scan in an Array). Dispatch iterates all values in O(N),
        /// which is unavoidable regardless of collection type.
        var subscriptions: [String: [UInt64: AsyncStream<String>.Continuation]] = [:]
        var nextID: UInt64 = 0
    }

    // MARK: - Storage

    private let _state: Mutex<_State> = Mutex(_State())

    let postgres: PostgresClient
    let logger: Logger
    /// Channels on which `LISTEN` will be issued when the connection is (re-)established.
    let channels: Set<String>

    // MARK: - Init

    // MARK: - Channel name constants

    /// Channel on which workers receive task-ready notifications.
    /// Pass in `channels:` when the notifier is shared with ``StrandWorker``.
    public static let tasksChannel = "strand_tasks"

    /// Channel on which ``StrandMetricsLoop`` broadcasts live task counts.
    /// Pass in `channels:` when the notifier is shared with ``MetricsBroadcastListener``.
    public static let metricsChannel = "strand_metrics"

    // MARK: - Init

    public init(
        postgres: PostgresClient,
        channels: Set<String>,
        logger: Logger
    ) {
        self.postgres = postgres
        self.channels = channels
        self.logger = logger
    }

    // MARK: - Subscription

    /// Returns an `AsyncStream<String>` that yields the raw `pg_notify` payload
    /// for every notification arriving on `channel`.
    ///
    /// The stream is lightweight — just an `AsyncStream` backed by a stored
    /// continuation.  Multiple callers may subscribe to the same channel and
    /// each receives an independent copy of every notification.
    ///
    /// When the consumer task exits (cancellation or normal return) the stream's
    /// `onTermination` handler removes the subscription automatically.
    public func stream(for channel: String) -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()

        let id = _state.withLock { s -> UInt64 in
            let id = s.nextID
            s.nextID += 1
            s.subscriptions[channel, default: [:]][id] = continuation
            return id
        }

        // O(1) removal: just wipe the key.
        continuation.onTermination = { [weak self] _ in
            self?._state.withLock { s in
                s.subscriptions[channel]?[id] = nil
            }
        }

        return stream
    }

    // MARK: - Service

    public func run() async throws {
        logger.info(
            "notifier starting",
            metadata: ["strand.channels": .string(channels.sorted().joined(separator: ", "))]
        )
        defer {
            // Finish every active stream so consumer for-await loops exit cleanly
            // rather than blocking indefinitely.
            //
            // collect continuations and clear subscriptions under the
            // lock, then call finish() OUTSIDE the lock.
            let pending = _state.withLock { s -> [AsyncStream<String>.Continuation] in
                let all = s.subscriptions.values.flatMap(\.values)
                s.subscriptions.removeAll()
                return all
            }
            for cont in pending { cont.finish() }
            logger.info("notifier stopped")
        }

        while !Task.isShuttingDownGracefully && !Task.isCancelled {
            do {
                // cancelWhenGracefulShutdown wraps the entire connection body for
                // the same two reasons documented in StrandWorker.listenLoop:
                //
                // 1. Fast voluntary exit: detects isShuttingDownGracefully and
                //    cancels the inner scope immediately rather than waiting for
                //    the next reconnect cycle.
                //
                // 2. NIO runTimer safety: the *outer* notifier task remains alive
                //    while the inner scope cleans up, giving NIO's event-loop
                //    callbacks the window they need to fire before the Swift task
                //    is torn down (preventing leaked runTimer continuations).
                try await cancelWhenGracefulShutdown {
                    try await self.postgres.withConnection { conn in
                        // One conn.listen() task per declared channel — all sharing
                        // the same connection.  This is the fan-out: a single
                        // Postgres wire connection services N subscribers.
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            for channel in self.channels {
                                let ch = channel
                                group.addTask {
                                    try await conn.listen(on: ch) { notifications in
                                        for try await note in notifications {
                                            // Dispatch to all subscribers for this channel.
                                            // yield() is synchronous — no blocking here.
                                            let subs = self._state.withLock { s in
                                                s.subscriptions[ch] ?? [:]
                                            }
                                            // Dispatch to every subscriber in O(N).
                                            for (_, cont) in subs {
                                                cont.yield(note.payload)
                                            }
                                        }
                                    }
                                }
                            }
                            // Keep the closure alive until all listen tasks finish
                            // (they run until the connection drops or is cancelled).
                            try await group.waitForAll()
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                logger.warning(
                    "notifier connection lost — reconnecting",
                    metadata: .forError(error)
                )
                try? await cancelWhenGracefulShutdown {
                    try await Task.sleep(for: .seconds(1))
                }
            }
        }
    }
}
