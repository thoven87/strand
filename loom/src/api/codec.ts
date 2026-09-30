import { api } from "./client";

/**
 * Encode raw bytes through the server's configured codec before storing.
 *
 * Loom always calls this before sending workflow inputs, signal payloads,
 * or update payloads to the API so the correct wire format is stored in
 * Postgres regardless of which StrandCodec is active on the server.
 *
 * For JSONCodec (the default) the endpoint is a pass-through — the base64
 * round-trip is the only overhead, and the stored bytes are identical to what
 * Loom would have sent without the call.
 *
 * @param namespace  Active namespace (e.g. "lhcsa").
 * @param rawString  UTF-8 string to encode (typically a JSON payload).
 * @returns          The encoded string, ready to send to the API.
 */
export const codecEncode = async (
    namespace: string,
    rawString: string,
): Promise<string> => {
    const b64 = btoa(unescape(encodeURIComponent(rawString)));
    const result = await api
        .post<{ data: string }>(`/api/${namespace}/codec/encode`, { data: b64 })
        .then((r) => r.data);
    return decodeURIComponent(escape(atob(result.data)));
};

/**
 * Decode stored bytes through the server's configured codec back to a
 * human-readable string (typically JSON).
 *
 * Call this when displaying stored params or payload bytes in the UI.
 *
 * @param namespace    Active namespace.
 * @param storedString The stored byte string to decode.
 * @returns            The decoded string (e.g. plain JSON).
 */
export const codecDecode = async (
    namespace: string,
    storedString: string,
): Promise<string> => {
    const b64 = btoa(unescape(encodeURIComponent(storedString)));
    const result = await api
        .post<{ data: string }>(`/api/${namespace}/codec/decode`, { data: b64 })
        .then((r) => r.data);
    return decodeURIComponent(escape(atob(result.data)));
};
