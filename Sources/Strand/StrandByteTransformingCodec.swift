public import NIOCore

// MARK: - StrandPayload

/// Tagged payload envelope written to Postgres by codecs that transform bytes
/// (encryption, compression, …).
///
/// The envelope is serialised as JSON alongside the transformed bytes:
///
/// ```json
/// {
///   "encoding": "binary/encrypted+aes-gcm",
///   "keyId": "key-2026-01",
///   "data": "<base64-ciphertext>"
/// }
/// ```
///
/// ``JSONCodec`` (the default) never produces a `StrandPayload` envelope — it
/// writes raw JSON directly.  Custom codecs write an envelope so the decode
/// side can identify the encoding and **skip payloads it does not own**:
///
/// ```
/// Postgres column:  { "encoding": "binary/encrypted+aes-gcm", "data": "..." }
///                       ↑
///               transformFromStorage reads this tag
///               • encoding matches  → decrypt and return JSON bytes
///               • encoding differs   → return nil (pass through unchanged)
///               • not an envelope    → return nil (plain JSON, pre-migration row)
/// ```
///
public struct StrandPayload: Codable, Sendable {
    /// Identifies the encoding, e.g. `"binary/encrypted+aes-gcm"` or
    /// `"binary/compressed+zstd"`.  Must be unique per codec implementation.
    public let encoding: String

    /// Optional key identifier — used for key-rotation.  Store the active key
    /// ID here so `transformFromStorage` knows which key to decrypt with.
    public let keyId: String?

    /// Base64-encoded transformed bytes.
    public let data: String

    public init(encoding: String, keyId: String? = nil, data: String) {
        self.encoding = encoding
        self.keyId = keyId
        self.data = data
    }
}

// MARK: - StrandByteTransformingCodec

/// Optional refinement of ``StrandCodec`` for codecs that apply a byte-level
/// transformation on top of serialisation — encryption, compression, signing, …
///
/// ``StrandCodec/encode(_:)`` converts a typed Swift value to bytes (serialisation).
/// ``StrandByteTransformingCodec`` adds a second pass that transforms those bytes
/// (or any already-serialised bytes) into the final storage wire format:
///
/// ```
/// Typed value  →  StrandCodec.encode  →  JSON bytes
///                                          ↓
///                              StrandByteTransformingCodec.transformForStorage
///                                          ↓
///                                    Encrypted bytes  (stored in Postgres)
/// ```
///
/// ## When to conform
///
/// Conform when your codec applies a byte-level transform **on top of** JSON
/// serialisation. Example: an AES codec serialises to JSON first, then
/// encrypts the JSON bytes before storage.
///
/// ``JSONCodec`` does **not** conform — its wire format is plain JSON and no
/// further transformation is needed.
///
/// ## Example — AES-GCM
///
/// ```swift
/// struct AESCodec: StrandCodec, StrandByteTransformingCodec {
///     let key: SymmetricKey
///     let keyId: String          // e.g. "key-2026-01" for key rotation
///
///     // StrandCodec: typed value → JSON → envelope → Postgres
///     func encode<T: Encodable>(_ value: T) throws -> ByteBuffer {
///         let json     = try JSONCodec().encode(value)
///         let envelope = try transformForStorage(json)   // wraps in StrandPayload
///         return try JSONCodec().encode(envelope)        // stored as JSON in Postgres
///     }
///     func decode<T: Decodable>(_ type: T.Type, from buffer: ByteBuffer) throws -> T {
///         // Try to parse as a StrandPayload envelope first.
///         // Fall back to plain JSON for pre-encryption rows (migration safe).
///         if let envelope = try? JSONCodec().decode(StrandPayload.self, from: buffer),
///            let json     = try transformFromStorage(envelope) {
///             return try JSONCodec().decode(type, from: json)
///         }
///         return try JSONCodec().decode(type, from: buffer)
///     }
///
///     // StrandByteTransformingCodec: raw bytes → tagged StrandPayload envelope
///     func transformForStorage(_ buffer: ByteBuffer) throws -> StrandPayload {
///         let sealed = try AES.GCM.seal(Data(buffer.readableBytesView), using: key)
///         return StrandPayload(
///             encoding: "binary/encrypted+aes-gcm",
///             keyId:    keyId,
///             data:     sealed.combined!.base64EncodedString()
///         )
///     }
///
///     // Return nil for envelopes this codec didn’t produce — lets decode
///     // fall through to plain JSON for pre-migration rows or different codecs.
///     func transformFromStorage(_ payload: StrandPayload) throws -> ByteBuffer? {
///         guard payload.encoding == "binary/encrypted+aes-gcm" else { return nil }
///         guard let combined = Data(base64Encoded: payload.data) else { return nil }
///         let box   = try AES.GCM.SealedBox(combined: combined)
///         let plain = try AES.GCM.open(box, using: key)
///         return ByteBuffer(bytes: plain)
///     }
/// }
/// ```
///
/// The HTTP codec proxy endpoints (`POST /api/:namespace/codec/encode` and
/// `/decode`) call these methods when they exist, so Loom encodes raw JSON
/// through the same transform before posting workflow inputs or signal payloads.
public protocol StrandByteTransformingCodec: StrandCodec {
    /// Transforms already-serialised bytes into a tagged ``StrandPayload`` envelope.
    ///
    /// The envelope’s `encoding` field is the key that lets `transformFromStorage`
    /// know whether a stored row belongs to this codec.  Set it to a unique,
    /// stable string (e.g. `"binary/encrypted+aes-gcm"`).
    func transformForStorage(_ buffer: ByteBuffer) throws -> StrandPayload

    /// Decodes a ``StrandPayload`` envelope produced by this codec.
    ///
    /// - Return the original bytes when `payload.encoding` matches this codec.
    /// - Return `nil` for any other encoding (or for plain-JSON pre-migration
    ///   rows that were never wrapped in an envelope) so the caller can fall
    ///   back gracefully.
    func transformFromStorage(_ payload: StrandPayload) throws -> ByteBuffer?
}
