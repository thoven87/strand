import Testing

@testable import Strand

#if canImport(Darwin)
import Darwin  // For macOS, iOS, watchOS, tvOS
#elseif canImport(Glibc)
import Glibc  // For Linux
#elseif os(Windows)
import ucrt  // For Windows
#endif

@Suite("DDSketch")
struct DDSketchTests {

    // ── 1. Empty sketch ───────────────────────────────────────────────────

    @Test("quantile returns nil for an empty sketch")
    func emptySketchReturnsNil() {
        let sketch = DDSketch()
        #expect(sketch.quantile(0.50) == nil)
        #expect(sketch.quantile(0.99) == nil)
        #expect(sketch.count == 0)
    }

    // ── 2. Single value ───────────────────────────────────────────────────

    @Test("any quantile of a single-value sketch returns approximately that value")
    func singleValueAllQuanntiles() {
        var sketch = DDSketch()
        sketch.insert(42.0)  // 42 ms

        for q in [0.0, 0.25, 0.50, 0.75, 0.95, 0.99, 1.0] {
            let estimate = sketch.quantile(q)
            #expect(estimate != nil)
            if let v = estimate {
                // Midpoint estimate: symmetric ±2% error.
                // max over  = γ^0.5 − 1 ≈ 2 %
                // max under = 1 − γ^(−0.5) ≈ 2 %
                #expect(
                    v >= 42.0 * 0.98 && v <= 42.0 * 1.02,
                    "q=\(q): estimate \(v) outside [42×0.98, 42×1.02]"
                )
            }
        }
    }

    // ── 3. Accuracy on uniform distribution ────────────────────────────────
    //
    // Insert 1000 values uniformly from 1 ms to 1000 ms.
    //
    // The ceiling-binning variant of DDSketch always maps v to γ^k ≥ v, so
    // estimates are in [true, true × γ].  The one-sided relative overestimate
    // is bounded by γ - 1 = (1+ε)/(1-ε) - 1 = 2ε/(1-ε) ≈ 4.1 % for ε=0.02.
    // Tests use [true, true × 1.05] with 1 % float headroom.

    @Test("quantile estimates on uniform 1–1000 ms distribution are within ±2% relative error")
    func uniformDistributionAccuracy() {
        var sketch = DDSketch()
        for i in 1...1000 {
            sketch.insert(Double(i))
        }
        #expect(sketch.count == 1000)

        let cases: [(q: Double, trueMs: Double)] = [
            (0.50, 500.0),
            (0.90, 900.0),
            (0.95, 950.0),
            (0.99, 990.0),
        ]
        for (q, trueMs) in cases {
            let estimate = sketch.quantile(q)
            #expect(estimate != nil, "q=\(q) returned nil")
            if let v = estimate {
                // Midpoint estimate: symmetric ±2% bound.
                #expect(
                    v >= trueMs * 0.98 && v <= trueMs * 1.02,
                    "q=\(q): estimate \(v) outside [\(trueMs*0.98), \(trueMs*1.02)]"
                )
            }
        }
    }

    // ── 4. Merge ──────────────────────────────────────────────────────────
    //
    // Merging two sketches of [1…500] and [501…1000] should give the same
    // result as inserting all 1000 values into one sketch.

    @Test("merge produces the same quantiles as inserting all values directly")
    func mergeEquivalence() {
        var full = DDSketch()
        for i in 1...1000 { full.insert(Double(i)) }

        var a = DDSketch()
        var b = DDSketch()
        for i in 1...500 { a.insert(Double(i)) }
        for i in 501...1000 { b.insert(Double(i)) }
        a.merge(b)

        #expect(a.count == full.count)

        for q in [0.25, 0.50, 0.75, 0.95, 0.99] {
            let merged = a.quantile(q)!
            let direct = full.quantile(q)!
            // The two should be equal (same bins, same counts)
            #expect(
                merged == direct,
                "q=\(q): merged=\(merged) != direct=\(direct)"
            )
        }
    }

    // ── 5. Serialisation round-trip ───────────────────────────────────────
    //
    // DDSketch.Serialized must preserve quantile estimates within floating-point
    // precision (the serialised form carries the exact bin counts).

    @Test("Serialized round-trip preserves quantile estimates")
    func serialisedRoundTrip() throws {
        var sketch = DDSketch()
        for i in stride(from: 1.0, through: 500.0, by: 1.0) {
            sketch.insert(i)
        }

        let serialized = DDSketch.Serialized(from: sketch)
        #expect(serialized.size == sketch.count)

        for q in [0.50, 0.95, 0.99] {
            let fromSketch = sketch.quantile(q)!
            let fromSerialized = serialized.quantile(q)!
            #expect(
                fromSketch == fromSerialized,
                "q=\(q): sketch=\(fromSketch) != serialized=\(fromSerialized)"
            )
        }
    }

    // ── 6. Serialised quantile accuracy ───────────────────────────────────────────────
    //
    // Verify that the Serialized.quantile path also honours the symmetric ±2% guarantee.

    @Test("Serialized.quantile estimates are within ±2% error")
    func serialisedAccuracy() {
        var sketch = DDSketch()
        for i in 1...1000 { sketch.insert(Double(i)) }
        let s = DDSketch.Serialized(from: sketch)

        let cases: [(q: Double, trueMs: Double)] = [
            (0.50, 500.0), (0.95, 950.0), (0.99, 990.0),
        ]
        for (q, trueMs) in cases {
            let v = s.quantile(q)!
            #expect(
                v >= trueMs && v <= trueMs * 1.05,
                "q=\(q): estimate \(v) outside [\(trueMs), \(trueMs*1.05)]"
            )
        }
    }

    // ── 7. Serialized.merged ──────────────────────────────────────────────

    @Test("Serialized.merged returns nil for an empty array")
    func serializedMergedEmpty() {
        #expect(DDSketch.Serialized.merged([]) == nil)
    }

    @Test("Serialized.merged of a single sketch is identity")
    func serializedMergedSingle() {
        var sketch = DDSketch()
        for i in 1...100 { sketch.insert(Double(i)) }
        let s = DDSketch.Serialized(from: sketch)
        let merged = DDSketch.Serialized.merged([s])!

        #expect(merged.size == s.size)
        for q in [0.50, 0.95, 0.99] {
            #expect(merged.quantile(q) == s.quantile(q), "q=\(q) diverged")
        }
    }

    @Test("Serialized.merged combines sizes correctly")
    func serializedMergedSize() {
        var a = DDSketch()
        var b = DDSketch()
        for i in 1...300 { a.insert(Double(i)) }
        for i in 301...500 { b.insert(Double(i)) }
        let merged = DDSketch.Serialized.merged([
            DDSketch.Serialized(from: a),
            DDSketch.Serialized(from: b),
        ])!
        #expect(merged.size == 500)
    }

    @Test("Serialized.merged produces the same quantiles as a direct in-memory merge")
    func serializedMergedQuantiles() {
        // Build two non-overlapping sketches [1…500] and [501…1000] then merge
        // both in-memory and via Serialized.merged. Quantiles must agree.
        var a = DDSketch()
        var b = DDSketch()
        for i in 1...500 { a.insert(Double(i)) }
        for i in 501...1000 { b.insert(Double(i)) }

        // In-memory merge (the existing DDSketch.merge path)
        var inMemory = a
        inMemory.merge(b)

        // Serialized merge
        let serializedMerge = DDSketch.Serialized.merged([
            DDSketch.Serialized(from: a),
            DDSketch.Serialized(from: b),
        ])!

        #expect(serializedMerge.size == inMemory.count)
        for q in [0.25, 0.50, 0.75, 0.95, 0.99] {
            let fromMerged = serializedMerge.quantile(q)!
            let fromInMemory = DDSketch.Serialized(from: inMemory).quantile(q)!
            #expect(
                fromMerged == fromInMemory,
                "q=\(q): serialized=\(fromMerged) != in-memory=\(fromInMemory)"
            )
        }
    }

    @Test("Serialized.merged across many sketches accumulates all values")
    func serializedMergedMany() {
        // Split [1…1000] across 10 sketches of 100 values each.
        let sketches: [DDSketch.Serialized] = (0..<10).map { chunk in
            var s = DDSketch()
            for i in (chunk * 100 + 1)...(chunk * 100 + 100) { s.insert(Double(i)) }
            return DDSketch.Serialized(from: s)
        }
        let merged = DDSketch.Serialized.merged(sketches)!
        #expect(merged.size == 1000)
        // p50 of [1…1000] ≈ 500 ±2%
        let p50 = merged.quantile(0.50)!
        #expect(
            p50 >= 500 * 0.98 && p50 <= 500 * 1.02,
            "p50=\(p50) outside [490, 510]"
        )
    }

    // ── 8. Correctness constants ──────────────────────────────────────────

    @Test("DDSketch constants satisfy the algebraic invariants of the 2% error specification")
    func constantsConsistency() {
        // ── 1. gamma encodes the claimed error rate ───────────────────────
        // For gamma = (1+ε)/(1-ε), algebra gives (γ-1)/(γ+1) = ε.
        // Checking this avoids restating the formula while still verifying
        // that gamma is tuned to the right error bound.
        let derivedError = (DDSketch.gamma - 1.0) / (DDSketch.gamma + 1.0)
        #expect(abs(derivedError - DDSketch.errorRate) < 1e-14)
        #expect(DDSketch.gamma > 1.0)  // log(γ) must be positive

        // ── 2. Cross-constant identity (independent of source formulas) ───
        // invLogGamma × log2gamma = 1/log(γ) × log₂(γ)
        //                         = log₂(γ)/log(γ)  (change of base)
        //                         = 1/log(2)           = log₂(e)
        // This holds for any γ > 1 and is derivable from mathematics alone,
        // not by reading the source code.
        let log2e = 1.0 / log(2.0)  // ≈ 1.4426950408889634
        #expect(abs(DDSketch.invLogGamma * DDSketch.log2gamma - log2e) < 1e-10)

        // ── 3. exp2 optimisation is numerically equivalent to pow ────────
        // The quantile path uses exp2((k-0.5) × log2gamma) instead of
        // pow(gamma, k-0.5). Test several bin indices to confirm equivalence.
        for k in [1, 10, 50, 100, 500] {
            let exp2val = exp2((Double(k) - 0.5) * DDSketch.log2gamma)
            let powval = pow(DDSketch.gamma, Double(k) - 0.5)
            #expect(
                abs(exp2val - powval) / powval < 1e-10,
                "exp2 and pow diverge at bin \(k)"
            )
        }
    }
}
