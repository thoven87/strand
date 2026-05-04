import Hummingbird
import PostgresNIO
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct EventRoutes {
    let client: StrandClient
    let postgres: PostgresClient

    private struct EmitEventBody: Decodable {
        let name: String
        let payload: String?
    }

    func register(on router: some RouterMethods<StrandRequestContext>) {

        // GET /api/:namespace/events?queue=&cursor=&limit=   — cross-queue events
        router.get("events") { req, _ -> CursorPageResponse<EventResponse> in
            let qp = req.uri.queryParameters
            let queue = qp.get("queue")  // nil = all queues
            let limit = qp.get("limit").flatMap(Int.init) ?? 50
            let cursorStr = qp.get("cursor")
            let cursor: Date? = cursorStr.flatMap { Double($0) }.map {
                Date(timeIntervalSince1970: $0)
            }

            let page = try await ManagementQueries.listEventsGlobal(
                on: self.postgres,
                queue: queue,
                cursor: cursor,
                limit: min(limit, 200),
                logger: self.client.logger
            )
            return CursorPageResponse(
                items: page.items.map(EventResponse.init),
                nextCursor: page.nextCursor
            )
        }

        router.get("queues/:queue/events") { req, ctx -> CursorPageResponse<EventResponse> in
            let queue = try ctx.parameters.require("queue")
            let qp = req.uri.queryParameters
            let limit = qp.get("limit").flatMap(Int.init) ?? 50
            let cursor: Date? = qp.get("cursor")
                .flatMap { Double($0) }
                .map { Date(timeIntervalSince1970: $0) }
            let page = try await ManagementQueries.listEvents(
                on: self.postgres,
                queue: queue,
                cursor: cursor,
                limit: min(limit, 200),
                logger: self.client.logger
            )
            return CursorPageResponse(
                items: page.items.map(EventResponse.init),
                nextCursor: page.nextCursor
            )
        }
        router.post("queues/:queue/events") { req, ctx -> SimpleResponse in
            let queue = try ctx.parameters.require("queue")
            let body = try await req.decode(as: EmitEventBody.self, context: ctx)
            let payloadStr = body.payload ?? "null"
            try await self.client.emitEvent(body.name, payload: payloadStr, queue: queue)
            return SimpleResponse(message: "emitted", id: body.name)
        }
    }
}
