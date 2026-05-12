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
        router.get("events") { req, ctx -> CursorPageResponse<EventResponse> in
            let qp = req.uri.queryParameters
            let queue = qp.get("queue")  // nil = all queues
            let name = qp.get("name")  // nil = all event names
            let limit = qp.get("limit").flatMap(Int.init) ?? 50
            let cursorStr = qp.get("cursor")
            let cursor: Date? = cursorStr.flatMap { Double($0) }.map {
                Date(timeIntervalSince1970: $0)
            }

            let since: Date? = qp.get("since").flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
            let page = try await ManagementQueries.listEventsGlobal(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                queue: queue,
                name: name,
                since: since,
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
            let since: Date? = qp.get("since").flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
            let page = try await ManagementQueries.listEvents(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                queue: queue,
                since: since,
                cursor: cursor,
                limit: min(limit, 200),
                logger: self.client.logger
            )
            return CursorPageResponse(
                items: page.items.map(EventResponse.init),
                nextCursor: page.nextCursor
            )
        }
        // GET /api/:namespace/queues/:queue/events/:name/waiters
        // Returns workflows currently suspended in ctx.waitForEvent(name).
        // Powers the "Waiting for this event" panel in the Loom events page.
        router.get("queues/:queue/events/:name/waiters") { req, ctx -> [EventWaiterResponse] in
            let queue = try ctx.parameters.require("queue")
            let name = try ctx.parameters.require("name")
            let limit = req.uri.queryParameters.get("limit").flatMap(Int.init) ?? 20
            let rows = try await ManagementQueries.listEventWaiters(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                queue: queue,
                eventName: name,
                limit: min(limit, 200),
                logger: self.client.logger
            )
            return rows.map(EventWaiterResponse.init)
        }

        // GET /api/:namespace/tasks/:taskID/event-trigger
        // Returns the event-trigger for a task — the specific event emission that
        // woke this workflow from a ctx.waitForEvent suspension.
        // Returns null (not 404) when the task was not woken by a named event,
        // since the task itself exists and a missing trigger is a valid state.
        router.get("tasks/:taskID/event-trigger") { _, ctx -> EventTriggerResponse? in
            let taskID = try ctx.parameters.require("taskID", as: UUID.self)
            guard
                let row = try await ManagementQueries.getEventTriggerForTask(
                    on: self.postgres,
                    namespaceID: ctx.namespaceID,
                    taskID: taskID,
                    logger: self.client.logger
                )
            else { return nil }
            return EventTriggerResponse(from: row)
        }

        // POST /api/:namespace/queues/:queue/events
        // Emits a named event into the namespace from the URL path.
        //
        router.post("queues/:queue/events") { req, ctx -> SimpleResponse in
            let queue = try ctx.parameters.require("queue")
            let body = try await req.decode(as: EmitEventBody.self, context: ctx)
            // Trim whitespace; nil or empty payload → JSON null (event delivered, no data).
            let buf: ByteBuffer? = body.payload.flatMap { raw -> ByteBuffer? in
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : ByteBuffer(string: t)
            }
            try await self.client.emitEvent(
                body.name,
                payloadBuffer: buf,
                queue: queue,
                namespaceID: ctx.namespaceID
            )
            return SimpleResponse(message: "emitted", id: body.name)
        }
    }
}
