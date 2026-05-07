import Hummingbird
import Logging
import OTel
import PostgresNIO
import ServiceLifecycle
import Strand
import StrandServer

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Types

struct OrderInput: Codable, Sendable {
    let orderId: String
    let amount: Double
    let items: [String]
}

struct OrderResult: Codable, Sendable {
    let orderId: String
    let status: String
    let trackingNumber: String
}

struct ReportInput: Codable, Sendable {
    let reportId: String
    let dataset: String
    let rowCount: Int
}

struct ReportResult: Codable, Sendable {
    let reportId: String
    let rowsProcessed: Int
    let path: String
}

struct GreetInput: Codable, Sendable {
    let name: String
}

struct GreetResult: Codable, Sendable {
    let message: String
}

// MARK: - Workflows

/// Multi-step order pipeline — shows checkpoints in the run timeline.
struct ProcessOrderWorkflow: Workflow {
    typealias Input = OrderInput
    typealias Output = OrderResult

    mutating func run(
        context: WorkflowContext<Self>,
        input: OrderInput
    ) async throws -> OrderResult {
        // Values derived purely from input — deterministic, no checkpoint needed.
        let paymentId = "pay_\(input.orderId.prefix(8).lowercased())"
        let tracking = "TRK-\(paymentId.suffix(6).uppercased())"
        return OrderResult(
            orderId: input.orderId,
            status: "completed",
            trackingNumber: tracking
        )
    }
}

/// Sleeps before processing — lets you see SLEEPING state in the UI.
struct GenerateReportWorkflow: Workflow {
    typealias Input = ReportInput
    typealias Output = ReportResult

    mutating func run(
        context: WorkflowContext<Self>,
        input: ReportInput
    ) async throws -> ReportResult {
        try await context.sleep(for: .seconds(8))
        let processed = input.rowCount
        return ReportResult(
            reportId: input.reportId,
            rowsProcessed: processed,
            path: "/data/reports/\(input.dataset)/\(input.reportId).csv"
        )
    }
}

/// Fails on attempts 1–2, succeeds on attempt 3 — shows FAILED + retry flow.
struct FlakyTaskWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    mutating func run(
        context: WorkflowContext<Self>,
        input: String
    ) async throws -> String {
        struct TransientFailure: LocatableError, CustomStringConvertible {
            let attempt: Int
            let sourceFileID: String
            let sourceLine: Int
            init(attempt: Int, fileID: String = #fileID, line: Int = #line) {
                self.attempt = attempt
                self.sourceFileID = fileID
                self.sourceLine = line
            }
            var description: String { "Transient failure on attempt \(attempt) — will retry" }
        }
        guard context.attempt >= 3 else {
            throw TransientFailure(attempt: context.attempt)
        }
        return "'\(input)' succeeded after \(context.attempt) attempt(s)"
    }
}

/// Instant greeting — the simplest possible workflow.
struct GreetUserWorkflow: Workflow {
    typealias Input = GreetInput
    typealias Output = GreetResult

    mutating func run(
        context: WorkflowContext<Self>,
        input: GreetInput
    ) async throws -> GreetResult {
        GreetResult(message: "Hello, \(input.name)! Powered by Strand.")
    }
}

// MARK: - Postgres factory

private func makePostgres(logger: Logger) -> PostgresClient {
    let env = ProcessInfo.processInfo.environment
    let host = env["POSTGRES_HOST"] ?? "localhost"
    let port = Int(env["POSTGRES_PORT"] ?? "5499") ?? 5499
    let user = env["POSTGRES_USER"] ?? "strand"
    let pass = env["POSTGRES_PASSWORD"] ?? "strand"
    let db = env["POSTGRES_DB"] ?? "strand_dev"

    var config = PostgresClient.Configuration(
        host: host,
        port: port,
        username: user,
        password: pass,
        database: db,
        tls: .disable
    )
    // Pool sizing: Σ(activityConcurrency) + Σ(workflowConcurrency)
    //            + N workers × 3 (listenLoop + poll + lease)
    //            + headroom for HTTP handlers
    // ordersWorker (16+8) + reportsWorker (8+4) + 2×3 + 8 HTTP = 50
    config.options.maximumConnections = 50
    return PostgresClient(configuration: config, backgroundLogger: logger)
}

// MARK: - Seeder

