import Hummingbird
import Strand

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

// MARK: - SchedulePattern helpers (local extension)

extension SchedulePattern {
    fileprivate var typeName: String {
        switch self {
        case .cron: return "cron"
        case .interval: return "interval"
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .once: return "once"
        }
    }
}

// MARK: - Response type

struct ScheduleSummaryResponse: Codable, Sendable {
    let id: String
    let name: String
    let queue: String
    let taskName: String
    let isActive: Bool
    let nextRunAt: Date?
    let lastRunAt: Date?
    let runCount: Int
    let createdAt: Date
    let patternType: String
    let patternDescription: String

    init(from s: ScheduleSummary) {
        id = s.id.uuidString
        name = s.name
        queue = s.queue
        taskName = s.taskName
        isActive = s.isActive
        nextRunAt = s.nextRunAt
        lastRunAt = s.lastRunAt
        runCount = s.runCount
        createdAt = s.createdAt
        patternType = s.pattern.typeName
        patternDescription = s.pattern.description
    }
}
extension ScheduleSummaryResponse: ResponseCodable {}

// MARK: - Detail response

/// Extended schedule response including `startsAt` / `endsAt` window fields.
struct ScheduleDetailResponse: Codable, Sendable {
    let id: String
    let name: String
    let queue: String
    let taskName: String
    let isActive: Bool
    let nextRunAt: Date?
    let lastRunAt: Date?
    let runCount: Int
    let createdAt: Date
    let patternType: String
    let patternDescription: String
    let startsAt: Date?
    let endsAt: Date?

    init(from s: ScheduleSummary) {
        id = s.id.uuidString
        name = s.name
        queue = s.queue
        taskName = s.taskName
        isActive = s.isActive
        nextRunAt = s.nextRunAt
        lastRunAt = s.lastRunAt
        runCount = s.runCount
        createdAt = s.createdAt
        patternType = s.pattern.typeName
        patternDescription = s.pattern.description
        startsAt = s.startsAt
        endsAt = s.endsAt
    }
}
extension ScheduleDetailResponse: ResponseCodable {}

// MARK: - Run response

struct ScheduleRunResponse: Codable, Sendable {
    let id: String
    let state: String
    let attempt: Int
    let createdAt: Date
    let completedAt: Date?
}
extension ScheduleRunResponse: ResponseCodable {}

// MARK: - Routes

struct ScheduleRoutes {
    let client: StrandClient

    func register(on router: some RouterMethods<StrandRequestContext>) {

        // GET /api/:namespace/schedules?queue=
        router.get("schedules") { req, ctx -> [ScheduleSummaryResponse] in
            let queue = req.uri.queryParameters.get("queue")
            let summaries = try await self.client.listSchedules(
                queue: queue, namespaceID: ctx.namespaceID)
            return summaries.map(ScheduleSummaryResponse.init)
        }

        // GET /api/:namespace/schedules/:id
        router.get("schedules/:id") { _, ctx -> ScheduleDetailResponse in
            let uuid = try ctx.parameters.require("id", as: UUID.self)
            let summaries = try await self.client.listSchedules(
                queue: nil, namespaceID: ctx.namespaceID)
            guard let s = summaries.first(where: { $0.id == uuid }) else {
                throw HTTPError(.notFound, message: "Schedule not found")
            }
            return ScheduleDetailResponse(from: s)
        }

        // POST /api/:namespace/schedules/:id/pause
        router.post("schedules/:id/pause") { _, ctx -> SimpleResponse in
            let uuid = try ctx.parameters.require("id", as: UUID.self)
            try await ScheduleQueries.pauseSchedule(
                on: self.client.postgres, namespaceID: ctx.namespaceID,
                id: uuid, logger: self.client.logger)
            return SimpleResponse(message: "paused", id: uuid.uuidString)
        }

        // POST /api/:namespace/schedules/:id/resume
        router.post("schedules/:id/resume") { _, ctx -> SimpleResponse in
            let uuid = try ctx.parameters.require("id", as: UUID.self)
            try await ScheduleQueries.resumeSchedule(
                on: self.client.postgres, namespaceID: ctx.namespaceID,
                id: uuid, logger: self.client.logger)
            return SimpleResponse(message: "resumed", id: uuid.uuidString)
        }

        // GET /api/:namespace/schedules/:id/runs — tasks fired by this schedule (newest first)
        router.get("schedules/:id/runs") { req, ctx -> [ScheduleRunResponse] in
            let scheduleID = try ctx.parameters.require("id", as: UUID.self)
            let limit = req.uri.queryParameters.get("limit").flatMap(Int.init) ?? 20

            let prefix = "$schedule:\(scheduleID.uuidString):"
            let stream = try await self.client.postgres.query(
                """
                SELECT id, state, attempt, created_at, completed_at
                FROM strand.tasks
                WHERE namespace_id = \(ctx.namespaceID)
                  AND idempotency_key LIKE \(prefix + "%")
                ORDER BY created_at DESC
                LIMIT \(min(limit, 100))
                """,
                logger: self.client.logger
            )
            var rows: [ScheduleRunResponse] = []
            for try await row in stream {
                var col = row.makeIterator()
                let id = try col.next()!.decode(UUID.self, context: .default)
                let state = try col.next()!.decode(String.self, context: .default)
                let attempt = try col.next()!.decode(Int.self, context: .default)
                let createdAt = try col.next()!.decode(Date.self, context: .default)
                let completedAt = try col.next()!.decode(Date?.self, context: .default)
                rows.append(
                    ScheduleRunResponse(
                        id: id.uuidString,
                        state: state,
                        attempt: attempt,
                        createdAt: createdAt,
                        completedAt: completedAt
                    ))
            }
            return rows
        }

        // DELETE /api/:namespace/schedules/:id
        router.delete("schedules/:id") { _, ctx -> SimpleResponse in
            let uuid = try ctx.parameters.require("id", as: UUID.self)
            try await ScheduleQueries.deleteSchedule(
                on: self.client.postgres, namespaceID: ctx.namespaceID,
                id: uuid, logger: self.client.logger)
            return SimpleResponse(message: "deleted", id: uuid.uuidString)
        }
    }
}
