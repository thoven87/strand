package import NIOCore

#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

// MARK: - ActivityError

/// Thrown by `WorkflowContext.runActivity(_:input:options:)` when the activity
/// reaches a terminal non-success state after exhausting all retry attempts.
///
/// The underlying error from the activity lives in ``cause`` so workflows can
/// inspect it without matching on raw string activity names.
///
/// ```swift
/// do {
///     let result = try await context.runActivity(ChargeCardActivity.self, input: req)
/// } catch let err as ActivityError {
///     if err.retryState == .maximumAttemptsReached {
///         // compensate — roll back earlier steps
///     }
///     logger.error("activity failed", metadata: ["cause": "\(err.cause?.localizedDescription ?? "")"])
/// }
/// ```
public struct ActivityError: Error, LocalizedError, Sendable {
    /// The registered name of the failed activity (e.g. `"charge-card"`).
    public let activityName: String
    /// Why the activity stopped retrying.
    public let retryState: ActivityRetryState
    /// The underlying error thrown by the activity, deserialized from
    /// `strand.runs.failure_reason`. `nil` when no failure reason was stored.
    public let cause: (any Error & Sendable)?

    public init(
        activityName: String,
        retryState: ActivityRetryState,
        cause: (any Error & Sendable)? = nil
    ) {
        self.activityName = activityName
        self.retryState = retryState
        self.cause = cause
    }

    public var errorDescription: String? {
        var msg = "Activity '\(activityName)' failed: \(retryState)"
        if let c = cause { msg += " — \(c.localizedDescription)" }
        return msg
    }
}

// MARK: - ActivityRetryState

/// Why an activity stopped executing.
public enum ActivityRetryState: String, Sendable, CustomStringConvertible {
    /// All configured retry attempts were exhausted and the activity still failed.
    case maximumAttemptsReached
    /// The activity was cancelled — either by the workflow, or because the worker shut down.
    case cancelled

    public var description: String { rawValue }
}

// MARK: - ActivityFailure

/// Deserialized representation of an activity's stored failure reason.
///
/// When `runActivity()` throws `ActivityError`, the ``ActivityError/cause`` is an
/// `ActivityFailure` decoded from `strand.runs.failure_reason`. This lets workflows
/// inspect the original error type name and message without a direct type dependency
/// on the activity's error type.
///
/// ```swift
/// } catch let err as ActivityError {
///     if let failure = err.cause as? ActivityFailure {
///         print(failure.name)     // "OllamaActivityError"
///         print(failure.message)  // "Ollama returned HTTP 500"
///         print(failure.fileID)   // "AIAgent/OllamaCallActivity.swift"
///         print(failure.line)     // 42
///     }
/// }
/// ```
public struct ActivityFailure: Error, LocalizedError, Sendable {
    /// The Swift type name of the original error (e.g. `"OllamaActivityError"`).
    public let name: String
    /// The `localizedDescription` of the original error.
    public let message: String
    /// The source file captured by `#fileID` at the `context.runActivity(...)` call site.
    public let fileID: String?
    /// The source line captured by `#line` at the `context.runActivity(...)` call site.
    public let line: Int?

    public var errorDescription: String? { "\(name): \(message)" }
}

extension ActivityFailure {
    /// Attempt to deserialize an `ActivityFailure` from the raw JSON stored in
    /// `strand.runs.failure_reason`. Returns `nil` when the buffer is unreadable.
    package static func decode(from buffer: ByteBuffer) -> ActivityFailure? {
        struct Payload: Decodable {
            let name: String
            let message: String
            let source: Source?
            struct Source: Decodable {
                let file_id: String?
                let line: Int?
            }
        }
        guard let payload = try? JSON.decode(Payload.self, from: buffer) else { return nil }
        return ActivityFailure(
            name: payload.name,
            message: payload.message,
            fileID: payload.source?.file_id,
            line: payload.source?.line
        )
    }
}
