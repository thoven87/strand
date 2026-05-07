import NIOCore
import NIOFoundationCompat

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Namespace for JSON helpers that encode and decode directly to/from
/// `ByteBuffer`, avoiding intermediate `Data` allocations.
///
/// `NIOFoundationCompat` provides the `encodeAsByteBuffer` and
/// `decode(_:from:ByteBuffer)` overloads used here.
enum JSON {

    // MARK: - Shared instances
    //
    // ByteBufferAllocator stores four C function pointers and NIO recommends reuse.
    // JSONEncoder / JSONDecoder are classes; construction allocates and initialises
    // strategy tables. Both are `Sendable` in Swift 6 and stateless after init
    // (we never mutate date/key strategies), so sharing across concurrent tasks is safe.
    private static let allocator = ByteBufferAllocator()
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Encode `value` into a new `ByteBuffer`.
    ///
    /// Implementation note: `encodeAsByteBuffer` encodes to `Data` first and then copies
    /// the bytes into the returned `ByteBuffer` (two allocations). Foundation's
    /// `JSONEncoder` has no direct ByteBuffer output path, so this is the best
    /// available option without a third-party JSON library.
    ///
    /// - Throws: `StrandError.serialization` if encoding fails.
    static func encode<T: Encodable & Sendable>(_ value: T) throws(StrandError) -> ByteBuffer {
        do {
            return try encoder.encodeAsByteBuffer(value, allocator: allocator)
        } catch {
            throw StrandError.serialization(underlying: error)
        }
    }

    /// Decode `type` from `buffer`.
    ///
    /// NIO's `JSONDecoder.decode(_:from:ByteBuffer)` uses `byteTransferStrategy: .noCopy`
    /// internally, so no Data copy occurs — the decoder reads directly from the
    /// ByteBuffer's backing storage.
    ///
    /// - Throws: `StrandError.serialization` if decoding fails.
    static func decode<T: Decodable>(
        _ type: T.Type,
        from buffer: ByteBuffer
    ) throws(StrandError) -> T {
        do {
            return try decoder.decode(type, from: buffer)
        } catch {
            throw StrandError.serialization(underlying: error)
        }
    }

    /// Decode `type` from a UTF-8 JSON string.
    ///
    /// **Prefer the `ByteBuffer` overload for all BYTEA Postgres columns** — it is
    /// zero-copy (NIOFoundationCompat uses `byteTransferStrategy: .noCopy` internally).
    /// Types stored as BYTEA should conform to `PostgresCodable` and be decoded
    /// directly via `col.next()!.decode(T?.self, context: .default)`.
    ///
    /// This overload exists solely for `TaskResultSnapshot.resultJSON: String?`, a
    /// public field that surfaces the raw result JSON as text so callers can inspect or
    /// forward it without decoding. Changing that field to `ByteBuffer?` would be a
    /// breaking API change, so the string path is preserved here.
    ///
    /// One `Data(string.utf8)` allocation is unavoidable: `JSONDecoder` has no
    /// `decode(from: String)` entry point. `string.utf8` always produces valid UTF-8
    /// (unlike the failable `string.data(using: .utf8)` form), so no optional is needed.
    ///
    /// - Throws: `StrandError.serialization` if decoding fails.
    static func decode<T: Decodable>(_ type: T.Type, from string: String) throws(StrandError) -> T {
        do {
            return try decoder.decode(type, from: Data(string.utf8))
        } catch {
            throw StrandError.serialization(underlying: error)
        }
    }

    /// Decode `type` from an optional buffer. Returns `nil` for `nil` or
    /// empty buffers (representing SQL `NULL` / empty JSON columns).
    /// - Throws: `StrandError.serialization` if `JSONDecoder` fails.
    static func decodeOptional<T: Decodable>(
        _ type: T.Type,
        from buffer: ByteBuffer?
    ) throws(StrandError) -> T? {
        guard let buffer, buffer.readableBytes > 0 else { return nil }
        return try decode(type, from: buffer)
    }
}
