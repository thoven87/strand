package import Logging
package import NIOCore
package import PostgresNIO

#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

package enum BackfillQueries {

    // MARK: - Types

    package enum BackfillStatus: String, Sendable {
        case running = "RUNNING"
        case halted = "HALTED"
        case completed = "COMPLETED"
        case failed = "FAILED"
    }

    package struct BackfillRow: Sendable {
        package let id: UUID
        package let namespaceID: String
        package let queue: String
        package let taskName: String
        package let taskKind: TaskKind
        package let paramsBuffer: ByteBuffer
        package let headersBuffer: ByteBuffer?
        package let retryStrategyBuffer: ByteBuffer?
        package let maxAttempts: Int?
        package let schedulePatternBuffer: ByteBuffer
        package let rangeStart: Date
        package let rangeEnd: Date
        package let concurrency: Int
        package let allowOverwrite: Bool
        package let description: String?
        package let scheduleId: UUID?
        package let status: BackfillStatus
        package let nextSlotTime: Date
        package let totalSlots: Int
        package let completedSlots: Int
        package let createdAt: Date
        package let completedAt: Date?
    }

    // MARK: - Create

    package static func createBackfill(
        on client: PostgresClient,
        id: UUID,
        namespaceID: String,
        queue: String,
        taskName: String,
        taskKind: TaskKind,
        paramsBuffer: ByteBuffer,
        headersBuffer: ByteBuffer?,
        retryStrategyBuffer: ByteBuffer?,
        maxAttempts: Int?,
        schedulePatternBuffer: ByteBuffer,
        rangeStart: Date,
        rangeEnd: Date,
        concurrency: Int,
        allowOverwrite: Bool,
        description: String?,
        scheduleId: UUID? = nil,
        nextSlotTime: Date,
        totalSlots: Int,
        logger: Logger
    ) async throws {
        try await client.query(
            """
            INSERT INTO strand.backfills
                (id, namespace_id, queue, task_name, task_kind, params, headers,
                 retry_strategy, max_attempts, schedule_pattern,
                 range_start, range_end, concurrency, allow_overwrite, description,
                 schedule_id, next_slot_time, total_slots)
            VALUES
                (\(id), \(namespaceID), \(queue), \(taskName), \(taskKind),
                 \(paramsBuffer), \(headersBuffer), \(retryStrategyBuffer), \(maxAttempts),
                 \(schedulePatternBuffer), \(rangeStart), \(rangeEnd), \(concurrency),
                 \(allowOverwrite), \(description), \(scheduleId), \(nextSlotTime), \(totalSlots))
            """,
            logger: logger
        )
    }

    // MARK: - List running (called by StrandScheduler each poll cycle)

    package static func listRunning(
        on client: PostgresClient,
        namespaceID: String,
        limit: Int = 50,
        logger: Logger
    ) async throws -> [BackfillRow] {
        let stream = try await client.query(
            """
            SELECT id, namespace_id, queue, task_name, task_kind, params, headers,
                   retry_strategy, max_attempts, schedule_pattern,
                   range_start, range_end, concurrency, allow_overwrite, description,
                   schedule_id, status, next_slot_time, total_slots, completed_slots, created_at, completed_at
            FROM strand.backfills
            WHERE namespace_id = \(namespaceID)
              AND status = \(BackfillStatus.running)
            ORDER BY created_at
            LIMIT \(limit)
            """,
            logger: logger
        )
        var rows: [BackfillRow] = []
        for try await row in stream { rows.append(try BackfillRow(row: row)) }
        return rows
    }

    // MARK: - Count in-flight tasks (concurrency enforcement)

    package static func countActiveTasks(
        on client: PostgresClient,
        backfillID: UUID,
        namespaceID: String,
        logger: Logger
    ) async throws -> Int {
        let stream = try await client.query(
            """
            SELECT COUNT(*)::int
            FROM strand.tasks
            WHERE backfill_id = \(backfillID)
              AND namespace_id = \(namespaceID)
              AND state IN (\(TaskState.pending), \(TaskState.running), \(TaskState.sleeping), \(TaskState.waiting))
            """,
            logger: logger
        )
        for try await row in stream {
            var col = row.makeIterator()
            return try col.next()!.decode(Int.self, context: .default)
        }
        return 0
    }

    // MARK: - Advance cursor

    package static func advanceCursor(
        on client: PostgresClient,
        backfillID: UUID,
        namespaceID: String,
        nextSlotTime: Date,
        firedCount: Int,
        logger: Logger
    ) async throws {
        try await client.query(
            """
            UPDATE strand.backfills
            SET next_slot_time  = \(nextSlotTime),
                completed_slots = completed_slots + \(firedCount)
            WHERE id = \(backfillID) AND namespace_id = \(namespaceID)
            """,
            logger: logger
        )
    }

    // MARK: - Mark completed

    package static func markCompleted(
        on client: PostgresClient,
        backfillID: UUID,
        namespaceID: String,
        logger: Logger
    ) async throws {
        try await client.query(
            """
            UPDATE strand.backfills
            SET status       = \(BackfillStatus.completed),
                completed_at = NOW()
            WHERE id = \(backfillID) AND namespace_id = \(namespaceID)
              AND status = \(BackfillStatus.running)
            """,
            logger: logger
        )
    }

    // MARK: - Halt / resume / change concurrency

    package static func halt(
        on client: PostgresClient,
        backfillID: UUID,
        namespaceID: String,
        logger: Logger
    ) async throws {
        try await client.query(
            """
            UPDATE strand.backfills
            SET status = \(BackfillStatus.halted)
            WHERE id = \(backfillID) AND namespace_id = \(namespaceID)
              AND status = \(BackfillStatus.running)
            """,
            logger: logger
        )
    }

    package static func resume(
        on client: PostgresClient,
        backfillID: UUID,
        namespaceID: String,
        logger: Logger
    ) async throws {
        try await client.query(
            """
            UPDATE strand.backfills
            SET status = \(BackfillStatus.running)
            WHERE id = \(backfillID) AND namespace_id = \(namespaceID)
              AND status = \(BackfillStatus.halted)
            """,
            logger: logger
        )
    }

    package static func setConcurrency(
        on client: PostgresClient,
        backfillID: UUID,
        concurrency: Int,
        namespaceID: String,
        logger: Logger
    ) async throws {
        try await client.query(
            "UPDATE strand.backfills SET concurrency = \(max(1, concurrency)) WHERE id = \(backfillID) AND namespace_id = \(namespaceID)",
            logger: logger
        )
    }

    // MARK: - Get single backfill

    package static func get(
        on client: PostgresClient,
        backfillID: UUID,
        namespaceID: String,
        logger: Logger
    ) async throws -> BackfillRow? {
        let stream = try await client.query(
            """
            SELECT id, namespace_id, queue, task_name, task_kind, params, headers,
                   retry_strategy, max_attempts, schedule_pattern,
                   range_start, range_end, concurrency, allow_overwrite, description,
                   schedule_id, status, next_slot_time, total_slots, completed_slots, created_at, completed_at
            FROM strand.backfills
            WHERE id = \(backfillID) AND namespace_id = \(namespaceID)
            """,
            logger: logger
        )
        for try await row in stream { return try BackfillRow(row: row) }
        return nil
    }

    // MARK: - List backfills for a (namespace, queue, taskName) triple

    package static func listForQueue(
        on client: PostgresClient,
        namespaceID: String,
        queue: String,
        taskName: String,
        limit: Int = 20,
        logger: Logger
    ) async throws -> [BackfillRow] {
        let stream = try await client.query(
            """
            SELECT id, namespace_id, queue, task_name, task_kind, params, headers,
                   retry_strategy, max_attempts, schedule_pattern,
                   range_start, range_end, concurrency, allow_overwrite, description,
                   schedule_id, status, next_slot_time, total_slots, completed_slots, created_at, completed_at
            FROM strand.backfills
            WHERE namespace_id = \(namespaceID) AND queue = \(queue) AND task_name = \(taskName)
            ORDER BY created_at DESC
            LIMIT \(limit)
            """,
            logger: logger
        )
        var rows: [BackfillRow] = []
        for try await row in stream { rows.append(try BackfillRow(row: row)) }
        return rows
    }
}

