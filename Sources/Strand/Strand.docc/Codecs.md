# Codecs

Control how Strand serialises and stores every payload in Postgres.

## Overview

Every byte written to `strand.tasks.params`, `strand.workflow_state`,
`strand.workflow_signals.payload`, and activity results flows through the
active **codec**. The codec is responsible for turning a typed Swift value
into the bytes stored in Postgres, and for reversing that when the worker
claims the task.

```
Workflow input                   Activity output
     │                                │
     ▼                                ▼
StrandCodec.encode<T>       StrandCodec.encode<T>
     │                                │
     ▼                                ▼
  Postgres                        Postgres
     │                                │
     ▼                                ▼
StrandCodec.decode<T>       StrandCodec.decode<T>
     │                                │
     ▼                                ▼
Worker receives typed input    Workflow receives typed output
```

The default codec is ``JSONCodec``, which serialises values to JSON using
ISO 8601 dates (`"2026-09-25T00:00:00Z"`, not Unix epoch doubles).

---

## Configuring the codec

Pass a codec to ``StrandOptions`` (for ``StrandClient``) and ``WorkerOptions``
(for ``StrandWorker`` / ``StrandService``):

```swift
let aes = AESCodec(key: encryptionKey)

// Client — encodes inputs when starting workflows / sending signals
let client = StrandClient(
    postgres: postgres,
    options: StrandOptions(codec: aes)
)

// Worker — decodes inputs when claiming tasks, encodes outputs
let worker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(queue: "default", codec: aes),
    ...
)
```

> Important: The client and all workers that share a queue **must use the
> same codec**. A worker with ``JSONCodec`` that claims a task whose params
> were encrypted by an AES client will fail to decode the input.

---

## Implementing a custom codec

### Simple codecs — `StrandCodec`

For codecs that only change the serialisation format (e.g. MessagePack
instead of JSON), conform to ``StrandCodec``:

```swift
struct MsgPackCodec: StrandCodec {
    func encode<T: Encodable>(_ value: T) throws -> ByteBuffer {
        // serialise value to MessagePack bytes
    }
    func decode<T: Decodable>(_ type: T.Type, from buffer: ByteBuffer) throws -> T {
        // deserialise MessagePack bytes to T
    }
}
```

### Byte-level transforms — `StrandByteTransformingCodec`

For codecs that apply an additional transformation on top of serialisation
(encryption, compression, signing), conform to both ``StrandCodec`` **and**
``StrandByteTransformingCodec``:

```swift
struct AESCodec: StrandCodec, StrandByteTransformingCodec {
    let key: SymmetricKey
    let keyId: String   // e.g. "key-2026-01"

    // Layer 1 (StrandCodec): typed value → JSON → encrypt → Postgres
    func encode<T: Encodable>(_ value: T) throws -> ByteBuffer {
        let json     = try JSONCodec().encode(value)
        let envelope = try transformForStorage(json)
        return try JSONCodec().encode(envelope)   // envelope is stored as JSON
    }

    func decode<T: Decodable>(_ type: T.Type, from buffer: ByteBuffer) throws -> T {
        // Try to unwrap the StrandPayload envelope; fall back to plain JSON
        // for rows that were written before encryption was enabled.
        if let envelope = try? JSONCodec().decode(StrandPayload.self, from: buffer),
           let json     = try transformFromStorage(envelope) {
            return try JSONCodec().decode(type, from: json)
        }
        return try JSONCodec().decode(type, from: buffer)
    }

    // Layer 2 (StrandByteTransformingCodec): raw bytes → StrandPayload envelope
    func transformForStorage(_ buffer: ByteBuffer) throws -> StrandPayload {
        let sealed = try AES.GCM.seal(Data(buffer.readableBytesView), using: key)
        return StrandPayload(
            encoding: "binary/encrypted+aes-gcm",
            keyId:    keyId,
            data:     sealed.combined!.base64EncodedString()
        )
    }

    func transformFromStorage(_ payload: StrandPayload) throws -> ByteBuffer? {
        // Return nil for encodings this codec doesn't own — allows graceful
        // pass-through during migrations or when multiple codecs coexist.
        guard payload.encoding == "binary/encrypted+aes-gcm" else { return nil }
        guard let combined = Data(base64Encoded: payload.data) else { return nil }
        let box   = try AES.GCM.SealedBox(combined: combined)
        let plain = try AES.GCM.open(box, using: key)
        return ByteBuffer(bytes: plain)
    }
}
```

---

## The `StrandPayload` envelope

When ``StrandByteTransformingCodec`` is in use, the transformed bytes are
not written raw to Postgres. Instead they are wrapped in a ``StrandPayload``
JSON envelope:

```json
{
  "encoding": "binary/encrypted+aes-gcm",
  "keyId":    "key-2026-01",
  "data":     "<base64-encoded ciphertext>"
}
```

The `encoding` field is the key to migration safety. When
`transformFromStorage` receives a payload it checks this tag:

| `encoding` value | Action |
|---|---|
| Matches this codec | Decrypt and return bytes |
| Different codec's value | Return `nil` — pass through |
| Field absent (plain JSON row) | Parse fails → `nil` — pass through |

This means old plain-JSON rows written before encryption was enabled are
still readable by an AES codec — the `decode<T>` implementation falls back
to plain ``JSONCodec`` decoding for any row where `transformFromStorage`
returns `nil`.

### Key rotation

Store the active key identifier in `keyId`. When rotating keys:

1. Generate a new key and update `keyId` in the codec (e.g. `"key-2026-07"`).
2. New rows are written with the new key ID.
3. Old rows carry the old key ID in their envelope.
4. `transformFromStorage` reads `payload.keyId` and selects the correct key
   from a key store rather than a single hard-coded value.

---

## Loom (the dashboard UI)

When Strand's built-in dashboard is in use, Loom calls the server-side
codec proxy before posting workflow inputs or signal payloads:

```
POST /api/:namespace/codec/encode  — raw JSON bytes → codec wire-format bytes
POST /api/:namespace/codec/decode  — codec wire-format bytes → raw JSON bytes
```

For ``JSONCodec`` these are pass-through (no transformation). For a custom
codec that conforms to ``StrandByteTransformingCodec``, encode produces the
``StrandPayload`` envelope and decode reverses it. This means payloads
submitted through the Loom UI are stored in the same wire format as payloads
submitted programmatically via the Swift client.

---

## Topics

### Protocols
- ``StrandCodec``
- ``StrandByteTransformingCodec``

### Types
- ``JSONCodec``
- ``StrandPayload``
