import Hummingbird
import NIOCore
import NIOFoundationCompat
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Wire types

private struct CodecPayloadBody: Decodable {
    /// Base64-encoded bytes sent by Loom before posting a workflow input or signal payload.
    let data: String
}

struct CodecPayloadResponse: Encodable {
    /// Base64-encoded bytes returned after the codec has transformed them.
    let data: String
}
extension CodecPayloadResponse: ResponseCodable {}

// MARK: - CodecRoutes

/// Codec proxy endpoints — called by Loom before posting workflow inputs and
/// signal/update payloads so they are stored in the codec's wire format.
///
/// The server holds the active ``StrandCodec``; the browser does not need to
/// know which codec is configured or how to call it.
///
/// ## How encoding works
///
/// If the active codec conforms to ``StrandByteTransformingCodec``, the raw
/// bytes are passed through its `transformForStorage` method (e.g. AES
/// encryption).  Otherwise — including for the default ``JSONCodec`` — the
/// bytes are returned unchanged: ``JSONCodec`` serialises typed Swift values
/// to JSON but applies no additional byte-level transform, so raw JSON from
/// the UI is already the correct wire format.
///
/// ## Endpoints
///
/// ```
/// POST /api/:namespace/codec/encode
///   Body:     { "data": "<base64>" }   — raw bytes (e.g. UTF-8 JSON from Loom)
///   Response: { "data": "<base64>" }   — codec wire-format bytes
///
/// POST /api/:namespace/codec/decode
///   Body:     { "data": "<base64>" }   — codec wire-format bytes
///   Response: { "data": "<base64>" }   — raw bytes (e.g. UTF-8 JSON for display)
/// ```
struct CodecRoutes {
    let client: StrandClient

    func register(on router: some RouterMethods<StrandRequestContext>) {

        // POST /api/:namespace/codec/encode
        // Loom calls this before triggerWorkflow / sendSignal / sendUpdate.
        // For JSONCodec: pass-through (raw JSON is the wire format, no envelope).
        // For custom codecs: wraps the bytes in a StrandPayload envelope.
        router.post("codec/encode") { req, ctx -> CodecPayloadResponse in
            let body = try await req.decode(as: CodecPayloadBody.self, context: ctx)
            guard let rawData = Data(base64Encoded: body.data) else {
                throw HTTPError(.badRequest, message: "codec/encode: 'data' is not valid base64")
            }
            var raw = JSON.allocator.buffer(capacity: rawData.count)
            raw.writeContiguousBytes(rawData)

            let resultBytes: ByteBuffer
            if let transformer = self.client.options.codec as? any StrandByteTransformingCodec {
                // Produce a StrandPayload envelope, then serialise it to JSON for storage.
                let envelope = try transformer.transformForStorage(raw)
                resultBytes = try JSONCodec().encode(envelope)
            } else {
                resultBytes = raw  // JSONCodec: no envelope needed
            }
            return CodecPayloadResponse(data: Data(resultBytes.readableBytesView).base64EncodedString())
        }

        // POST /api/:namespace/codec/decode
        // Loom calls this to display stored payloads as human-readable JSON.
        // For JSONCodec: pass-through.
        // For custom codecs: reads the StrandPayload envelope and reverses the transform.
        // Falls back to pass-through for plain-JSON rows (pre-migration or JSONCodec rows).
        router.post("codec/decode") { req, ctx -> CodecPayloadResponse in
            let body = try await req.decode(as: CodecPayloadBody.self, context: ctx)
            guard let rawData = Data(base64Encoded: body.data) else {
                throw HTTPError(.badRequest, message: "codec/decode: 'data' is not valid base64")
            }
            var raw = JSON.allocator.buffer(capacity: rawData.count)
            raw.writeContiguousBytes(rawData)

            let resultBytes: ByteBuffer
            if let transformer = self.client.options.codec as? any StrandByteTransformingCodec,
                let envelope = try? JSONCodec().decode(StrandPayload.self, from: raw),
                let decoded = try transformer.transformFromStorage(envelope)
            {
                resultBytes = decoded
            } else {
                resultBytes = raw  // not an envelope, or encoding not recognised
            }
            return CodecPayloadResponse(data: Data(resultBytes.readableBytesView).base64EncodedString())
        }
    }
}
