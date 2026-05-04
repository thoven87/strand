import NIOCore

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// Public errors thrown by Strand.
public enum StrandError: Error, LocalizedError, Sendable {
    /// A durable wait (`awaitEvent`, `awaitTaskResult`, `waitForEvent`) exceeded its timeout.
    case timeout(message: String)
    /// The task was cancelled before or during execution.
    case cancelled
    /// No registered handler found for the given task name.
    case unknownTask(name: String)
    /// Queue name is empty or exceeds 57 UTF-8 bytes.
    case invalidQueueName(String)
    /// The worker's lease on a task expired before the handler finished.
    case leaseExpired(taskID: String)
    /// A Postgres-level error propagated from PostgresNIO.
    case database(underlying: any Error)
    /// JSON encoding or decoding failed.
    case serialization(underlying: any Error)
    /// Installed schema version is older than the SDK requires.
    case schemaMismatch(installed: String, required: String)
    /// An activity reached its terminal FAILED state (all retries exhausted).
    case activityFailed(name: String, state: String)
    /// A child workflow reached a terminal error state.
    case childWorkflowFailed(name: String, state: String)

    // MARK: - LocalizedError

    /// Human-readable description stored in `strand.runs.failure_reason` and
    /// surfaced in the dashboard. Without this, Foundation generates the
    /// cryptic "The operation couldn't be completed. (Strand.StrandError error N.)".
    public var errorDescription: String? {
        switch self {
        case .timeout(let msg): return "Timeout: \(msg)"
        case .cancelled: return "Task was cancelled"
        case .unknownTask(let name): return "No registered handler for task '\(name)'"
        case .invalidQueueName(let name): return "Invalid queue name '\(name)'"
        case .leaseExpired(let id): return "Worker lease expired for task \(id)"
        case .database(let err): return "Database error: \(err)"
        case .serialization(let err): return "Serialization error: \(err)"
        case .schemaMismatch(let ins, let req):
            return "Schema mismatch: installed \(ins), required \(req)"
        case .activityFailed(let name, let state):
            return "Activity '\(name)' reached terminal state: \(state)"
        case .childWorkflowFailed(let name, let state):
            return "Child workflow '\(name)' reached terminal state: \(state)"
        }
    }
}

/// Internal sentinel errors used to signal clean lifecycle transitions.
/// Never surfaced to user code — caught exclusively inside `executeTask`.
enum InternalError: Error {
    /// Task called `sleepFor`/`sleepUntil` or registered an event wait.
    case suspend
    /// Postgres signalled cancellation at a checkpoint write.
    case cancelled
    /// Run was already marked failed (concurrent edge case).
    case failedRun
}

// MARK: - Continue-as-new

/// Thrown by `WorkflowContext.continueAsNew(input:)` and caught exclusively by
/// `StrandWorker.runTask`. Never propagated to user code as an error — the
/// worker uses it to enqueue a fresh task and complete the current one.
struct _ContinueAsNewSignal: Error {
    /// The workflow type name to enqueue (same as the current workflow).
    let workflowName: String
    /// The namespace the new task belongs to (same as the current run).
    let namespaceID: String
    /// The queue to dispatch the new task on (inherited from the current run).
    let queue: String
    /// JSON-encoded input for the new workflow instance.
    let input: ByteBuffer
}
