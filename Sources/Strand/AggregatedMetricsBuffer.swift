import Synchronization

// MARK: - AggregatedMetricsBuffer

/// Thread-safe in-memory buffer that accumulates task execution timings from
/// one or more ``StrandWorker`` instances.
///
/// Workers call ``record(queue:taskName:state:execMs:waitMs:)`` synchronously
/// after each terminal execution (zero allocation per call — just a Mutex lock
/// + map update).  ``StrandMetricsLoop`` calls ``flush()`` every broadcast
/// cycle to atomically swap out the buffer and serialise the accumulated
/// ``DDSketch`` values into the `pg_notify` payload.
///
/// ## Buffer key
///
/// Entries are keyed by `"queue/taskName/state"` so completed and failed tasks
/// are tracked in separate sketches — a task that always fails in 2 ms should
/// not pollute the p95 of a task that succeeds in 200 ms.
///
/// Create one instance at the application level and pass it to every worker
/// and to the metrics loop:
///
/// ```swift
/// let metricsBuffer = AggregatedMetricsBuffer()
/// let worker  = StrandWorker(..., metricsBuffer: metricsBuffer)
/// let loop    = StrandMetricsLoop(client: client, metricsBuffer: metricsBuffer)
/// ```
public final class AggregatedMetricsBuffer: Sendable {

    // MARK: - Internal entry

    struct _Entry {
        /// Wall-clock duration from claim to terminal state (ms).
        var execTime: DDSketch = DDSketch()
        /// Time spent waiting in the queue before being claimed (ms).
        var waitTime: DDSketch = DDSketch()
    }

    // MARK: - Storage

    private let _mutex: Mutex<[String: _Entry]> = Mutex([:])

    public init() {}

    // MARK: - Writer API (called by StrandWorker)

    /// Record one task execution.
    ///
    /// - Parameters:
    ///   - queue: The queue the task ran on.
    ///   - taskName: The registered task name.
    ///   - state: Terminal state — `.completed` or `.failed`.
    ///   - execMs: Wall-clock execution duration in milliseconds.
    ///   - waitMs: Time spent in the queue before being claimed (ms).
    ///             Pass 0 or a negative value to skip wait_time recording.
    public func record(
        queue: String,
        taskName: String,
        state: TaskStatus,
        execMs: Double,
        waitMs: Double = 0
    ) {
        guard execMs > 0 else { return }
        _mutex.withLock { entries in
            let key = "\(queue)/\(taskName)/\(state.rawValue)"
            entries[key, default: _Entry()].execTime.insert(execMs)
            if waitMs > 0 {
                entries[key, default: _Entry()].waitTime.insert(waitMs)
            }
        }
    }

    // MARK: - Reader API (called by StrandMetricsLoop)

    /// Atomically returns all accumulated entries and resets the buffer to empty.
    ///
    /// Each entry maps `"queue/taskName/state"` to a pair of ``DDSketch``
    /// values (exec_time and wait_time).  Returns an empty dict if no tasks
    /// completed since the last flush.
    func flush() -> [String: _Entry] {
        _mutex.withLock { entries in
            let snapshot = entries
            entries = [:]
            return snapshot
        }
    }
}