private func runSeeder(
    orders: StrandClient,
    reports: StrandClient,
    logger: Logger
) async {
    // postgres.run() is now managed by Application; give it a moment.
    try? await Task.sleep(for: .milliseconds(500))
    await seedBatch(orders: orders, reports: reports, logger: logger)

    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        guard !Task.isCancelled else { break }
        await seedOne(orders: orders, logger: logger)
    }
}

private func seedBatch(
    orders: StrandClient,
    reports: StrandClient,
    logger: Logger
) async {
    let initialOrders: [(String, Double, [String])] = [
        ("ORD-1001", 49.99, ["widget-a", "widget-b"]),
        ("ORD-1002", 129.00, ["gadget-x"]),
        ("ORD-1003", 19.95, ["sticker-pack", "mug"]),
        ("ORD-1004", 299.00, ["pro-kit"]),
    ]
    for (id, amount, items) in initialOrders {
        do {
            _ = try await orders.startWorkflow(
                ProcessOrderWorkflow.self,
                input: OrderInput(orderId: id, amount: amount, items: items)
            )
            logger.info("[seeder] order \(id) enqueued")
        } catch {
            logger.warning("[seeder] order \(id): \(error)")
        }
    }

    let initialReports: [(String, String, Int)] = [
        ("RPT-A1", "sales-q3", 8_432),
        ("RPT-B2", "users-monthly", 2_100),
    ]
    for (id, dataset, rows) in initialReports {
        do {
            _ = try await reports.startWorkflow(
                GenerateReportWorkflow.self,
                input: ReportInput(reportId: id, dataset: dataset, rowCount: rows)
            )
            logger.info("[seeder] report \(id) enqueued")
        } catch {
            logger.warning("[seeder] report \(id): \(error)")
        }
    }

    do {
        _ = try await orders.startWorkflow(
            FlakyTaskWorkflow.self,
            options: WorkflowOptions(maxAttempts: 3),
            input: "connection-probe"
        )
        _ = try await orders.startWorkflow(
            GreetUserWorkflow.self,
            input: GreetInput(name: "Developer")
        )
        logger.info("[seeder] flaky-task + greet-user enqueued")
    } catch {
        logger.warning("[seeder] misc tasks: \(error)")
    }
}

private func seedOne(orders: StrandClient, logger: Logger) async {
    let id = "ORD-\(Int.random(in: 2000...9999))"
    let catalog = ["widget", "gadget", "module", "adapter", "kit"]
    let items = ["\(catalog.randomElement()!)-\(Int.random(in: 1...9))"]
    do {
        _ = try await orders.startWorkflow(
            ProcessOrderWorkflow.self,
            input: OrderInput(orderId: id, amount: Double.random(in: 9.99...299.99), items: items)
        )
        logger.info("[seeder] periodic order \(id)")
    } catch {
        logger.warning("[seeder] periodic order: \(error)")
    }
}

// MARK: - Entry point

@main struct DevServer {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment

        // Bootstrap OTel — replaces LoggingSystem, MetricsSystem, and
        // InstrumentationSystem. Exports traces, metrics, and logs to Jaeger
        // via OTLP/gRPC on the default port (4317) — no auth required.
        //
        // Override the endpoint for other collectors:
        //   OTEL_EXPORTER_OTLP_ENDPOINT=https://api.honeycomb.io:443 \
        //   OTEL_EXPORTER_OTLP_AUTH=<base64-api-key> \
        //   swift run DevServer
        let otlpEndpoint = env["OTEL_EXPORTER_OTLP_ENDPOINT"] ?? "http://localhost:4317"
        let otlpHeaders: [(String, String)] =
            env["OTEL_EXPORTER_OTLP_AUTH"].map {
                [("Authorization", "Basic \($0)")]
            } ?? []

