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
        case .yearly: return "yearly"
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
    let lastTaskID: UUID?
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
        lastTaskID = s.lastTaskID
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
    let lastTaskID: UUID?
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
        lastTaskID = s.lastTaskID
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

// MARK: - Upcoming response

/// One upcoming fire-time slot returned by `GET /api/:namespace/schedules/:id/upcoming`.
struct UpcomingSlotResponse: Codable, Sendable {
    /// The wall-clock UTC time when this slot will fire.
    let slot: Date
}
extension UpcomingSlotResponse: ResponseCodable {}

// MARK: - Routes

private struct RunScheduleBody: Decodable {
    let partitionTime: Date
    let allowOverwrite: Bool?
}

struct ScheduleRoutes {
    let client: StrandClient

    func register(on router: some RouterMethods<StrandRequestContext>) {

        // GET /api/:namespace/schedules?queue=
        router.get("schedules") { req, ctx -> [ScheduleSummaryResponse] in
            let queue = req.uri.queryParameters.get("queue")
            let limit = req.uri.queryParameters.get("limit").flatMap(Int.init) ?? 200
            let afterQueue = req.uri.queryParameters.get("afterQueue")
            let afterName = req.uri.queryParameters.get("afterName")
            let summaries = try await self.client.listSchedules(
                queue: queue,
                namespaceID: ctx.namespaceID,
                limit: min(limit, 500),
                afterQueue: afterQueue,
                afterName: afterName
            )
            return summaries.map(ScheduleSummaryResponse.init)
        }

        // GET /api/:namespace/schedules/:id
        router.get("schedules/:id") { _, ctx -> ScheduleDetailResponse in
            let uuid = try ctx.parameters.require("id", as: UUID.self)
            guard
                let s = try await self.client.getSchedule(
                    id: uuid,
                    namespaceID: ctx.namespaceID
                )
            else {
                throw HTTPError(.notFound, message: "Schedule not found")
            }
            return ScheduleDetailResponse(from: s)
        }

        // POST /api/:namespace/schedules/:id/pause
        router.post("schedules/:id/pause") { _, ctx -> SimpleResponse in
            let uuid = try ctx.parameters.require("id", as: UUID.self)
            try await ScheduleQueries.pauseSchedule(
                on: self.client.postgres,
                namespaceID: ctx.namespaceID,
                id: uuid,
                logger: self.client.logger
            )
            return SimpleResponse(message: "paused", id: uuid.uuidString)
        }

        // POST /api/:namespace/schedules/:id/resume
        router.post("schedules/:id/resume") { _, ctx -> SimpleResponse in
            let uuid = try ctx.parameters.require("id", as: UUID.self)
            // Default: skip slots missed during the pause and resume from now.
            // Clients that want to replay missed slots should omit or send a
            // custom recomputeFrom via a future query param.
            try await ScheduleQueries.resumeSchedule(
                on: self.client.postgres,
                namespaceID: ctx.namespaceID,
                id: uuid,
                recomputeFrom: Date.now,
                logger: self.client.logger
            )
            return SimpleResponse(message: "resumed", id: uuid.uuidString)
        }

        // GET /api/:namespace/schedules/:id/runs — tasks fired by this schedule (newest first)
        router.get("schedules/:id/runs") { req, ctx -> [ScheduleRunResponse] in
            let scheduleID = try ctx.parameters.require("id", as: UUID.self)
            let limit = req.uri.queryParameters.get("limit").flatMap(Int.init) ?? 20
            let runs = try await ScheduleQueries.listScheduleRuns(
                on: self.client.postgres,
                namespaceID: ctx.namespaceID,
                scheduleID: scheduleID,
                limit: limit,
                logger: self.client.logger
            )
            return runs.map { row in
                ScheduleRunResponse(
                    id: row.id.uuidString,
                    state: row.state,
                    attempt: row.attempt,
                    createdAt: row.createdAt,
                    completedAt: row.completedAt
                )
            }
        }

        // GET /api/:namespace/schedules/:id/upcoming?count=5
        // Returns the next N scheduled fire times starting from nextRunAt.
        // Uses ScheduleCalculator.nextRunTime to iterate forward from the schedule's
        // current nextRunAt so the list is always in sync with what the scheduler
        // will actually fire next.
        router.get("schedules/:id/upcoming") { req, ctx -> [UpcomingSlotResponse] in
            let uuid = try ctx.parameters.require("id", as: UUID.self)
            let count = min(req.uri.queryParameters.get("count").flatMap(Int.init) ?? 5, 20)
            guard
                let s = try await self.client.getSchedule(
                    id: uuid,
                    namespaceID: ctx.namespaceID
                )
            else {
                throw HTTPError(.notFound, message: "Schedule not found")
            }
            // If the schedule has no nextRunAt (e.g. paused before ever firing, or
            // endsAt has passed), return an empty list rather than an error.
            guard let nextRunAt = s.nextRunAt else { return [] }
            var slots: [UpcomingSlotResponse] = []
            // Start the iteration one millisecond before nextRunAt so that
            // nextRunTime(after:) returns nextRunAt itself as the first result.
            var cursor = nextRunAt.addingTimeInterval(-0.001)
            for _ in 0..<count {
                guard
                    let next = try? ScheduleCalculator.nextRunTime(
                        for: s.pattern,
                        after: cursor,
                        timezone: s.pattern.timezone
                    )
                else { break }
                slots.append(UpcomingSlotResponse(slot: next))
                cursor = next
            }
            return slots
        }

        // POST /api/:namespace/schedules/:id/run
        // Fire a single execution for a specific partition time.
        // Uses the scheduler's idempotency key format so re-running an already-completed
        // slot is blocked via ON CONFLICT — unless allowOverwrite is true.
        router.post("schedules/:id/run") { req, ctx -> RunScheduleResponse in
            let scheduleID = try ctx.parameters.require("id", as: UUID.self)
            let body = try await req.decode(as: RunScheduleBody.self, context: ctx)
            let result = try await self.client.runScheduleSlot(
                scheduleID: scheduleID,
                partitionTime: body.partitionTime,
                allowOverwrite: body.allowOverwrite ?? false,
                namespaceID: ctx.namespaceID
            )
            return RunScheduleResponse(
                taskId: result.taskID,
                runId: result.runID
            )
        }

        // DELETE /api/:namespace/schedules/:id
        router.delete("schedules/:id") { _, ctx -> SimpleResponse in
            let uuid = try ctx.parameters.require("id", as: UUID.self)
            try await ScheduleQueries.deleteSchedule(
                on: self.client.postgres,
                namespaceID: ctx.namespaceID,
                id: uuid,
                logger: self.client.logger
            )
            return SimpleResponse(message: "deleted", id: uuid.uuidString)
        }
    }
}
