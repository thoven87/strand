// Import full Foundation (not FoundationEssentials) so NSData.compressed is
// available.  This API ships in Foundation on macOS 10.15+ and in
// swift-corelibs-foundation on Linux since Swift 5.7.
import Foundation
import NIOCore

// MARK: - Gzip + base64 encode/decode
//
// Large pg_notify payloads (DDSketch JSON) are gzip-compressed and
// base64-encoded to stay within Postgres’s 8 000-byte hard limit:
//
//   encode: json → gzip → base64 string
//   decode: starts with "{" → plain JSON; otherwise base64 → gzip → json

/// Gzip-compress `buf` and return a base64-encoded string.
///
/// DDSketch JSON compresses 5–10× under gzip, keeping broadcast payloads
/// well within Postgres’s 8 000-byte `pg_notify` limit.
///
/// Returns `nil` if Foundation's zlib compression is unavailable on the
/// current platform, in which case the caller falls back to plain JSON.
func _zlibDeflate(_ buf: ByteBuffer) -> String? {
    guard let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes) else {
        return nil
    }
    let data = Data(bytes)
    guard let compressed = try? (data as NSData).compressed(using: .zlib) as Data else {
        return nil
    }
    return compressed.base64EncodedString()
}

/// Decode a payload that is either:
/// - Plain JSON (starts with `{`) — e.g. from a SQL `pg_notify()` call.
/// - Base64-encoded gzip-compressed JSON — e.g. from `_zlibDeflate()` above.
///
/// Returns `nil` if decoding or decompression fails.
package func _decodeMetricsBroadcast(_ text: String) -> StrandMetricsBroadcast? {
    if text.hasPrefix("{") {
        // Plain JSON fast path.
        return try? JSON.decode(StrandMetricsBroadcast.self, from: text)
    }
    // base64 + gzip path.
    guard
        let compressed = Data(base64Encoded: text),
        let decompressed = try? (compressed as NSData).decompressed(using: .zlib) as Data,
        let json = String(data: decompressed, encoding: .utf8)
    else { return nil }
    return try? JSON.decode(StrandMetricsBroadcast.self, from: json)
}
