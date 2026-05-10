package import Logging
package import NIOCore
package import PostgresNIO

#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

// MARK: - Row types

/// A schedule row returned by ``ScheduleQueries/pollDueSchedules``.
package struct ScheduleRow: Sendable {
    let id: UUID
    let queue: String
    let name: String
    let taskName: String
    let paramsBuffer: ByteBuffer
    let headersBuffer: ByteBuffer?
    let patternBuffer: ByteBuffer
    /// The `next_run_at` value that triggered this fire.
    let scheduledAt: Date
    let endsAt: Date?
    let maxAttempts: Int?
    let retryStrategyBuffer: ByteBuffer?
    let cancellationBuffer: ByteBuffer?
    let accuracy: ScheduleAccuracy  // catch-up behaviour
    let kind: TaskKind  // 'WORKFLOW' or 'ACTIVITY'
}

/// A schedule summary row returned by ``ScheduleQueries/listSchedules``.
package struct ScheduleSummaryRow: Sendable {
    let id: UUID
    let queue: String
    let name: String
    let taskName: String
    let patternBuffer: ByteBuffer
    let isActive: Bool
    let startsAt: Date?
    let endsAt: Date?
    let nextRunAt: Date?
    let lastRunAt: Date?
    let lastTaskID: UUID?
    let runCount: Int
    let accuracy: ScheduleAccuracy
    let kind: TaskKind  // 'WORKFLOW' or 'ACTIVITY'
    let createdAt: Date
}

// MARK: - Queries

