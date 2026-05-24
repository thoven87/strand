import Hummingbird
import PostgresNIO
import Strand

struct QueueRoutes {
    let client: StrandClient
    let postgres: PostgresClient
    /// Optional broadcast-cache for per-queue `throughputPerSec`.
    /// When warm, populates `QueueResponse.throughputPerSec` with zero extra DB queries.
    let metricsCache: MetricsCache?

    private struct CreateQueueBody: Decodable { let name: String }

    func register(on router: some RouterMethods<StrandRequestContext>) {

        router.get("queues") { req, ctx -> [QueueResponse] in
            let rootOnly = req.uri.queryParameters.get("rootOnly").map { $0 == "true" } ?? false
            let rows = try await ManagementQueries.listQueueStats(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                rootOnly: rootOnly,
                logger: self.client.logger
            )
            let rates = self.metricsCache?.queueThroughputRates(namespace: ctx.namespaceID) ?? [:]
            return rows.map { QueueResponse(from: $0, throughputPerSec: rates[$0.name]) }
        }

        router.post("queues") { req, ctx -> SimpleResponse in
            let body = try await req.decode(as: CreateQueueBody.self, context: ctx)
            try await self.client.createQueue(body.name, namespaceID: ctx.namespaceID)
            return SimpleResponse(message: "created", id: body.name)
        }

        router.get("queues/:queue") { req, ctx -> QueueResponse in
            let queue = try ctx.parameters.require("queue")
            let rootOnly = req.uri.queryParameters.get("rootOnly").map { $0 == "true" } ?? false
            guard
                let row = try await ManagementQueries.queueStats(
                    on: self.postgres,
                    namespaceID: ctx.namespaceID,
                    queue: queue,
                    rootOnly: rootOnly,
                    logger: self.client.logger
                )
            else {
                throw HTTPError(.notFound, message: "Queue '\(queue)' not found")
            }
            let rate = self.metricsCache?.throughputPerSec(forQueue: queue, namespace: ctx.namespaceID)
            return QueueResponse(from: row, throughputPerSec: rate)
        }

        router.delete("queues/:queue") { _, ctx -> SimpleResponse in
            let queue = try ctx.parameters.require("queue")
            try await self.client.dropQueue(queue, namespaceID: ctx.namespaceID)
            return SimpleResponse(message: "dropped", id: queue)
        }

        // POST /api/:namespace/queues/:queue/pause
        router.post("queues/:queue/pause") { _, ctx -> SimpleResponse in
            let queue = try ctx.parameters.require("queue")
            try await self.client.pauseQueue(queue, namespaceID: ctx.namespaceID)
            return SimpleResponse(message: "paused", id: queue)
        }

        // POST /api/:namespace/queues/:queue/resume
        router.post("queues/:queue/resume") { _, ctx -> SimpleResponse in
            let queue = try ctx.parameters.require("queue")
            try await self.client.resumeQueue(queue, namespaceID: ctx.namespaceID)
            return SimpleResponse(message: "resumed", id: queue)
        }

        // POST /api/:namespace/queues/:queue/cleanup?olderThan=2592000&limit=1000
        router.post("queues/:queue/cleanup") { req, ctx -> SimpleResponse in
            let queue = try ctx.parameters.require("queue")
            let qp = req.uri.queryParameters
            let olderThan = qp.get("olderThan").flatMap(Int.init) ?? (30 * 24 * 3600)
            let limit = qp.get("limit").flatMap(Int.init) ?? 1000
            let deleted = try await ManagementQueries.cleanupTasks(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                queue: queue,
                ageSeconds: olderThan,
                limit: min(limit, 10_000),
                logger: self.client.logger
            )
            return SimpleResponse(message: "deleted \(deleted) task(s)", id: queue)
        }

        // POST /api/:namespace/cleanup — global cleanup across all queues in namespace
        router.post("cleanup") { req, ctx -> SimpleResponse in
            let qp = req.uri.queryParameters
            let olderThan = qp.get("olderThan").flatMap(Int.init) ?? (30 * 24 * 3600)
            let limit = qp.get("limit").flatMap(Int.init) ?? 1000
            let deleted = try await ManagementQueries.cleanupTasks(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                queue: nil,
                ageSeconds: olderThan,
                limit: min(limit, 10_000),
                logger: self.client.logger
            )
            return SimpleResponse(message: "deleted \(deleted) task(s)", id: "all")
        }
    }
}