// MARK: - BackfillStatus: PostgresCodable

extension BackfillQueries.BackfillStatus: PostgresCodable {
    package static var psqlType: PostgresDataType { .text }
    package static var psqlFormat: PostgresFormat { .binary }

    package func encode<E: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<E>
    ) throws {
        rawValue.encode(into: &byteBuffer, context: context)
    }

    package init<D: PostgresJSONDecoder>(
        from byteBuffer: inout ByteBuffer,
        type: PostgresDataType,
        format: PostgresFormat,
        context: PostgresDecodingContext<D>
    ) throws {
        let raw = try String(from: &byteBuffer, type: type, format: format, context: context)
        guard let v = BackfillQueries.BackfillStatus(rawValue: raw) else {
            throw PostgresDecodingError.Code.typeMismatch
        }
        self = v
    }
}

// MARK: - BackfillRow decoding

extension BackfillQueries.BackfillRow {
    package init(row: PostgresRow) throws {
        var col = row.makeIterator()
        id = try col.next()!.decode(UUID.self, context: .default)
        namespaceID = try col.next()!.decode(String.self, context: .default)
        queue = try col.next()!.decode(String.self, context: .default)
        taskName = try col.next()!.decode(String.self, context: .default)
        taskKind = try col.next()!.decode(TaskKind.self, context: .default)
        paramsBuffer = try col.next()!.decode(ByteBuffer.self, context: .default)
        headersBuffer = try col.next()!.decode(ByteBuffer?.self, context: .default)
        retryStrategyBuffer = try col.next()!.decode(ByteBuffer?.self, context: .default)
        maxAttempts = try col.next()!.decode(Int?.self, context: .default)
        schedulePatternBuffer = try col.next()!.decode(ByteBuffer.self, context: .default)
        rangeStart = try col.next()!.decode(Date.self, context: .default)
        rangeEnd = try col.next()!.decode(Date.self, context: .default)
        concurrency = try col.next()!.decode(Int.self, context: .default)
        allowOverwrite = try col.next()!.decode(Bool.self, context: .default)
        description = try col.next()!.decode(String?.self, context: .default)
        scheduleId = try col.next()!.decode(UUID?.self, context: .default)
        status = try col.next()!.decode(BackfillQueries.BackfillStatus.self, context: .default)
        nextSlotTime = try col.next()!.decode(Date.self, context: .default)
        totalSlots = try col.next()!.decode(Int.self, context: .default)
        completedSlots = try col.next()!.decode(Int.self, context: .default)
        createdAt = try col.next()!.decode(Date.self, context: .default)
        completedAt = try col.next()!.decode(Date?.self, context: .default)
    }
}
