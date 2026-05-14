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

// MARK: - EventWaitTimeoutError

/// Thrown by ``WorkflowContext/waitForEvent(_:as:timeout:)`` when the timeout
/// elapses before the named event arrives.
///
/// Catch this type specifically in your workflow handler — do **not** catch the
/// broader ``StrandError`` enum, which contains framework-internal variants
/// that must propagate to the runtime:
///
/// ```swift
/// do {
///     let payload = try await context.waitForEvent(
///         "order.shipped", as: ShipmentInfo.self, timeout: .seconds(300)
///     )
///     return .success(payload)
/// } catch is EventWaitTimeoutError {
///     // No one shipped within 5 minutes — escalate
///     return .timedOut
/// }
/// ```
public struct EventWaitTimeoutError: Error, Sendable {
    /// The name of the event that was being waited for.
    public let eventName: String

    public var localizedDescription: String {
        "Timed out waiting for event \"\(eventName)\""
    }
}

/// Internal sentinel errors used to signal clean lifecycle transitions.
/// Never surfaced to user code.
enum InternalError: Error {
    /// Postgres signalled cancellation at a checkpoint write (e.g. task was cancelled externally).
    case cancelled
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

// MARK: - LocatableError

/// An error that carries the source location of the `throw` site.
///
/// Conform to this protocol and use `#fileID`/`#line` default parameters so
/// Strand can surface the exact file and line in the dashboard. Because
/// `LocatableError` already refines `Error` you don't need to list `Error`
/// separately in the conformance list:
///
/// ```swift
/// struct TransientFailure: LocatableError {
///     let attempt: Int
///     let sourceFileID: String
///     let sourceLine: Int
///
///     init(attempt: Int, fileID: String = #fileID, line: Int = #line) {
///         self.attempt = attempt
///         self.sourceFileID = fileID
///         self.sourceLine   = line
///     }
/// }
/// // throw TransientFailure(attempt: ctx.attempt)
/// // ↑ #fileID and #line are captured at the throw site automatically
/// ```
public protocol LocatableError: Error {
    var sourceFileID: String { get }
    var sourceLine: Int { get }
}

// MARK: - Error message helper

/// Returns the best human-readable description of `error`.
///
/// Priority:
///   1. `LocalizedError.errorDescription` — the author's intended message.
///   2. `String(describing:)` — uses `CustomStringConvertible` when available,
///      otherwise Swift's default struct/class description.
///
/// **Why not `error.localizedDescription`?**
/// Foundation synthesises `localizedDescription` for any `Error` as
/// `"The operation couldn't be completed. (Module.TypeName error N.)"` when the
/// type does not implement `LocalizedError`. That string is machine-generated
/// noise. `String(describing:)` at least honours `CustomStringConvertible` and
/// produces something readable like `"Transient failure on attempt 2"`.
func strandErrorMessage(_ error: any Error) -> String {
    if let le = error as? any LocalizedError, let desc = le.errorDescription {
        return desc
    }
    return String(describing: error)
}

// MARK: - NonRetryableError

/// Conforming to this protocol marks an error type as permanently non-retryable.
///
/// When an activity throws an error that conforms to `NonRetryableError`, Strand
/// will not schedule another attempt regardless of the remaining retry budget or
/// `maxAttempts` setting — equivalent to `RetryStrategy.nonRetryable(MyError.self)`
/// but declared on the type itself where it belongs.
///
/// Because `NonRetryableError` already refines `Error` you don't need to list
/// `Error` separately in the conformance list:
///
/// ```swift
/// enum BankAccountError: Codable, NonRetryableError {
///     case invalidDetails
///     case expiredCard
/// }
/// ```
public protocol NonRetryableError: Error {}

// MARK: - Internal failure signals

/// Pre-encoded activity failure reason thrown from `Activity._run`.
/// Carries the JSON BYTEA that should be stored verbatim in `strand.runs.failure_reason`.
/// `StrandWorker.runTask` catches this to bypass re-encoding in `FailureReason`.
struct _TypedActivityFailure: Error, CustomStringConvertible {
    let reasonBuffer: ByteBuffer

    /// Human-readable description used by OTel’s `withSpan` when recording this
    /// error as an exception attribute on the activity span.
    /// Without this, swift-distributed-tracing falls back to `String(describing:)`
    /// which emits the raw struct internals: `_TypedActivityFailure(reasonBuffer: [7b...])`.
    var description: String {
        struct Reason: Decodable {
            let name: String
            let message: String
        }
        if let r = try? JSON.decode(Reason.self, from: reasonBuffer) {
            return "\(r.name): \(r.message)"
        }
        return "activity failed"
    }

    /// Builds the failure reason payload and encodes it as JSON.
    /// Falls back to a minimal JSON string if encoding itself fails.
    init(name: String, message: String, payload: Data?, nonRetryable: Bool, source: (fileID: String, line: Int)? = nil) {
        struct Payload: Encodable {
            let name: String
            let message: String
            let non_retryable: Bool?
            let payload: Data?
            let source: SourcePayload?
            struct SourcePayload: Encodable {
                let file_id: String
                let line: Int
            }
        }
        let p = Payload(
            name: name,
            message: message,
            non_retryable: nonRetryable ? true : nil,
            payload: payload,
            source: source.map { Payload.SourcePayload(file_id: $0.fileID, line: $0.line) }
        )
        // If encoding fails (essentially never) fall back to a static safe string.
        // We can't trust arbitrary content in `name` for manual JSON escaping,
        // so drop it and keep only the error signal.
        self.reasonBuffer =
            (try? JSON.encode(p))
            ?? ByteBuffer(string: #"{"name":"unknown","message":"failure encoding failed"}"#)
    }
}

/// Thrown by `resumeActivation` to carry the raw failure-reason buffer through the
/// cached-Task continuation back to `runActivity`, which decodes `A.Failure` from it.
/// This keeps `resumeActivation` generic (it doesn't know `A.Failure`) while letting
/// the typed `runActivity<A>` perform the decode.
struct _ActivityFailureSignal: Error {
    let failureReason: ByteBuffer?
    let retryState: ActivityRetryState
    let activityName: String
    let state: TaskState
}
