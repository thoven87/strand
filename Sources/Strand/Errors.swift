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
    /// No registered handler found for the given task name.
    case unknownTask(name: String)
    /// Queue name is empty or exceeds 57 UTF-8 bytes.
    case invalidQueueName(String)
    /// A Postgres-level error propagated from PostgresNIO.
    case database(underlying: any Error)
    /// JSON encoding or decoding failed.
    case serialization(underlying: any Error)
    /// Installed schema version is older than the SDK requires.
    case schemaMismatch(installed: String, required: String)

    // MARK: - LocalizedError

    /// Human-readable description stored in `strand.runs.failure_reason` and
    /// surfaced in the dashboard. Without this, Foundation generates the
    /// cryptic "The operation couldn't be completed. (Strand.StrandError error N.)".
    public var errorDescription: String? {
        switch self {
        case .timeout(let msg): return "Timeout: \(msg)"
        case .unknownTask(let name): return "No registered handler for task '\(name)'"
        case .invalidQueueName(let name): return "Invalid queue name '\(name)'"
        case .database(let err): return "Database error: \(err)"
        case .serialization(let err): return "Serialization error: \(err)"
        case .schemaMismatch(let ins, let req):
            return "Schema mismatch: installed \(ins), required \(req)"
        }
    }
}

// MARK: - WorkflowError

/// Thrown when a workflow execution reaches a terminal non-success state.
///
/// Raised by both ``WorkflowHandle/result(timeout:)`` (root workflow) and
/// ``WorkflowContext/runChildWorkflow(_:options:input:)`` (nested workflow).
/// This keeps workflows as a distinct first-class concept — separate from
/// ``ActivityError`` even though both represent "a unit of work that failed".
///
/// ```swift
/// do {
///     let result = try await handle.result(timeout: .seconds(60))
/// } catch let err as WorkflowError {
///     switch err.state {
///     case .failed:    // workflow threw an unhandled error
///     case .cancelled: // cancelTask() was called externally
///     default: break
///     }
/// }
/// ```
public struct WorkflowError: Error, LocalizedError, Sendable {
    /// The registered name of the workflow (e.g. `"OrderWorkflow"`).
    public let workflowName: String
    /// The terminal status the workflow reached.
    public let state: TaskStatus

    public var errorDescription: String? {
        "Workflow '\(workflowName)' reached terminal state: \(state.rawValue)"
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

// MARK: - RetryAfterError

/// Conforming errors carry a server-side retry delay that overrides the task's
/// configured `RetryStrategy` backoff **for the next attempt only**.
///
/// Use this when the failure contains authoritative retry guidance — for example,
/// a `Retry-After` HTTP header from a rate-limited API — that should take
/// precedence over the local exponential backoff schedule:
///
/// ```swift
/// struct RateLimitError: Error, RetryAfterError {
///     let retryAfter: Duration
///     var nextRetryDelay: Duration { retryAfter }
/// }
///
/// // In an activity:
/// func run(input: Input, context: ActivityContext) async throws -> Output {
///     let response = try await apiClient.fetch(input.url)
///     if response.statusCode == 429 {
///         let seconds = Int(response.headers["Retry-After"] ?? "60") ?? 60
///         throw RateLimitError(retryAfter: .seconds(seconds))
///     }
///     // ...
/// }
/// ```
///
/// Unlike `NonRetryableError`, conforming does **not** consume the retry budget.
/// The task is retried on the normal schedule except that `nextRetryDelay`
/// replaces the backoff computation for the single upcoming retry.
/// Subsequent retries (if any) return to the configured `RetryStrategy`.
public protocol RetryAfterError: Error {
    /// The duration to wait before the next retry attempt.
    var nextRetryDelay: Duration { get }
}

/// Ready-made ``RetryAfterError`` for one-liners at the throw site.
///
/// Use this when you don't want to define a dedicated error type:
///
/// ```swift
/// if response.statusCode == 429 {
///     let delay = Int(response.headers["Retry-After"] ?? "60") ?? 60
///     throw RetryAfterDelay(.seconds(delay), "GitHub rate-limited")
/// }
/// ```
///
/// For strongly-typed errors (recommended when you need to `catch` the specific
/// case in a workflow), define your own type that conforms to ``RetryAfterError``
/// instead.
public struct RetryAfterDelay: Error, RetryAfterError, CustomStringConvertible, Sendable {
    public let nextRetryDelay: Duration
    public let description: String

    /// - Parameters:
    ///   - delay:   How long to wait before the next attempt.
    ///   - message: Human-readable reason stored in the failure record.
    ///              Defaults to `"Retry after \(delay)"` when omitted.
    public init(_ delay: Duration, _ message: String? = nil) {
        self.nextRetryDelay = delay
        self.description = message ?? "Retry after \(delay)"
    }
}

// MARK: - Internal failure signals

/// Pre-encoded activity failure reason thrown from `Activity._run`.
/// Carries the JSON BYTEA that should be stored verbatim in `strand.runs.failure_reason`.
/// `StrandWorker.runTask` catches this to bypass re-encoding in `FailureReason`.
struct _TypedActivityFailure: Error, CustomStringConvertible {
    let reasonBuffer: ByteBuffer

    // MARK: - Private Codable helpers

    private struct _Reason: Decodable {
        let name: String
        let message: String
    }

    private struct _Payload: Encodable {
        let name: String
        let message: String
        let nonRetryable: Bool?
        let payload: Data?  // synthesised Encodable base64-encodes Data automatically
        let source: _Source?
        enum CodingKeys: String, CodingKey {
            case name, message, payload, source
            case nonRetryable = "non_retryable"
        }
        struct _Source: Encodable {
            let fileId: String
            let line: Int
            enum CodingKeys: String, CodingKey {
                case fileId = "file_id"
                case line
            }
        }
    }

    /// Pre-encoded sentinel buffer for `init(name:message:payload:nonRetryable:source:)`
    /// fallback.  The fallback is unreachable in practice; the constant centralises the
    /// literal in the type rather than scattering it at call sites.
    static let fallback: ByteBuffer = ByteBuffer(
        string: #"{"name":"unknown","message":"failure encoding failed"}"#
    )

    /// Human-readable description used by OTel’s `withSpan` when recording this
    /// error as an exception attribute on the activity span.
    /// Without this, swift-distributed-tracing falls back to `String(describing:)`
    /// which emits the raw struct internals: `_TypedActivityFailure(reasonBuffer: [7b...])`.
    var description: String {
        if let r = try? JSON.decode(_Reason.self, from: reasonBuffer) {
            return "\(r.name): \(r.message)"
        }
        return "activity failed"
    }

    /// Builds the failure reason payload and encodes it as JSON.
    /// Falls back to a minimal JSON string if encoding itself fails.
    init(name: String, message: String, payload: ByteBuffer?, nonRetryable: Bool, source: (fileID: String, line: Int)? = nil) {
        let p = _Payload(
            name: name,
            message: message,
            nonRetryable: nonRetryable ? true : nil,
            payload: payload.map { Data($0.readableBytesView) },
            source: source.map { _Payload._Source(fileId: $0.fileID, line: $0.line) }
        )
        // If encoding fails (essentially never) fall back to a static safe string.
        // We can't trust arbitrary content in `name` for manual JSON escaping,
        // so drop it and keep only the error signal.
        self.reasonBuffer = (try? JSON.encode(p)) ?? _TypedActivityFailure.fallback
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
