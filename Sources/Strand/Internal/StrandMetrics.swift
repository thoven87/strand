import Metrics

// MARK: - Metric label constants

/// Centralised names for every metric emitted by Strand.
///
/// Backends (Prometheus, StatsD, CloudWatch, …) receive these labels verbatim.
/// Bootstrap your preferred backend once at process start:
///
/// ```swift
/// import Metrics
/// import PrometheusMetrics   // or any swift-metrics-compatible backend
///
/// MetricsSystem.bootstrap(PrometheusMetricsFactory(configuration: .init()))
/// ```
///
/// If no backend is bootstrapped the default `NOOPMetricsHandler` is used
/// and all metric calls are silently discarded — there is no startup cost.
public enum StrandMetrics {

    // MARK: - Worker / poll loop

    /// Number of tasks claimed from the DB in a single poll cycle.
    /// **Dimensions**: `queue`
    public static let tasksClaimed = "strand.worker.tasks_claimed"

    // MARK: - Task execution

    /// Wall-clock duration of one task execution attempt (claim → terminal state or suspension).
    /// **Dimensions**: `task_name`, `queue`
    public static let taskDuration = "strand.task.duration"

    /// Task reached a terminal COMPLETED state.
    /// **Dimensions**: `task_name`, `queue`
    public static let tasksCompleted = "strand.tasks.completed"

    /// Task handler threw a real error (FAILED state, retries may follow).
    /// **Dimensions**: `task_name`, `queue`
    public static let tasksFailed = "strand.tasks.failed"

    /// Task suspended cleanly (waiting for activity, sleep, event, or condition).
    /// Not an error — just a lifecycle checkpoint.
    /// **Dimensions**: `task_name`, `queue`
    public static let tasksSuspended = "strand.tasks.suspended"

    /// Workflow called `context.continueAsNew(input:)` — old run completed, new task enqueued.
    /// **Dimensions**: `task_name`, `queue`
    public static let tasksContinuedAsNew = "strand.tasks.continued_as_new"

    // MARK: - Pruner

    /// Number of terminal tasks deleted in a pruner cycle.
    /// Includes COMPLETED, CONTINUED_AS_NEW, FAILED, and CANCELLED tasks
    /// that have aged past the namespace retention window.
    /// **Dimensions**: `namespace`
    public static let prunerTasksDeleted = "strand.pruner.tasks_deleted"

    /// Number of events deleted in a pruner cycle.
    /// `strand.events` rows have no FK to tasks and are pruned independently.
    /// **Dimensions**: `namespace`
    public static let prunerEventsDeleted = "strand.pruner.events_deleted"

    /// Number of monthly partitions dropped in a partition management cycle.
    /// A non-zero value means at least one whole month of `strand.runs` or
    /// `strand.task_logs` data was instantly reclaimed without a vacuum.
    /// **Dimensions**: `namespace`
    public static let prunerPartitionsDropped = "strand.pruner.partitions_dropped"
}

// MARK: - LISTEN/NOTIFY channel names

/// Internal PostgreSQL channel names and payload type for LISTEN/NOTIFY wakeups.
package enum StrandChannels {
    /// Channel on which workers LISTEN for new work.
    /// All NOTIFY calls go through `PostgresConnection.notifyWorkers(namespace:queue:logger:)`.
    package static let tasks = "strand_tasks"

    /// Channel on which `StrandMetricsLoop` broadcasts pre-computed queue counts
    /// and ``MetricsBroadcastListener`` in the dashboard server listens.
    package static let metrics = "strand_metrics"

    /// Channel on which activity stream chunks are broadcast.
    /// Payload format: see `_StreamPayload` in `StrandStreamNotifier.swift`.
    package static let stream = "strand_stream"

    // MARK: - Payload type

    /// A typed NOTIFY payload carrying a `(namespace, queue)` pair.
    ///
    /// Wire format: `"<namespace>/<queue>"`. Splitting on the first `/` allows
    /// a queue name that contains `/` as long as the namespace does not
    /// (namespace IDs are plain identifiers validated by a Postgres FK).
    package struct Notification: Sendable {
        package let namespace: String
        package let queue: String

        /// Creates a notification for the given namespace and queue.
        package init(namespace: String, queue: String) {
            self.namespace = namespace
            self.queue = queue
        }

        /// Parses a raw NOTIFY payload. Returns `nil` if the format is unrecognised.
        package init?(payload: String) {
            guard let slash = payload.firstIndex(of: "/") else { return nil }
            let ns = String(payload[..<slash])
            let q = String(payload[payload.index(after: slash)...])
            guard !ns.isEmpty, !q.isEmpty else { return nil }
            self.namespace = ns
            self.queue = q
        }

        /// The encoded string passed as the `pg_notify` payload.
        package var payload: String { "\(namespace)/\(queue)" }
    }
}

// MARK: - Helpers

extension Duration {
    /// Converts a `Duration` (Swift 5.7+) to nanoseconds for `Timer.recordNanoseconds`.
    var nanoseconds: Int64 {
        components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    }
}
