public import Hummingbird

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// Custom Hummingbird request context for the Strand dashboard API.
///
/// Owns the ISO-8601 `JSONEncoder`/`JSONDecoder` so every route handler gets
/// consistent date formatting automatically — no global encoder singletons needed.
///
/// Route handlers that return a `ResponseCodable` type use `responseEncoder`
/// automatically. Body parsing via `req.decode(as:context:)` uses `requestDecoder`.
public struct StrandRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    /// Resolved by ``NamespaceMiddleware`` from the `:namespace` path parameter
    /// or the `X-Strand-Namespace` request header. Falls back to `"default"`.
    public var namespaceID: String = "default"

    public init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
    }

    public var requestDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public var responseEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