package enum ScheduleQueries {

    // MARK: Scheduler operations

    /// Finds all due schedules and claims them with `FOR UPDATE SKIP LOCKED`
    /// so multiple `StrandScheduler` instances never double-fire the same schedule.
    package static func pollDueSchedules(
        on client: PostgresClient,
        namespaceID: String,
        now: Date,
        limit: Int = 100,
        logger: Logger
    ) async throws -> [ScheduleRow] {
        let stream = try await client.query(
            """
            SELECT id, queue, name, task_name, params, headers,
                   pattern, next_run_at, ends_at,
                   max_attempts, retry_strategy, cancellation, accuracy, kind
            FROM strand.schedules
            WHERE namespace_id = \(namespaceID)
              AND is_active = TRUE
              AND (starts_at IS NULL OR starts_at <= \(now))
              AND (ends_at   IS NULL OR ends_at   >  \(now))
              AND next_run_at IS NOT NULL
              AND next_run_at <= \(now)
            ORDER BY next_run_at ASC
            LIMIT \(limit)
            FOR UPDATE SKIP LOCKED
            """,
            logger: logger
        )
        var rows: [ScheduleRow] = []
        for try await row in stream {
            var col = row.makeIterator()
            rows.append(
                ScheduleRow(
                    id: try col.next()!.decode(UUID.self, context: .default),
                    queue: try col.next()!.decode(String.self, context: .default),
                    name: try col.next()!.decode(String.self, context: .default),
                    taskName: try col.next()!.decode(String.self, context: .default),
                    paramsBuffer: try col.next()!.decode(ByteBuffer.self, context: .default),
                    headersBuffer: try col.next()!.decode(ByteBuffer?.self, context: .default),
                    patternBuffer: try col.next()!.decode(ByteBuffer.self, context: .default),
                    scheduledAt: try col.next()!.decode(Date.self, context: .default),
                    endsAt: try col.next()!.decode(Date?.self, context: .default),
                    maxAttempts: try col.next()!.decode(Int?.self, context: .default),
                    retryStrategyBuffer: try col.next()!.decode(
                        ByteBuffer?.self,
                        context: .default
                    ),
                    cancellationBuffer: try col.next()!.decode(
                        ByteBuffer?.self,
                        context: .default
                    ),
                    accuracy: try col.next()!.decode(ScheduleAccuracy.self, context: .default),
                    kind: try col.next()!.decode(TaskKind.self, context: .default)
                )
            )
        }
        return rows
    }

    /// Returns the `last_slot_at` (scheduled slot time of the last fire) for a
    /// named schedule, or `nil` if the schedule does not exist or has never fired.
    ///
    /// Used by `StrandClient._schedule` to anchor catch-up computation from the
    /// last successfully-fired slot boundary, not from the wall-clock fire time.
    /// The distinction matters: `last_run_at` stores the actual enqueue time
    /// (displayed in the dashboard), while `last_slot_at` stores the canonical
    /// slot the scheduler was covering (used for interval arithmetic).
    package static func lastSlotAt(
        on client: PostgresClient,
        namespaceID: String,
        queue: String,
        name: String,
        logger: Logger
    ) async throws -> Date? {
        let stream = try await client.query(
            """
            SELECT last_slot_at FROM strand.schedules
            WHERE namespace_id = \(namespaceID)
              AND queue        = \(queue)
              AND name         = \(name)
            """,
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else { return nil }
        var col = row.makeIterator()
        return try col.next()!.decode(Date?.self, context: .default)
    }

    /// Returns the earliest `next_run_at` across all active schedules in the
    /// namespace. The scheduler sleeps until this time (capped at `sleepCap`).
    package static func nextScheduledFireTime(
        on client: PostgresClient,
        namespaceID: String,
        logger: Logger
    ) async throws -> Date? {
        let stream = try await client.query(
            """
            SELECT next_run_at
            FROM strand.schedules
            WHERE namespace_id = \(namespaceID)
              AND is_active     = TRUE
              AND next_run_at   IS NOT NULL
              AND (starts_at IS NULL OR starts_at <= NOW())
              AND (ends_at   IS NULL OR ends_at   >  NOW())
            ORDER BY next_run_at ASC
            LIMIT 1
            """,
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else { return nil }
        var col = row.makeIterator()
        return try col.next()!.decode(Date?.self, context: .default)
    }

    /// Advances `next_run_at` after a successful fire.
    /// Passing `nextRunAt: nil` automatically deactivates one-shot schedules.
    ///
    /// - Parameters:
    ///   - firedAt: Actual wall-clock time the scheduler enqueued the task.
    ///     Stored in `last_run_at` and shown in the dashboard as "Last run".
    ///   - slotAt: The scheduled slot boundary this fire covers (e.g. 16:29 UTC).
    ///     Stored in `last_slot_at` and used by `_schedule` as the catch-up base
    ///     so interval arithmetic stays pinned to the original cadence.
    package static func markScheduleFired(
        on client: PostgresClient,
        namespaceID: String,
        id: UUID,
        firedAt: Date,
        slotAt: Date,
        nextRunAt: Date?,
        lastTaskID: UUID,
        logger: Logger
    ) async throws {
        try await client.query(
            """
            UPDATE strand.schedules
            SET last_run_at  = \(firedAt),
                last_slot_at = \(slotAt),
                last_task_id = \(lastTaskID),
                run_count    = run_count + 1,
                next_run_at  = \(nextRunAt),
                is_active    = \(nextRunAt != nil),
                updated_at   = NOW()
            WHERE namespace_id = \(namespaceID)
              AND id = \(id)
            """,
            logger: logger
        )
    }

    // MARK: Management operations

    /// Inserts or replaces a schedule (upsert on `namespace_id + queue + name`).
    package static func upsertSchedule(
        on client: PostgresClient,
        namespaceID: String,
        id: UUID,
        queue: String,
        name: String,
        taskName: String,
        paramsBuffer: ByteBuffer,
        headersBuffer: ByteBuffer?,
        patternBuffer: ByteBuffer,
        maxAttempts: Int?,
        retryStrategyBuffer: ByteBuffer?,
        cancellationBuffer: ByteBuffer?,
        accuracy: ScheduleAccuracy,
        kind: TaskKind,
        startsAt: Date?,
        endsAt: Date?,
        nextRunAt: Date?,
        logger: Logger
    ) async throws -> UUID {
        let stream = try await client.query(
            """
            INSERT INTO strand.schedules
                (namespace_id, id, queue, name, task_name, params, headers, pattern,
                 max_attempts, retry_strategy, cancellation, accuracy, kind,
                 starts_at, ends_at, next_run_at, is_active)
            VALUES
                (\(namespaceID), \(id), \(queue), \(name), \(taskName),
                 \(paramsBuffer), \(headersBuffer), \(patternBuffer),
                 \(maxAttempts), \(retryStrategyBuffer), \(cancellationBuffer), \(accuracy.dbString), \(kind.rawValue),
                 \(startsAt), \(endsAt), \(nextRunAt), \(nextRunAt != nil))
            ON CONFLICT (namespace_id, queue, name) DO UPDATE SET
                task_name       = EXCLUDED.task_name,
                params          = EXCLUDED.params,
                headers         = EXCLUDED.headers,
                pattern         = EXCLUDED.pattern,
                max_attempts    = EXCLUDED.max_attempts,
                retry_strategy  = EXCLUDED.retry_strategy,
                cancellation    = EXCLUDED.cancellation,
                accuracy        = EXCLUDED.accuracy,
                kind            = EXCLUDED.kind,
                starts_at       = EXCLUDED.starts_at,
                ends_at         = EXCLUDED.ends_at,
                -- next_run_at merge: take the EARLIER of the two values.
                --
                -- The caller supplies EXCLUDED.next_run_at anchored to last_run_at
                -- (not Date.now), so it correctly identifies the most-recent missed
                -- slot or the next future slot.  LEAST means:
                --
                --   • Existing overdue + new future  → keep existing (don't skip).
                --   • Existing future (corrupted)   + new earlier correct → heal it.
                --   • Both future, new < existing   → fire the earlier slot first
                --     (desirable after a pattern change).
                --   • Existing NULL                 → use new (fresh registration).
                --   • New NULL                      → keep existing (one-shot ended).
                next_run_at     = CASE
                                      WHEN strand.schedules.next_run_at IS NULL
                                      THEN EXCLUDED.next_run_at
                                      WHEN EXCLUDED.next_run_at IS NULL
                                      THEN strand.schedules.next_run_at
                                      ELSE LEAST(strand.schedules.next_run_at,
                                                 EXCLUDED.next_run_at)
                                  END,
                is_active       = COALESCE(strand.schedules.next_run_at,
                                            EXCLUDED.next_run_at) IS NOT NULL,
                updated_at      = NOW()
            RETURNING id
            """,
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else {
            throw StrandError.database(underlying: ScheduleUpsertError())
        }
        var col = row.makeIterator()
        return try col.next()!.decode(UUID.self, context: .default)
    }

    package static func pauseSchedule(
        on client: PostgresClient,
        namespaceID: String,
        id: UUID,
        logger: Logger
    ) async throws {
        try await client.query(
            "UPDATE strand.schedules SET is_active = FALSE, updated_at = NOW() WHERE namespace_id = \(namespaceID) AND id = \(id)",
            logger: logger
        )
    }

    package static func resumeSchedule(
        on client: PostgresClient,
        namespaceID: String,
        id: UUID,
        logger: Logger
    ) async throws {
        try await client.query(
            "UPDATE strand.schedules SET is_active = TRUE, updated_at = NOW() WHERE namespace_id = \(namespaceID) AND id = \(id)",
            logger: logger
        )
    }

    package static func deleteSchedule(
        on client: PostgresClient,
        namespaceID: String,
        id: UUID,
        logger: Logger
    ) async throws {
        try await client.query(
            "DELETE FROM strand.schedules WHERE namespace_id = \(namespaceID) AND id = \(id)",
            logger: logger
        )
    }

    package static func listSchedules(
        on client: PostgresClient,
        namespaceID: String,
        queue: String?,
        logger: Logger
    ) async throws -> [ScheduleSummaryRow] {
        let stream = try await client.query(
            """
            SELECT id, queue, name, task_name, pattern, is_active,
                   starts_at, ends_at, next_run_at, last_run_at, last_task_id, run_count, accuracy, kind, created_at
            FROM strand.schedules
            WHERE namespace_id = \(namespaceID)
              AND (\(queue)::text IS NULL OR queue = \(queue))
            ORDER BY queue, name
            """,
            logger: logger
        )
        var rows: [ScheduleSummaryRow] = []
        for try await row in stream {
            var col = row.makeIterator()
            rows.append(
                ScheduleSummaryRow(
                    id: try col.next()!.decode(UUID.self, context: .default),
                    queue: try col.next()!.decode(String.self, context: .default),
                    name: try col.next()!.decode(String.self, context: .default),
                    taskName: try col.next()!.decode(String.self, context: .default),
                    patternBuffer: try col.next()!.decode(ByteBuffer.self, context: .default),
                    isActive: try col.next()!.decode(Bool.self, context: .default),
                    startsAt: try col.next()!.decode(Date?.self, context: .default),
                    endsAt: try col.next()!.decode(Date?.self, context: .default),
                    nextRunAt: try col.next()!.decode(Date?.self, context: .default),
                    lastRunAt: try col.next()!.decode(Date?.self, context: .default),
                    lastTaskID: try col.next()!.decode(UUID?.self, context: .default),
                    runCount: try col.next()!.decode(Int.self, context: .default),
                    accuracy: try col.next()!.decode(ScheduleAccuracy.self, context: .default),
                    kind: try col.next()!.decode(TaskKind.self, context: .default),
                    createdAt: try col.next()!.decode(Date.self, context: .default)
                )
            )
        }
        return rows
    }
}

private struct ScheduleUpsertError: Error, CustomStringConvertible {
    var description: String { "Schedule upsert returned no rows" }
}
