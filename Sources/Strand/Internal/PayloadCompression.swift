import CompressNIO
import ExtrasBase64
import NIOCore

// MARK: - Zlib + base64 encode/decode
//
// Large pg_notify payloads (DDSketch JSON) are compressed and base64-encoded
// to stay within Postgres's 8 000-byte hard limit:
//
//   encode: ByteBuffer → zlib compress → base64 string
//   decode: starts with "{" → plain JSON; otherwise base64 → zlib decompress → JSON

/// Zlib-compress `buf` and return a base64-encoded string.
///
/// DDSketch JSON compresses 5–10×, keeping broadcast payloads well within
/// Postgres's 8 000-byte `pg_notify` limit.
///
/// Returns `nil` if compression fails, in which case the caller falls back
/// to sending the plain JSON string.
func _zlibDeflate(_ buf: ByteBuffer) -> String? {
    do {
        var input = buf
        var compressed = try input.compress(with: .zlib, allocator: JSON.allocator)
        guard let bytes = compressed.readBytes(length: compressed.readableBytes) else {
            return nil
        }
        return Base64.encodeToString(bytes: bytes)
    } catch {
        return nil
    }
}

/// Decode a payload that is either:
/// - Plain JSON (starts with `{`) — e.g. from a SQL `pg_notify()` call.
/// - Base64 + zlib-compressed JSON — e.g. from `_zlibDeflate()` above.
///
/// Returns `nil` if decoding or decompression fails.
package func _decodeMetricsBroadcast(_ text: String) -> StrandMetricsBroadcast? {
    if text.hasPrefix("{") {
        // Plain JSON fast path — no decompression needed.
        return try? JSON.decode(StrandMetricsBroadcast.self, from: text)
    }
    // base64 → zlib decompress → JSON
    do {
        let compressedBytes = try Base64.decode(string: text)
        var buf = JSON.allocator.buffer(capacity: compressedBytes.count)
        buf.writeBytes(compressedBytes)
        let decompressed = try buf.decompress(with: .zlib, allocator: JSON.allocator)
        return try JSON.decode(StrandMetricsBroadcast.self, from: decompressed)
    } catch {
        return nil
    }
}
