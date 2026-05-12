#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

extension UUID {
    /// Generates a UUID version 7 — time-ordered with random data in the low bits.
    ///
    /// Layout (RFC 9562):
    /// ```
    /// 0                   1                   2                   3
    ///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    /// ├─────────────────────────────────────────────────────────────────┤
    /// │                   unix_ts_ms (48 bits)                          │
    /// ├────────────────────────────────┬──────────────────────────────  │
    /// │  ver = 0111 (4 bits)           │  rand_a (12 bits)              │
    /// ├──┬─────────────────────────────┴──────────────────────────────  │
    /// │10│  rand_b (62 bits)                                            │
    /// └──┴──────────────────────────────────────────────────────────────┘
    /// ```
    ///
    /// UUIDv7 is monotonically increasing within the same millisecond
    /// (via the random `rand_a` field) and time-ordered across milliseconds.
    /// This keeps B-tree index inserts sequential on `strand.tasks` and
    /// `strand.runs`, dramatically reducing index fragmentation compared to
    /// random UUIDv4.
    package static func v7() -> UUID {
        // 48-bit Unix timestamp in milliseconds
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)

        let b0 = UInt8((ms >> 40) & 0xFF)
        let b1 = UInt8((ms >> 32) & 0xFF)
        let b2 = UInt8((ms >> 24) & 0xFF)
        let b3 = UInt8((ms >> 16) & 0xFF)
        let b4 = UInt8((ms >> 8) & 0xFF)
        let b5 = UInt8(ms & 0xFF)

        // 4-bit version (0111) | 4 random bits  (byte 6)
        let b6 = 0x70 | UInt8.random(in: 0...0x0F)
        // 8 random bits — rand_a low byte       (byte 7)
        let b7 = UInt8.random(in: 0...0xFF)

        // 2-bit variant (10) | 6 random bits    (byte 8)
        let b8 = 0x80 | UInt8.random(in: 0...0x3F)
        let b9 = UInt8.random(in: 0...0xFF)
        let b10 = UInt8.random(in: 0...0xFF)
        let b11 = UInt8.random(in: 0...0xFF)
        let b12 = UInt8.random(in: 0...0xFF)
        let b13 = UInt8.random(in: 0...0xFF)
        let b14 = UInt8.random(in: 0...0xFF)
        let b15 = UInt8.random(in: 0...0xFF)

        return UUID(
            uuid: (
                b0, b1, b2, b3, b4, b5, b6, b7,
                b8, b9, b10, b11, b12, b13, b14, b15
            )
        )
    }

    /// Extracts the creation timestamp embedded in a UUIDv7.
    ///
    /// UUIDv7 stores a 48-bit unix-millisecond timestamp in its first six bytes
    /// (big-endian). This property reconstructs the `Date` from those bytes,
    /// giving a stable, zero-cost alternative to storing creation times separately.
    ///
    /// Returns `nil` when called on a non-v7 UUID (version nibble ≠ 0x7).
    public var v7CreatedAt: Date? {
        let b = uuid
        // Check version nibble (high 4 bits of byte 6).
        guard (b.6 & 0xF0) == 0x70 else { return nil }
        let ms: UInt64 =
            UInt64(b.0) << 40 | UInt64(b.1) << 32 | UInt64(b.2) << 24 | UInt64(b.3) << 16 | UInt64(
                b.4
            ) << 8 | UInt64(b.5)
        return Date(timeIntervalSince1970: Double(ms) / 1_000)
    }
}
