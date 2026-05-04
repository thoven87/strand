public import Logging

/// Configuration for a ``StrandServer`` service instance.
public struct ServerConfiguration: Sendable {
    /// Interface to bind to. Defaults to `"0.0.0.0"` (all interfaces).
    public var host: String
    /// Port to listen on. Defaults to `8080`.
    public var port: Int
    /// Logger used by the HTTP server layer.
    /// Strand never calls `LoggingSystem.bootstrap` — the caller owns the backend.
    public var logger: Logger

    public init(
        host: String = "0.0.0.0",
        port: Int = 8080,
        logger: Logger = Logger(label: "dev.strand.server")
    ) {
        self.host = host
        self.port = port
        self.logger = logger
    }
}
