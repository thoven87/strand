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
}

// MARK: - Helpers

extension Duration {
    /// Converts a `Duration` (Swift 5.7+) to nanoseconds for `Timer.recordNanoseconds`.
    var nanoseconds: Int64 {
        components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    }
}
