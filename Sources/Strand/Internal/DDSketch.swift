#if canImport(Darwin)
import Darwin  // For macOS, iOS, watchOS, tvOS
#elseif canImport(Glibc)
import Glibc  // For Linux
#elseif os(Windows)
import ucrt  // For Windows
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
    /// Exact minimum value seen. `nil` when the sketch is empty.
    private(set) var minValue: Double? = nil
    /// Exact maximum value seen. `nil` when the sketch is empty.
    private(set) var maxValue: Double? = nil

    // MARK: - Mutation

    /// Record one measurement (in milliseconds).  Values ≤ 0 are silently ignored.
    public mutating func insert(_ ms: Double) {
        guard ms > 0 else { return }
        let bin = Int((log(ms) * Self.invLogGamma).rounded(.up))
        bins[bin, default: 0] += 1
        count += 1
        minValue = Swift.min(minValue ?? ms, ms)
        maxValue = Swift.max(maxValue ?? ms, ms)
    }

    /// Merge another sketch into this one (in-place).
    public mutating func merge(_ other: DDSketch) {
        for (bin, n) in other.bins {
            bins[bin, default: 0] += n
        }
        count += other.count
        if let otherMin = other.minValue {
            minValue = minValue.map { Swift.min($0, otherMin) } ?? otherMin
        }
        if let otherMax = other.maxValue {
            maxValue = maxValue.map { Swift.max($0, otherMax) } ?? otherMax
        }
    }

    // MARK: - Query

    /// Estimate the `q`-th quantile (0 … 1), returned in milliseconds.
    ///
    /// Returns `nil` when the sketch is empty.
    ///
    /// Special cases: `q == 0.0` returns the exact `minValue`; `q == 1.0`
    /// returns the exact `maxValue`.
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
        if q == 0.0 { return minValue }
        if q == 1.0 { return maxValue }
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

    /// Returns the approximate sum of all recorded values (in milliseconds).
    /// Uses the geometric midpoint of each bucket as the representative value.
    public func approximateSum() -> Double {
        bins.reduce(0.0) { acc, pair in
            let mid = exp2((Double(pair.key) - 0.5) * Self.log2gamma)
            return acc + mid * Double(pair.value)
        }
    }

    /// Returns the approximate mean of all recorded values (in milliseconds).
    /// Returns `nil` when the sketch is empty.
    public func approximateMean() -> Double? {
        count > 0 ? approximateSum() / Double(count) : nil
    }

    /// Returns all buckets as `(midpoint, count)` pairs, sorted by midpoint ascending.
    /// The midpoint is the geometric midpoint of the bucket's range.
    public func toList() -> [(midpoint: Double, count: Int)] {
        bins.keys.sorted().map { k in
            (midpoint: exp2((Double(k) - 0.5) * Self.log2gamma), count: bins[k]!)
        }
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
        /// Exact minimum value seen. `nil` when the sketch is empty (`size == 0`).
        public let min: Double?
        /// Exact maximum value seen. `nil` when the sketch is empty (`size == 0`).
        public let max: Double?

        public init(from sketch: DDSketch) {
            bins = Dictionary(uniqueKeysWithValues: sketch.bins.map { ("\($0.key)", $0.value) })
            size = sketch.count
            min = sketch.minValue
            max = sketch.maxValue
        }

        /// Estimate the `q`-th quantile (ms).  Returns `nil` for an empty sketch.
        /// Uses the geometric midpoint `γ^(k−0.5)` for symmetric ±2 % error.
        /// `q == 0.0` returns the exact `min`; `q == 1.0` returns the exact `max`.
        public func quantile(_ q: Double) -> Double? {
            guard size > 0, (0...1).contains(q) else { return nil }
            if q == 0.0 { return min }
            if q == 1.0 { return max }
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

        /// Returns the approximate sum of all recorded values (in milliseconds).
        public func approximateSum() -> Double {
            bins.reduce(0.0) { acc, pair in
                guard let k = Int(pair.key) else { return acc }
                let mid = exp2((Double(k) - 0.5) * DDSketch.log2gamma)
                return acc + mid * Double(pair.value)
            }
        }

        /// Returns the approximate mean (in milliseconds). `nil` when empty.
        public func approximateMean() -> Double? {
            size > 0 ? approximateSum() / Double(size) : nil
        }

        /// Returns all buckets as `(midpoint, count)` pairs, sorted by midpoint ascending.
        public func toList() -> [(midpoint: Double, count: Int)] {
            bins.compactMap { k, n -> (Double, Int)? in
                guard let ki = Int(k) else { return nil }
                return (exp2((Double(ki) - 0.5) * DDSketch.log2gamma), n)
            }.sorted { $0.0 < $1.0 }
        }

        /// Merge multiple serialised sketches into one so callers can query
        /// cross-queue quantiles without duplicating the quantile algorithm.
        /// Returns `nil` when the input array is empty.
        public static func merged(_ sketches: [Serialized]) -> Serialized? {
            guard !sketches.isEmpty else { return nil }
            var mergedBins: [String: Int] = [:]
            var mergedSize = 0
            var mergedMin: Double? = nil
            var mergedMax: Double? = nil
            for s in sketches {
                for (k, v) in s.bins { mergedBins[k, default: 0] += v }
                mergedSize += s.size
                if let m = s.min { mergedMin = mergedMin.map { Swift.min($0, m) } ?? m }
                if let m = s.max { mergedMax = mergedMax.map { Swift.max($0, m) } ?? m }
            }
            return Serialized(bins: mergedBins, size: mergedSize, min: mergedMin, max: mergedMax)
        }

        private init(bins: [String: Int], size: Int, min: Double?, max: Double?) {
            self.bins = bins
            self.size = size
            self.min = min
            self.max = max
        }
    }
}
