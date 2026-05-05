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

    /// Encode `value` into a new `ByteBuffer`.
    /// - Throws: `StrandError.serialization` if `JSONEncoder` fails.
    static func encode<T: Encodable & Sendable>(_ value: T) throws(StrandError) -> ByteBuffer {
        do {
            return try JSONEncoder().encodeAsByteBuffer(value, allocator: ByteBufferAllocator())
        } catch {
            throw StrandError.serialization(underlying: error)
        }
    }

    /// Decode `type` from `buffer` without copying to `Data` first.
    /// - Throws: `StrandError.serialization` if `JSONDecoder` fails.
    static func decode<T: Decodable>(
        _ type: T.Type,
        from buffer: ByteBuffer
    ) throws(StrandError)
        -> T
    {
        do {
            return try JSONDecoder().decode(type, from: buffer)
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
