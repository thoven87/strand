package import NIOCore
import NIOFoundationCompat

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - StrandCodec

/// A codec that serialises and deserialises user-supplied payload values for
/// storage in Postgres.
///
/// Every payload written to `strand.tasks.params`, `strand.workflow_state`,
/// activity results, signal payloads, update payloads, and child-workflow
/// inputs flows through the codec configured on the worker and client.
///
/// Implement this protocol to add encryption-at-rest, compression, or a
/// custom wire format. The default is ``JSONCodec``.
///
/// ## Example — AES-GCM encryption
/// ```swift
/// import CryptoKit
/// import NIOCore
///
/// struct AESCodec: StrandCodec {
///     let key: SymmetricKey
///
///     func encode<T: Encodable>(_ value: T) throws -> ByteBuffer {
///         let plaintext = try JSONCodec().encode(value)
///         let sealed = try AES.GCM.seal(Data(plaintext.readableBytesView), using: key)
///         return ByteBuffer(bytes: sealed.combined!)
///     }
///
///     func decode<T: Decodable>(_ type: T.Type, from buffer: ByteBuffer) throws -> T {
///         let box = try AES.GCM.SealedBox(combined: Data(buffer.readableBytesView))
///         let plaintext = try AES.GCM.open(box, using: key)
///         return try JSONCodec().decode(type, from: ByteBuffer(bytes: plaintext))
///     }
/// }
///
/// let worker = StrandWorker(
///     postgres: postgres,
///     options: WorkerOptions(queue: "default", codec: AESCodec(key: encryptionKey)),
///     ...
/// )
/// ```
public protocol StrandCodec: Sendable {
    /// Encodes `value` to a `ByteBuffer` for Postgres storage.
    ///
    /// The `Sendable` constraint is absent: the codec is invoked synchronously
    /// within an already-isolated context. `Encodable` is sufficient.
    func encode<T: Encodable>(_ value: T) throws -> ByteBuffer

    /// Decodes `T` from a `ByteBuffer` retrieved from Postgres.
    func decode<T: Decodable>(_ type: T.Type, from buffer: ByteBuffer) throws -> T
}

// MARK: - JSONCodec

/// The default codec: plain JSON via NIOFoundationCompat's zero-copy paths.
///
/// Uses `encodeAsByteBuffer` to write directly into a `ByteBuffer` (no
/// `Foundation.Data` intermediate) and `JSONDecoder.decode(from:ByteBuffer)`
/// for zero-copy decode.
public struct JSONCodec: StrandCodec {
    public init() {}

    // Shared instances: JSONEncoder/JSONDecoder are classes whose construction
    // allocates strategy tables. Re-using them is safe in Swift 6 — both types
    // are Sendable and stateless after init.
    //
    // Date strategy: .iso8601 produces human-readable strings
    // (e.g. "2026-09-18T00:00:00Z") instead of Foundation’s default
    // `timeIntervalSinceReferenceDate` double (e.g. 811382400.0 — seconds
    // since Jan 1, 2001, not Unix epoch, which is confusing in API responses
    // and DB inspection).
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func encode<T: Encodable>(_ value: T) throws -> ByteBuffer {
        do {
            return try Self.encoder.encodeAsByteBuffer(value, allocator: JSON.allocator)
        } catch {
            throw StrandError.serialization(underlying: error)
        }
    }

    public func decode<T: Decodable>(_ type: T.Type, from buffer: ByteBuffer) throws -> T {
        do {
            return try Self.decoder.decode(type, from: buffer)
        } catch {
            throw StrandError.serialization(underlying: error)
        }
    }
}

// MARK: - Void / non-Encodable dispatch (replaces protocol witness table)
//
// SE-0352 (Swift 5.7) opens existentials when calling a member function on
// `any P` (value) or a static method on `any P.Type` (metatype). These two
// fileprivate extensions bridge from the statically-unknown Output type to
// the codec's generic methods without any `@unchecked Sendable` wrappers:
// the `Sendable` constraint was removed from the codec's generic parameters,
// so plain `Encodable` / `Decodable` suffice here.

extension Encodable {
    fileprivate func _encode(using codec: any StrandCodec) throws -> ByteBuffer {
        try codec.encode(self)
    }
}

extension Decodable {
    fileprivate static func _decode(using codec: any StrandCodec, from buffer: ByteBuffer) throws -> Self {
        try codec.decode(Self.self, from: buffer)
    }
}

/// Encodes an activity or workflow `Output` through the codec, handling Void.
/// Returns `nil` for `Void` or non-`Encodable` outputs (stored as NULL in Postgres).
package func _encodeOutput<Output: Sendable>(_ output: Output, codec: any StrandCodec) throws -> ByteBuffer? {
    if output is Void { return nil }
    guard let encodable = output as? any Encodable else { return nil }
    return try encodable._encode(using: codec)  // SE-0352 opens value existential
}

/// Decodes an activity or workflow `Output` from a `ByteBuffer` through the codec.
/// Returns `()` cast to `Output` for `Void` without touching the buffer.
package func _decodeOutput<Output: Sendable>(
    _ outputType: Output.Type,
    from buffer: ByteBuffer,
    codec: any StrandCodec
) throws -> Output {
    if Output.self == Void.self { return () as! Output }
    guard let decodableType = outputType as? any Decodable.Type else {
        throw StrandError.serialization(underlying: _NonDecodableOutputError(type: outputType))
    }
    let decoded = try decodableType._decode(using: codec, from: buffer)  // SE-0352 opens metatype existential
    return decoded as! Output
}

private struct _NonDecodableOutputError: Error, CustomStringConvertible {
    let type: Any.Type
    var description: String { "Output type \(type) does not conform to Decodable; cannot decode from Postgres" }
}

// MARK: - _StrandCodecContext

/// Task-local codec propagated into `handleSignal` / `handleUpdate` calls so
/// that ``Workflow/decodeSignalPayload(_:from:)`` and macro-generated handlers
/// use the same codec as the rest of the activation — without changing the
/// ``Workflow`` protocol's signal/update method signatures.
///
/// Default: ``JSONCodec``. Overwritten by `applyAndPersistSignals` with a
/// synchronous `withValue` before each handler call.
package enum _StrandCodecContext {
    @TaskLocal package static var codec: any StrandCodec = JSONCodec()
}
