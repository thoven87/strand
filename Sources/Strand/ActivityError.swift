package import NIOCore

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// MARK: - ActivityError

/// Fallback error thrown by `WorkflowContext.runActivity(_:input:options:)` when
/// an activity with `Failure = Never` (or an unrecognised payload) reaches a
/// terminal non-success state.
///
/// ## Typed failures (preferred)
///
/// When an activity declares `typealias Failure = MyError` (where `MyError: Codable`),
/// `runActivity` decodes and throws `MyError` **directly** — no `ActivityError` wrapper:
///
/// ```swift
/// // Activity declares: typealias Failure = PaymentError
/// do {
///     let result = try await context.runActivity(ChargeCardActivity.self, input: req)
/// } catch let err as PaymentError {
///     // err is the original typed value — no unwrapping needed
/// }
/// ```
///
/// ## Untyped fallback
///
/// For activities with `Failure = Never` (the default), `ActivityError` is thrown.
/// ``cause`` carries an ``ActivityFailure`` with the stored name and message:
///
/// ```swift
/// } catch let err as ActivityError {
///     if err.retryState == .maximumAttemptsReached {
///         // compensate — roll back earlier steps
///     }
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
/// When `runActivity()` cannot decode the original typed `A.Failure` value
/// (e.g. when the activity declared `Failure = Never`), it falls back to
/// throwing ``ActivityError`` whose ``ActivityError/cause`` is an
/// `ActivityFailure`.
///
/// ```swift
/// } catch let err as ActivityError {
///     if let failure = err.cause as? ActivityFailure {
///         print(failure.name)     // "OllamaActivityError"
///         print(failure.message)  // "Ollama returned HTTP 500"
///     }
/// }
/// ```
public struct ActivityFailure: Error, LocalizedError, Sendable {
    /// The Swift type name of the original error (e.g. `"OllamaActivityError"`).
    public let name: String
    /// The `localizedDescription` of the original error.
    public let message: String
    /// Base64-encoded JSON of the original `Failure` value (if it was `Codable`).
    /// Use `decode(_:)` to recover the original typed error.
    let payload: Data?

    public var errorDescription: String? { "\(name): \(message)" }

    /// Attempts to decode the original typed failure value from the stored payload.
    ///
    /// Returns `nil` when no payload is stored (activity declared `Failure = Never`)
    /// or when the payload cannot be decoded as `F`.
    ///
    /// ```swift
    /// } catch let err as ActivityError {
    ///     if let bankErr = (err.cause as? ActivityFailure)?.decode(BankAccountError.self) {
    ///         print(bankErr)  // BankAccountError.invalidDetails
    ///     }
    /// }
    /// ```
    public func decode<F: Error & Decodable>(_ type: F.Type) -> F? {
        guard let data = payload else { return nil }
        let buf = ByteBuffer(bytes: data)
        return try? JSON.decode(type, from: buf)
    }
}

extension ActivityFailure {
    /// Deserialise an `ActivityFailure` from the raw JSON stored in
    /// `strand.runs.failure_reason`. Returns `nil` when the buffer is unreadable.
    package static func decode(from buffer: ByteBuffer) -> ActivityFailure? {
        struct Payload: Decodable {
            let name: String
            let message: String
            let payload: Data?
        }
        guard let p = try? JSON.decode(Payload.self, from: buffer) else { return nil }
        return ActivityFailure(name: p.name, message: p.message, payload: p.payload)
    }
}
