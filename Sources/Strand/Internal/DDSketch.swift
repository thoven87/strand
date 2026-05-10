#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - DDSketch

/// A DDSketch histogram with 2 % relative error.
///
/// ## How it works
///
/// Each measurement is mapped to a logarithmic bucket:
///
///     bin(v) = ⌈log(v) / log(γ)⌉
///
/// where `γ = (1 + ε) / (1 − ε)` and `ε = 0.02`. Values inside the same
/// bucket are at most 2 % apart, so any quantile estimate has at most 2 %
/// relative error.  The number of buckets grows as `O(log(max/min))` which
/// for millisecond timings (1 ms – 10 min) is roughly 300 bins regardless of
/// how many measurements were recorded.
///
/// ## Thread safety
///
/// `DDSketch` is a value type (`struct`).  Use a `Mutex` or similar when
/// sharing across tasks; see ``AggregatedMetricsBuffer``.
public struct DDSketch: Sendable {

    // MARK: - Constants

    public static let errorRate: Double = 0.02
    /// γ = (1 + ε) / (1 − ε)
    public static let gamma: Double = (1 + errorRate) / (1 - errorRate)  // ≈ 1.0408
    /// 1 / log(γ)  — multiply by log(v) to get the bin index
    public static let invLogGamma: Double = 1.0 / log(gamma)  // ≈ 25.07
    /// log₂(γ) — used with exp2() for fast bucket midpoint reconstruction.
    /// Avoids per-call log() inside pow(): γ^x = 2^(x · log₂γ).
    public static let log2gamma: Double = log2(gamma)  // ≈ 0.05715

    // MARK: - Storage

    /// Logarithmic bucket index → observation count.
    private(set) var bins: [Int: Int] = [:]
    /// Total number of observations inserted.
    private(set) var count: Int = 0

    // MARK: - Mutation

    /// Record one measurement (in milliseconds).  Values ≤ 0 are silently ignored.
    public mutating func insert(_ ms: Double) {
        guard ms > 0 else { return }
        let bin = Int((log(ms) * Self.invLogGamma).rounded(.up))
        bins[bin, default: 0] += 1
        count += 1
    }

    /// Merge another sketch into this one (in-place).
    public mutating func merge(_ other: DDSketch) {
        for (bin, n) in other.bins {
            bins[bin, default: 0] += n
        }
        count += other.count
    }

    // MARK: - Query

    /// Estimate the `q`-th quantile (0 … 1), returned in milliseconds.
    ///
    /// Returns `nil` when the sketch is empty.
    ///
    /// ## Error guarantee
    ///
    /// Each value `v` is placed in bucket `k = ⌈log(v)/log(γ)⌉`.  The estimate
    /// uses the *geometric midpoint* `γ^(k‒0.5)` rather than the ceiling `γ^k`.
    /// Any value `v` in bucket `k` satisfies `γ^(k−1) < v ≤ γ^k`, so:
    ///
    ///   max overestimate  = γ^(k−0.5) / γ^(k−1) − 1 = γ^0.5 − 1 ≈ 2 %
    ///   max underestimate = 1 − γ^(k−0.5) / γ^k   = 1 − γ^(−0.5) ≈ 2 %
    ///
    /// This matches the symmetric `±2 %` guarantee cited in the DDSketch paper.
    public func quantile(_ q: Double) -> Double? {
        guard count > 0, (0...1).contains(q) else { return nil }
        let target = Int((q * Double(count)).rounded(.up))
        var accumulated = 0
        for key in bins.keys.sorted() {
            accumulated += bins[key, default: 0]
            if accumulated >= target {
                // Geometric midpoint: γ^(k−0.5) = 2^((k−0.5) · log₂γ)
                // exp2 maps to a single hardware instruction; pow() would
                // internally compute exp(x·log(γ)), paying log() every call.
                return exp2((Double(key) - 0.5) * Self.log2gamma)
            }
        }
        return nil
    }

    // MARK: - Serialisation

    /// A `Codable` representation that fits inside a `pg_notify` payload.
    ///
    /// JSON dict keys must be strings, so bin indices are encoded as their
    /// decimal string representation.  The decoder converts them back to `Int`.
    public struct Serialized: Codable, Sendable {
        /// Bucket index (as decimal string) → observation count.
        public let bins: [String: Int]
        /// Total number of observations.
        public let size: Int

        public init(from sketch: DDSketch) {
            bins = Dictionary(uniqueKeysWithValues: sketch.bins.map { ("\($0.key)", $0.value) })
            size = sketch.count
        }

        /// Estimate the `q`-th quantile (ms).  Returns `nil` for an empty sketch.
        /// Uses the geometric midpoint `γ^(k−0.5)` for symmetric ±2 % error.
        public func quantile(_ q: Double) -> Double? {
            guard size > 0, (0...1).contains(q) else { return nil }
            let target = Int((q * Double(size)).rounded(.up))
            let sorted = bins.compactMap { k, v -> (Int, Int)? in
                Int(k).map { ($0, v) }
            }.sorted { $0.0 < $1.0 }
            var accumulated = 0
            for (key, n) in sorted {
                accumulated += n
                if accumulated >= target {
                    return exp2((Double(key) - 0.5) * DDSketch.log2gamma)
                }
            }
            return nil
        }
    }
}
