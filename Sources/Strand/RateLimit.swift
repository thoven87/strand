#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - RateLimit

/// Leaky-bucket rate limit applied when enqueuing an activity, workflow, or
/// generic task.  When set, each enqueue atomically claims a time slot; the
/// run waits in PENDING until its slot arrives.
///
/// Only enforced when explicitly set — `nil` (the default) means no rate limit
/// and the task is enqueued at full speed, exactly as without this option.
///
/// - `limit` / `period`: together define the slot interval.
///   `.init(limit: 10, period: .seconds(1))` → one slot every 100 ms.
///   `.init(limit: 2, period: .minutes(1))` → one slot every 30 s.
///
/// - `key`: static partition key — one bucket per unique value.
///
/// ```swift
/// // Global: 10 payment activities per second across all customers
/// options: .init(rateLimit: .init(limit: 10, period: .seconds(1)))
///
/// // Per-customer static key — computed at the call site
/// options: .init(
///     rateLimit: .init(limit: 2, period: .minutes(1), key: "customer:\(customerID)")
/// )
/// ```
public struct RateLimit: Sendable {
    /// Maximum executions allowed within `period`.
    public var limit: Double
    /// Time window over which `limit` applies. Default: `.seconds(1)`.
    public var period: Duration
    /// Optional partition key.  `nil` = one global bucket for this task
    /// type on this queue.  A non-nil value gives each entity its own bucket.
    public var key: String?

    /// When set, this string is used as the slot-key prefix — no task-name
    /// prefix is applied.  Use this to share a rate-limit bucket across multiple
    /// task types (e.g. all payment tasks sharing `"payments"`).
    ///
    /// - When only `sharedKey` is set the slot key is `sharedKey` verbatim
    ///   (one global bucket shared by all matching tasks).
    /// - When BOTH `sharedKey` and `key` are set the slot key is
    ///   `"sharedKey:key"` — per-entity buckets within the shared namespace.
    ///   Example: `sharedKey: "payments", key: "tenant-acme"` → `"payments:tenant-acme"`.
    public var sharedKey: String?

    /// Number of tasks that may be dispatched immediately from a cold bucket (or
    /// from any bucket that still has burst tokens remaining) before the regular
    /// per-interval drip begins.  Default `0` = no burst.
    public var burst: Int

    /// Number of rate-limit tokens this dispatch consumes from the shared bucket.
    /// Default `1` = one dispatch charges one slot.  Set to the number of
    /// external API calls made inside the activity so the bucket stays
    /// calibrated to actual outbound call volume rather than dispatch count.
    ///
    /// Example: a batch activity that calls a third-party API 50 times per run
    /// should set `units: 50` so the cursor advances 50× further on each
    /// dispatch, correctly throttling peer tasks on the same bucket.
    public var units: Int

    /// Derives the per-entity partition key from the task's typed input at
    /// enqueue time.  Set via the ``keyed(_:period:sharedKey:burst:units:by:)``
    /// factory, which wraps the `any Sendable` cast in a typed closure and
    /// adds a debug assertion for type mismatches.
    ///
    /// `internal` — callers should use `keyed(...)`, not set this directly.
    ///
    /// `nonisolated(unsafe)` because the closure is called exactly once,
    /// synchronously, inside `resolving(input:)` before anything crosses an
    /// isolation boundary.  The closure must be a pure function; `keyed`
    /// enforces this by construction (KeyPath reads and field accesses).
    nonisolated(unsafe) var keyExtractor: ((any Sendable) -> String?)?

    /// Returns `nil` when `limit` is not positive; no crash.
    public init?(limit: Double, period: Duration = .seconds(1), key: String? = nil, sharedKey: String? = nil, burst: Int = 0, units: Int = 1) {
        guard limit > 0 else { return nil }
        self.limit = limit
        self.period = period
        self.key = key
        self.sharedKey = sharedKey
        self.burst = burst
        self.units = max(1, units)
        self.keyExtractor = nil
    }

    // MARK: - Dynamic key factories

