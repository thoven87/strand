import Hummingbird
import PostgresNIO
import Strand

struct QueueRoutes {
    let client: StrandClient
    let postgres: PostgresClient

    private struct CreateQueueBody: Decodable { let name: String }

    func register(on router: some RouterMethods<StrandRequestContext>) {

        router.get("queues") { _, ctx -> [QueueResponse] in
            let rows = try await ManagementQueries.listQueueStats(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                logger: self.client.logger
            )
            return rows.map(QueueResponse.init)
        }

        router.post("queues") { req, ctx -> SimpleResponse in
            let body = try await req.decode(as: CreateQueueBody.self, context: ctx)
            try await self.client.createQueue(body.name)
            return SimpleResponse(message: "created", id: body.name)
        }

        router.get("queues/:queue") { _, ctx -> QueueResponse in
            let queue = try ctx.parameters.require("queue")
            guard
                let row = try await ManagementQueries.queueStats(
                    on: self.postgres,
                    namespaceID: ctx.namespaceID,
                    queue: queue,
                    logger: self.client.logger
                )
            else {
                throw HTTPError(.notFound, message: "Queue '\(queue)' not found")
            }
            return QueueResponse(from: row)
        }

        router.delete("queues/:queue") { _, ctx -> SimpleResponse in
            let queue = try ctx.parameters.require("queue")
            try await self.client.dropQueue(queue)
            return SimpleResponse(message: "dropped", id: queue)
        }

        // POST /api/:namespace/queues/:queue/pause
        router.post("queues/:queue/pause") { _, ctx -> SimpleResponse in
            let queue = try ctx.parameters.require("queue")
            try await self.client.pauseQueue(queue)
            return SimpleResponse(message: "paused", id: queue)
        }

        // POST /api/:namespace/queues/:queue/resume
        router.post("queues/:queue/resume") { _, ctx -> SimpleResponse in
            let queue = try ctx.parameters.require("queue")
            try await self.client.resumeQueue(queue)
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