        var otelConfig = OTel.Configuration.default
        otelConfig.serviceName = env["OTEL_SERVICE_NAME"] ?? "strand-devserver"
        otelConfig.diagnosticLogLevel = .warning
        // Flush frequently so spans appear quickly during local dev.
        // Jaeger only implements the traces gRPC service — disable logs and
        // metrics to avoid "unknown service" errors on every flush cycle.
        // Set OTEL_ENABLE_LOGS=true or OTEL_ENABLE_METRICS=true to re-enable
        // when pointing at a collector that supports all three signals (e.g. SigNoz).
        let enableLogs = env["OTEL_ENABLE_LOGS"] == "true"
        let enableMetrics = env["OTEL_ENABLE_METRICS"] == "true"
        otelConfig.logs.enabled = enableLogs
        otelConfig.metrics.enabled = enableMetrics
        otelConfig.traces.batchSpanProcessor.scheduleDelay = .seconds(3)
        otelConfig.traces.otlpExporter.protocol = .grpc
        otelConfig.traces.otlpExporter.endpoint = otlpEndpoint
        otelConfig.traces.otlpExporter.headers = otlpHeaders
        if enableLogs {
            otelConfig.logs.batchLogRecordProcessor.scheduleDelay = .seconds(3)
            otelConfig.logs.otlpExporter.protocol = .grpc
            otelConfig.logs.otlpExporter.endpoint = otlpEndpoint
            otelConfig.logs.otlpExporter.headers = otlpHeaders
        }
        if enableMetrics {
            otelConfig.metrics.exportInterval = .seconds(10)
            otelConfig.metrics.otlpExporter.protocol = .grpc
            otelConfig.metrics.otlpExporter.endpoint = otlpEndpoint
            otelConfig.metrics.otlpExporter.headers = otlpHeaders
        }
        let observability = try OTel.bootstrap(configuration: otelConfig)

        let logger = Logger(label: "strand.devserver")

        let postgres = makePostgres(logger: logger)

        let ordersClient = StrandClient(
            postgres: postgres,
            queue: "orders",
            options: StrandOptions(logger: logger)
        )
        let reportsClient = StrandClient(
            postgres: postgres,
            queue: "reports",
            options: StrandOptions(logger: logger)
        )

        let ordersWorker = StrandWorker(
            postgres: postgres,
            options: WorkerOptions(
                queue: "orders",
                workflowConcurrency: 8,
                activityConcurrency: 16,
                // pollInterval is a fallback for LISTEN/NOTIFY misses (timer fires,
                // brief reconnect window). 5 s is plenty — NOTIFY handles the fast path.
                pollInterval: .seconds(5),
                claimTimeout: .seconds(60),
                leaseExpiryInterval: .seconds(5),
                // Only 2 workers on this server — no thundering herd, no jitter needed.
                notifyJitter: .zero
            ),
            workflows: [
                ProcessOrderWorkflow.self,
                GreetUserWorkflow.self,
                FlakyTaskWorkflow.self,
            ],
            logger: logger
        )

        let reportsWorker = StrandWorker(
            postgres: postgres,
            options: WorkerOptions(
                queue: "reports",
                workflowConcurrency: 4,
                activityConcurrency: 8,
                pollInterval: .seconds(5),
                claimTimeout: .seconds(120),
                leaseExpiryInterval: .seconds(5),
                notifyJitter: .zero
            ),
            workflows: [GenerateReportWorkflow.self],
            logger: logger
        )

        let router = StrandServer.buildRouter(client: ordersClient, postgres: postgres)

        var app = Application(
            router: router,
            configuration: .init(address: .hostname("0.0.0.0", port: 8080)),
            logger: logger
        )

        // Mirror the Hummingbird todos-postgres pattern exactly:
        //   addServices → postgres, then workers (all managed by the Application)
        //   beforeServerStarts → schema check + seed (postgres is live by here)
        //   runService() → starts everything, handles SIGTERM/SIGINT
        app.addServices(observability)  // must be first so OTel is live before any spans are emitted
        app.addServices(postgres)
        app.addServices(ordersWorker)
        app.addServices(reportsWorker)

        app.beforeServerStarts {
            try await ordersClient.verifySchema()
            // Seed demo data after schema is confirmed.  Runs as a Task so
            // it doesn't hold up the HTTP server from accepting connections.
            Task { await runSeeder(orders: ordersClient, reports: reportsClient, logger: logger) }
            logger.info("────────────────────────────────────────────────")
            logger.info("  Strand DevServer ready")
            logger.info("  API     →  http://localhost:8080/api/queues")
            logger.info("  UI      →  cd loom && npm run dev")
            logger.info("  Traces  →  http://localhost:16686  (Jaeger)")
            logger.info("  queues: orders, reports")
            logger.info("────────────────────────────────────────────────")
        }

        try await app.runService()
    }
}