    /// Creates a rate limit whose per-entity key is derived from the task's
    /// input at enqueue time via a typed closure.
    ///
    /// The closure is evaluated while `Input` is still a concrete Swift
    /// value — before it is JSON-encoded.  This lets you declare the key schema
    /// once rather than repeating `key: input.tenantID` at every call site.
    ///
    /// ```swift
    /// // Declare once — Input type is inferred from the closure:
    /// static let rateLimitOpts = ActivityOptions(
    ///     rateLimit: .keyed(limit: 100, period: .minutes(1)) {
    ///         (input: ProcessPaymentInput) in input.customerID
    ///     }
    /// )
    ///
    /// // Every call site just passes the shared options:
    /// try await context.runActivity(ProcessPayment.self, input: input, options: .rateLimitOpts)
    /// ```
    static func keyed<Input: Sendable>(
        limit: Double,
        period: Duration = .seconds(1),
        sharedKey: String? = nil,
        burst: Int = 0,
        units: Int = 1,
        by keyExtractor: @escaping (Input) -> String?
    ) -> RateLimit? {
        // Optional.map on the failable init handles the limit <= 0 guard;
        // the transform sets keyExtractor on the valid copy and returns it.
        RateLimit(limit: limit, period: period, sharedKey: sharedKey, burst: burst, units: units).map { base in
            var rl = base
            rl.keyExtractor = { anyInput in
                guard let typed = anyInput as? Input else {
                    assertionFailure(
                        "RateLimit keyExtractor: expected \(Input.self), got \(type(of: anyInput)). "
                            + "Ensure the RateLimit is used with the matching task's Input type."
                    )
                    return nil
                }
                return keyExtractor(typed)
            }
            return rl
        }
    }

    /// KeyPath overload — derives the per-entity key from a non-optional property.
    ///
    /// ```swift
    /// rateLimit: .keyed(limit: 100, period: .minutes(1), by: \ProcessPaymentInput.customerID)
    /// ```
    static func keyed<Input: Sendable>(
        limit: Double,
        period: Duration = .seconds(1),
        sharedKey: String? = nil,
        burst: Int = 0,
        units: Int = 1,
        by keyPath: KeyPath<Input, String>
    ) -> RateLimit? {
        keyed(limit: limit, period: period, sharedKey: sharedKey, burst: burst, units: units) {
            (input: Input) in input[keyPath: keyPath]
        }
    }

    /// KeyPath overload — derives the per-entity key from an optional property.
    /// Returns `nil` (global bucket) when the property itself is `nil`.
    ///
    /// ```swift
    /// rateLimit: .keyed(limit: 100, period: .minutes(1), by: \SyncVisitsPageInput.officeID)
    /// ```
    static func keyed<Input: Sendable>(
        limit: Double,
        period: Duration = .seconds(1),
        sharedKey: String? = nil,
        burst: Int = 0,
        units: Int = 1,
        by keyPath: KeyPath<Input, String?>
    ) -> RateLimit? {
        keyed(limit: limit, period: period, sharedKey: sharedKey, burst: burst, units: units) {
            (input: Input) in input[keyPath: keyPath]
        }
    }

    // MARK: - Internal

    /// Slot-allocation parameters for the `strand.rate_limit_slots` SQL.
    ///
    /// - Parameter taskName: the task's registered name (activity or workflow name).
    ///   Used as the bucket prefix when `key` is `nil` (global bucket),
    ///   or as the prefix in `"TaskName:entityKey"` (per-entity bucket).
    /// - Returns: `slotKey` — the row key in `strand.rate_limit_slots`;
    ///   `intervalMs` — milliseconds between consecutive slots,
    ///   derived from `(period / limit) × units` and clamped to at least 1 ms;
    ///   `burstSlots` — number of tasks eligible for immediate dispatch.
    ///
    /// - Note: Uses `self.key` directly.  When a `keyExtractor` is present,
    ///   call sites must resolve it first via `resolving(input:)` so the
    ///   per-entity key is written into `self.key` before this is invoked.
    internal func slotParams(for taskName: String) -> (slotKey: String, intervalMs: Int, burstSlots: Int) {
        let slotKey: String
        if let sk = sharedKey {
            // sharedKey as namespace: append per-entity key when present.
            slotKey = key.map { "\(sk):\($0)" } ?? sk
        } else {
            slotKey = key.map { "\(taskName):\($0)" } ?? taskName
        }
        let intervalMs = max(1, Int(Double(period.milliseconds) / limit)) * units
        return (slotKey: slotKey, intervalMs: intervalMs, burstSlots: max(0, burst))
    }

    /// Resolves `key` in-place from `input` via `keyExtractor`.
    /// No-op when no extractor is set.
    internal mutating func resolve(input: any Sendable) {
        guard let extractor = keyExtractor else { return }
        key = extractor(input)
    }

    /// Returns a copy with `key` resolved from `input`.
    /// Used where a mutating call isn’t possible (e.g. inside `Optional.map`).
    internal func resolving(input: any Sendable) -> RateLimit {
        var copy = self
        copy.resolve(input: input)
        return copy
    }
}
