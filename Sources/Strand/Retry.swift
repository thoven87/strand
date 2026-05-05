// MARK: - RetryStrategy

/// Configures how a failed task is retried.
///
/// Use the static factory methods for the common patterns:
///
/// ```swift
/// // Exponential back-off (doubles each attempt, capped at 5 minutes):
/// RetryStrategy.backoff(initial: .seconds(2), multiplier: 2, cap: .minutes(5))
///
/// // Constant delay (same wait every time):
/// RetryStrategy.constant(.seconds(10))
/// ```
///
/// To skip retries for specific error types, chain `nonRetryable(_:)`:
///
/// ```swift
/// let strategy = RetryStrategy.backoff()
///     .nonRetryable(ValidationError.self)
///     .nonRetryable(NotFoundError.self)
/// ```
///
/// To disable retries entirely, set `maxAttempts: 1` on the enclosing
/// `EnqueueOptions` or `ActivityOptions` rather than using a strategy.
public struct RetryStrategy: Sendable, Codable {

    // MARK: Stored properties

    /// Delay before the first retry attempt.
    public var initialDelay: Duration

    /// Multiplier applied to the previous delay on each successive attempt.
    /// `2.0` doubles the wait every time; `1.0` gives a constant delay.
    public var multiplier: Double

    /// Upper bound on the computed delay.
    public var maxDelay: Duration

    /// Unqualified Swift type names (e.g. `"ValidationError"`) that must
    /// never trigger a retry — the task fails permanently on the first
    /// occurrence of a matching error type.
    ///
    /// Populated via `doNotRetry(_:)` and `nonRetryable(_:)` rather than
    /// raw string literals.
    public private(set) var nonRetryableErrorTypes: [String]

    // MARK: Initialiser

    public init(
        initialDelay: Duration = .seconds(2),
        multiplier: Double = 2.0,
        maxDelay: Duration = .seconds(300),
        nonRetryableErrorTypes: [String] = []
    ) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.nonRetryableErrorTypes = nonRetryableErrorTypes
    }

    // MARK: Factory methods

    /// Exponential back-off.
    public static func backoff(
        initial: Duration = .seconds(2),
        multiplier: Double = 2.0,
        cap: Duration = .seconds(300)
    ) -> RetryStrategy {
        RetryStrategy(initialDelay: initial, multiplier: multiplier, maxDelay: cap)
    }

    /// Constant delay between every attempt.
    public static func constant(_ delay: Duration) -> RetryStrategy {
        .backoff(initial: delay, multiplier: 1.0, cap: delay)
    }

    /// Retry without any delay, up to `cap` between attempts.
    public static func immediate(cap: Duration = .seconds(300)) -> RetryStrategy {
        .backoff(initial: .zero, multiplier: 1.0, cap: cap)
    }

    // MARK: Non-retryable error types

    /// Register an error type that must never trigger a retry.
    ///
    /// Matched against `String(describing: type(of: error))` — the
    /// unqualified Swift type name without module prefix.
    /// Duplicates are silently ignored.
    public mutating func doNotRetry<E: Error>(_ type: E.Type) {
        let name = String(describing: type)
        guard !nonRetryableErrorTypes.contains(name) else { return }
        nonRetryableErrorTypes.append(name)
    }

    /// Return a copy with the given error type added to the non-retryable list.
    public func nonRetryable<E: Error>(_ type: E.Type) -> RetryStrategy {
        var copy = self
        copy.doNotRetry(type)
        return copy
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case initialDelay = "initial_delay_seconds"
        case multiplier
        case maxDelay = "max_delay_seconds"
        case nonRetryableErrorTypes = "non_retryable_error_types"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let initial = (try? c.decode(Double.self, forKey: .initialDelay)) ?? 2
        let mult = (try? c.decode(Double.self, forKey: .multiplier)) ?? 2
        let maxD = (try? c.decode(Double.self, forKey: .maxDelay)) ?? 300
        let nret = try c.decodeIfPresent([String].self, forKey: .nonRetryableErrorTypes) ?? []
        self = RetryStrategy(
            initialDelay: .seconds(initial),
            multiplier: mult,
            maxDelay: .seconds(maxD),
            nonRetryableErrorTypes: nret
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(initialDelay.components.seconds, forKey: .initialDelay)
        try c.encode(multiplier, forKey: .multiplier)
        try c.encode(maxDelay.components.seconds, forKey: .maxDelay)
        if !nonRetryableErrorTypes.isEmpty {
            try c.encode(nonRetryableErrorTypes, forKey: .nonRetryableErrorTypes)
        }
    }
}

// MARK: - CancellationPolicy

/// Automatic cancellation rules applied to a task at enqueue time.
public struct CancellationPolicy: Sendable, Codable {
    /// Cancel if the task has been alive longer than this many seconds.
    public var maxDuration: Int?
    /// Cancel if no checkpoint has been written for this many seconds.
    public var maxDelay: Int?

    private enum CodingKeys: String, CodingKey {
        case maxDuration = "max_duration"
        case maxDelay = "max_delay"
    }

    public init(maxDuration: Int? = nil, maxDelay: Int? = nil) {
        self.maxDuration = maxDuration
        self.maxDelay = maxDelay
    }
}
