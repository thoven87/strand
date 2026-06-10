import Hummingbird
import NIOCore
import PostgresNIO
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Response types

struct BackfillResponse: Codable, Sendable {
    let id: String
    let scheduleId: UUID?
    let queue: String
    let taskName: String
    let taskKind: String
    let rangeStart: Date
    let rangeEnd: Date
    let concurrency: Int
    let allowOverwrite: Bool
    let description: String?
    let status: String
    let nextSlotTime: Date
    let totalSlots: Int
    let completedSlots: Int
    let createdAt: Date
    let completedAt: Date?
}
extension BackfillResponse: ResponseCodable {}

// MARK: - Routes

struct BackfillRoutes {
    let client: StrandClient
    let postgres: PostgresClient

    private struct CreateBackfillBody: Decodable {
        let rangeStart: Date
        let rangeEnd: Date
        let concurrency: Int?
        let allowOverwrite: Bool?
        let description: String?
    }

    private struct UpdateConcurrencyBody: Decodable {
        let concurrency: Int
    }

    func register(on router: some RouterMethods<StrandRequestContext>) {

        // ── POST /api/:namespace/schedules/:id/backfills ────────────────────────────────────
        // Create a backfill for an existing schedule. Inherits task_name, params,
        // kind, and schedule_pattern from the schedule row.
        router.post("schedules/:id/backfills") { req, ctx -> BackfillResponse in
            let scheduleID = try ctx.parameters.require("id", as: UUID.self)
            let body = try await req.decode(as: CreateBackfillBody.self, context: ctx)

            // Load full schedule data (params, pattern, task config)
            guard
                let schedule = try await ScheduleQueries.getSchedule(
                    on: self.postgres,
                    namespaceID: ctx.namespaceID,
                    id: scheduleID,
                    logger: self.client.logger
                )
            else {
                throw HTTPError(.notFound, message: "Schedule not found")
            }

            let id = UUID.v7()
            let pattern = try JSON.decode(SchedulePattern.self, from: schedule.patternBuffer)
            let concurrency = max(1, body.concurrency ?? 1)
            let totalSlots = ScheduleCalculator.countSlots(for: pattern, in: body.rangeStart..<body.rangeEnd)

            try await BackfillQueries.createBackfill(
                on: self.postgres,
                id: id,
                namespaceID: ctx.namespaceID,
                queue: schedule.queue,
                taskName: schedule.taskName,
                taskKind: schedule.kind,
                paramsBuffer: schedule.paramsBuffer,
                headersBuffer: schedule.headersBuffer,
                retryStrategyBuffer: schedule.retryStrategyBuffer,
                maxAttempts: schedule.maxAttempts,
                schedulePatternBuffer: schedule.patternBuffer,
                rangeStart: body.rangeStart,
                rangeEnd: body.rangeEnd,
                concurrency: concurrency,
                allowOverwrite: body.allowOverwrite ?? false,
                description: body.description,
                scheduleId: scheduleID,
                totalSlots: totalSlots,
                logger: self.client.logger
            )
            guard
                let row = try await BackfillQueries.get(
                    on: self.postgres,
                    backfillID: id,
                    namespaceID: ctx.namespaceID,
                    logger: self.client.logger
                )
            else { throw HTTPError(.internalServerError) }
            return BackfillResponse(from: row, scheduleId: row.scheduleId)
        }

        // ── GET /api/:namespace/schedules/:id/backfills ──────────────────────────────
        router.get("schedules/:id/backfills") { _, ctx -> [BackfillResponse] in
            let scheduleID = try ctx.parameters.require("id", as: UUID.self)
            guard
                let schedule = try await ScheduleQueries.getSchedule(
                    on: self.postgres,
                    namespaceID: ctx.namespaceID,
                    id: scheduleID,
                    logger: self.client.logger
                )
            else { throw HTTPError(.notFound) }
            let rows = try await BackfillQueries.listForQueue(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                queue: schedule.queue,
                taskName: schedule.taskName,
                logger: self.client.logger
            )
            return rows.map { BackfillResponse(from: $0, scheduleId: $0.scheduleId) }
        }

        // ── GET /api/:namespace/backfills/:id ───────────────────────────────────────────
        router.get("backfills/:id") { _, ctx -> BackfillResponse? in
            let id = try ctx.parameters.require("id", as: UUID.self)
            guard
                let row = try await BackfillQueries.get(
                    on: self.postgres,
                    backfillID: id,
                    namespaceID: ctx.namespaceID,
                    logger: self.client.logger
                )
            else { return nil }  // Hummingbird returns 204 No Content
            return BackfillResponse(from: row, scheduleId: row.scheduleId)
        }

        // ── POST /api/:namespace/backfills/:id/halt ──────────────────────────────
        router.post("backfills/:id/halt") { _, ctx -> SimpleResponse in
            let id = try ctx.parameters.require("id", as: UUID.self)
            try await BackfillQueries.halt(
                on: self.postgres,
                backfillID: id,
                namespaceID: ctx.namespaceID,
                logger: self.client.logger
            )
            return SimpleResponse(message: "halted", id: id.uuidString)
        }

        // ── POST /api/:namespace/backfills/:id/resume ────────────────────────────
        router.post("backfills/:id/resume") { _, ctx -> SimpleResponse in
            let id = try ctx.parameters.require("id", as: UUID.self)
            try await BackfillQueries.resume(
                on: self.postgres,
                backfillID: id,
                namespaceID: ctx.namespaceID,
                logger: self.client.logger
            )
            return SimpleResponse(message: "resumed", id: id.uuidString)
        }

        // ── PATCH /api/:namespace/backfills/:id/concurrency ──────────────────────
        router.patch("backfills/:id/concurrency") { req, ctx -> SimpleResponse in
            let id = try ctx.parameters.require("id", as: UUID.self)
            let body = try await req.decode(as: UpdateConcurrencyBody.self, context: ctx)
            try await BackfillQueries.setConcurrency(
                on: self.postgres,
                backfillID: id,
                concurrency: body.concurrency,
                namespaceID: ctx.namespaceID,
                logger: self.client.logger
            )
            return SimpleResponse(message: "updated", id: id.uuidString)
        }
    }
}

// MARK: - BackfillResponse init

extension BackfillResponse {
    init(from row: BackfillQueries.BackfillRow, scheduleId: UUID?) {
        id = row.id.uuidString
        self.scheduleId = scheduleId
        queue = row.queue
        taskName = row.taskName
        taskKind = row.taskKind.rawValue
        rangeStart = row.rangeStart
        rangeEnd = row.rangeEnd
        concurrency = row.concurrency
        allowOverwrite = row.allowOverwrite
        description = row.description
        status = row.status.rawValue
        nextSlotTime = row.nextSlotTime
        totalSlots = row.totalSlots
        completedSlots = row.completedSlots
        createdAt = row.createdAt
        completedAt = row.completedAt
    }
}
