public import Hummingbird
import Logging
public import PostgresNIO
public import ServiceLifecycle
public import Strand

/// A self-contained Hummingbird application that exposes the Strand dashboard
/// REST API and manages the `PostgresClient` lifecycle internally.
///
/// ## Standalone usage
///
/// ```swift
/// let postgres = PostgresClient(configuration: ..., backgroundLogger: logger)
/// let client   = StrandClient(postgres: postgres, queue: "default")
/// let server   = StrandServer(client: client, postgres: postgres)
/// try await server.run()   // blocks; handles SIGTERM/SIGINT via runService()
/// ```
///
/// ## Embedded in a larger Application (e.g. DevServer)
///
/// Use ``buildRouter(client:postgres:)`` to get a configured router and mount
/// it on your own `Application`, then call `addServices` and
/// `beforeServerStarts` yourself:
///
/// ```swift
/// let router = StrandServer.buildRouter(client: client, postgres: postgres)
/// var app    = Application(router: router, configuration: ...)
/// app.addServices(postgres, worker)
/// app.beforeServerStarts { try await client.verifySchema() }
/// try await app.runService()
/// ```
public struct StrandServer: Service {
    private let client: StrandClient
    private let postgres: PostgresClient
    public let configuration: ServerConfiguration

    public init(
        client: StrandClient,
        postgres: PostgresClient,
        configuration: ServerConfiguration = .init()
    ) {
        self.client = client
        self.postgres = postgres
        self.configuration = configuration
    }

    // MARK: - Service

    public func run() async throws {
        let metricsCache = MetricsCache()
        // StrandServer.run() is the *standalone* entry point (no shared notifier).
        // MetricsBroadcastListener opens its own LISTEN connection here, which is
        // correct: standalone server = no worker = one connection total.
        //
        // When embedding StrandServer in a larger application alongside a worker,
        // create ONE StrandNotifier at the application level, share it with both
        // StrandWorker and MetricsBroadcastListener, and pass the MetricsCache to
        // buildRouter.  The notifier then holds the single connection for all
        // LISTEN/NOTIFY across the entire process.
        let metricsListener = MetricsBroadcastListener(
            postgres: postgres,
            cache: metricsCache,
            logger: configuration.logger
        )
        var app = Application(
            router: Self.buildRouter(client: client, postgres: postgres, metricsCache: metricsCache),
            configuration: .init(
                address: .hostname(configuration.host, port: configuration.port)
            ),
            logger: configuration.logger
        )
        app.addServices(postgres, metricsListener)
        // Verify the Strand schema before the HTTP server begins accepting
        // requests — prevents 500s during a cold start against a blank DB.
        //let client = self.client
        app.beforeServerStarts {
            try await client.verifySchema()
        }
        try await app.runService()
    }

    // MARK: - Public router builder

    /// Returns a ``Router`` with all Strand dashboard routes registered.
    ///
    /// Use this when you want to embed the Strand API inside your own
    /// Hummingbird `Application` (e.g. alongside workers in a DevServer).
    public static func buildRouter(
        client: StrandClient,
        postgres: PostgresClient,
        metricsCache: MetricsCache? = nil
    ) -> Router<StrandRequestContext> {
        let router = Router(context: StrandRequestContext.self)

        // ── Non-namespaced ───────────────────────────────────────────────────
        // GET /health, GET /version
        HealthRoutes(client: client).register(on: router)
        // GET /api/namespaces
        NamespaceRoutes(postgres: postgres, logger: client.logger).register(on: router)

        // ── Namespaced: /api/:namespace/... ──────────────────────────────────
        // NamespaceMiddleware resolves ctx.namespaceID from the :namespace
        // path segment (priority 1), X-Strand-Namespace header (priority 2),
        // or the server's configured default namespace (priority 3).
        let nsGroup =
            router
            .group("api/:namespace")
            .addMiddleware {
                NamespaceMiddleware(defaultNamespace: client.namespaceID)
            }

        QueueRoutes(client: client, postgres: postgres).register(on: nsGroup)
        TaskRoutes(client: client, postgres: postgres).register(on: nsGroup)
        RunRoutes(postgres: postgres, logger: client.logger).register(on: nsGroup)
        EventRoutes(client: client, postgres: postgres).register(on: nsGroup)
        WorkflowRoutes(client: client).register(on: nsGroup)
        ScheduleRoutes(client: client).register(on: nsGroup)
        WorkerRoutes(postgres: postgres, logger: client.logger).register(on: nsGroup)
        MetricsRoutes(
            postgres: postgres,
            defaultNamespaceID: client.namespaceID,
            logger: client.logger,
            cache: metricsCache
        ).register(on: nsGroup)

        return router
    }
}
