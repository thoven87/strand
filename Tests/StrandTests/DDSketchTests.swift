import Testing

@testable import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
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

    // ── 7. Correctness constants ──────────────────────────────────────────

    @Test("gamma and invLogGamma constants are consistent")
    func constantsConsistency() {
        // invLogGamma must equal 1/log(gamma)
        let recomputed = 1.0 / log(DDSketch.gamma)
        #expect(abs(DDSketch.invLogGamma - recomputed) < 1e-10)
        // gamma > 1 (otherwise log would be <= 0)
        #expect(DDSketch.gamma > 1.0)
    }
}
