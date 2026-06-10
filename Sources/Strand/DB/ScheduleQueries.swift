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
    package let id: UUID
    package let queue: String
    package let name: String
    package let taskName: String
    package let patternBuffer: ByteBuffer
    package let isActive: Bool
    package let startsAt: Date?
    package let endsAt: Date?
    package let nextRunAt: Date?
    package let lastRunAt: Date?
    package let lastTaskID: UUID?
    package let runCount: Int
    package let accuracy: ScheduleAccuracy
    package let kind: TaskKind  // 'WORKFLOW' or 'ACTIVITY'
    package let createdAt: Date
}

/// A task row fired by a specific schedule, returned by ``ScheduleQueries/listScheduleRuns``.
package struct ScheduleRunRow: Sendable {
    package let id: UUID
    package let state: String
    package let attempt: Int
    package let createdAt: Date
    package let completedAt: Date?
    /// Canonical slot time from `scheduling_metadata.partitionTime`.
    /// `nil` for tasks enqueued before this field was added or without scheduling metadata.
    /// Use this (not `createdAt`) to place runs in a partition grid: backfill tasks
    /// are created at wall-clock time but their partition is in the past.
    package let partitionTime: Date?
}

/// Full schedule row returned by ``ScheduleQueries/getSchedule(on:namespaceID:id:logger:)``.
///
/// Carries every column: the display fields shared with ``ScheduleSummaryRow``
/// **plus** the payload buffers (`params`, `headers`, `retry_strategy`,
/// `cancellation`) needed for backfill and run-for-partition operations.
///
/// ``ScheduleSummaryRow`` still exists for **list queries** — loading payload
/// buffers for up to 200 rows just to render names and timestamps would be
/// wasteful. Single-ID lookups have no such concern, so they always fetch
/// everything in one query rather than requiring a second round-trip.
package struct ScheduleFullRow: Sendable {
    package let id: UUID
    package let queue: String
    package let name: String
    package let taskName: String
    package let patternBuffer: ByteBuffer
    package let isActive: Bool
    package let startsAt: Date?
    package let endsAt: Date?
    package let nextRunAt: Date?
    package let lastRunAt: Date?
    package let lastTaskID: UUID?
    package let runCount: Int
    package let accuracy: ScheduleAccuracy
    package let kind: TaskKind
    package let createdAt: Date
    package let paramsBuffer: ByteBuffer
    package let headersBuffer: ByteBuffer?
    package let retryStrategyBuffer: ByteBuffer?
    package let maxAttempts: Int?
    package let cancellationBuffer: ByteBuffer?
}

// MARK: - Queries

package enum ScheduleQueries {

    // MARK: Scheduler operations

    /// Returns all schedules with `next_run_at <= now`.
    ///
    /// `FOR UPDATE SKIP LOCKED` is a best-effort hint that reduces wasted work
    /// when multiple `StrandScheduler` instances run concurrently: rows being
    /// processed by another instance are skipped in this poll.  The real
    /// double-fire guard is the CAS in `markScheduleFired` (`AND next_run_at = $slot`),
    /// which ensures only one instance advances the schedule regardless of
    /// how many instances observe the same row here.
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
    ///
    /// Uses a CAS guard (`AND next_run_at = \(scheduledAt)`) so concurrent
    /// `StrandScheduler` instances that both observe the same slot are safe:
    /// only one UPDATE lands, only one `run_count` increment occurs, and the
    /// loser detects the collision via the `false` return value.
    ///
    /// Crash recovery: if the process crashes after `enqueueTask` but before
    /// this call, the next poll re-runs `enqueueTask` (idempotency key → no-op)
    /// and retries this UPDATE against the still-unchanged `next_run_at`.
    ///
    /// - Parameters:
    ///   - scheduledAt: The slot being claimed; used as the CAS guard.
    ///   - firedAt: Actual wall-clock time the scheduler enqueued the task.
    ///     Stored in `last_run_at` and shown in the dashboard as "Last run".
    ///   - slotAt: The scheduled slot boundary this fire covers (e.g. 16:29 UTC).
    ///     Stored in `last_slot_at` and used by `_schedule` as the catch-up base
    ///     so interval arithmetic stays pinned to the original cadence.
    /// - Returns: `true` when this instance won the CAS race and advanced the
    ///   schedule; `false` when another instance already fired this slot.
    package static func markScheduleFired(
        on client: PostgresClient,
        namespaceID: String,
        id: UUID,
        scheduledAt: Date,
        firedAt: Date,
        slotAt: Date,
        nextRunAt: Date?,
        lastTaskID: UUID,
        logger: Logger
    ) async throws -> Bool {
        let stream = try await client.query(
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
              AND id           = \(id)
              AND next_run_at  = \(scheduledAt)
            RETURNING id
            """,
            logger: logger
        )
        return try await stream.first(where: { _ in true }) != nil
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
                -- Preserve an existing deadline when the caller omits endsAt:.
                -- A bare re-registration (e.g. on scheduler restart) defaults
                -- endsAt to nil, which would otherwise silently clear the window.
                -- Use COALESCE so the deadline can only be set or extended,
                -- never cleared by accident — use deleteSchedule + re-register
                -- to intentionally remove a deadline.
                ends_at         = COALESCE(EXCLUDED.ends_at, strand.schedules.ends_at),
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

    /// Seeds `next_run_at` and activates a freshly-registered timetable schedule.
    ///
    /// Called by ``StrandScheduler/seedTimetableSchedules()`` after all static
    /// schedule declarations have been applied.  The UPDATE is conditional on
    /// `next_run_at IS NULL` so it is a no-op on restarts (existing values are
    /// preserved) and only runs on first registration.
    ///
    /// - Parameters:
    ///   - name:      Schedule name (unique within namespace + queue).
    ///   - queue:     Queue the schedule is registered on.
    ///   - nextRunAt: First fire time computed by the ``StrandTimeTable`` instance.
    package static func activateTimetableSchedule(
        on client: PostgresClient,
        namespaceID: String,
        name: String,
        queue: String,
        nextRunAt: Date,
        logger: Logger
    ) async throws {
        try await client.query(
            """
            UPDATE strand.schedules
            SET next_run_at = \(nextRunAt),
                is_active   = TRUE,
                updated_at  = NOW()
            WHERE namespace_id = \(namespaceID)
              AND queue        = \(queue)
              AND name         = \(name)
              AND next_run_at  IS NULL
            """,
            logger: logger
        )
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

    /// Reactivates a paused schedule.
    ///
    /// - Parameter recomputeFrom: When provided, `next_run_at` is advanced to
    ///   this date before reactivation, skipping any slots that fell due while
    ///   the schedule was paused.  Pass `Date.now` to resume from the present
    ///   moment.  When `nil` the existing `next_run_at` is preserved — for
    ///   `accuracy: .all` schedules this fires every missed slot since the pause.
    package static func resumeSchedule(
        on client: PostgresClient,
        namespaceID: String,
        id: UUID,
        recomputeFrom: Date? = nil,
        logger: Logger
    ) async throws {
        try await client.query(
            """
            UPDATE strand.schedules
            SET is_active   = TRUE,
                next_run_at = COALESCE(\(recomputeFrom), next_run_at),
                updated_at  = NOW()
            WHERE namespace_id = \(namespaceID)
              AND id = \(id)
            """,
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

    /// Fetches a single schedule by primary key.
    ///
    /// Returns `nil` when not found. Returns a ``ScheduleFullRow`` containing
    /// both the display fields (same as list queries) and the payload buffers
    /// needed for backfill and run-for-partition operations — one query covers
    /// all callers instead of requiring a separate `getScheduleDetail` call.
    package static func getSchedule(
        on client: PostgresClient,
        namespaceID: String,
        id: UUID,
        logger: Logger
    ) async throws -> ScheduleFullRow? {
        let stream = try await client.query(
            """
            SELECT id, queue, name, task_name, pattern, is_active,
                   starts_at, ends_at, next_run_at, last_run_at, last_task_id,
                   run_count, accuracy, kind, created_at,
                   params, headers, retry_strategy, max_attempts, cancellation
            FROM strand.schedules
            WHERE namespace_id = \(namespaceID)
              AND id           = \(id)
            LIMIT 1
            """,
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else { return nil }
        var col = row.makeIterator()
        return ScheduleFullRow(
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
            createdAt: try col.next()!.decode(Date.self, context: .default),
            paramsBuffer: try col.next()!.decode(ByteBuffer.self, context: .default),
            headersBuffer: try col.next()!.decode(ByteBuffer?.self, context: .default),
            retryStrategyBuffer: try col.next()!.decode(ByteBuffer?.self, context: .default),
            maxAttempts: try col.next()!.decode(Int?.self, context: .default),
            cancellationBuffer: try col.next()!.decode(ByteBuffer?.self, context: .default)
        )
    }

    /// Lists schedules with keyset pagination ordered by `(queue ASC, name ASC)`.
    ///
    /// Pass `afterQueue` + `afterName` (the last row's values from the previous page)
    /// to advance to the next page.  When both are `nil` the first page is returned.
    ///
    /// - Parameters:
    ///   - limit: Maximum rows to return. Defaults to 200; cap at a reasonable value in callers.
    ///   - afterQueue: Keyset cursor — `queue` value of the last row on the previous page.
    ///   - afterName:  Keyset cursor — `name` value of the last row on the previous page.
    package static func listSchedules(
        on client: PostgresClient,
        namespaceID: String,
        queue: String?,
        limit: Int = 200,
        afterQueue: String? = nil,
        afterName: String? = nil,
        logger: Logger
    ) async throws -> [ScheduleSummaryRow] {
        let stream = try await client.query(
            """
            SELECT id, queue, name, task_name, pattern, is_active,
                   starts_at, ends_at, next_run_at, last_run_at, last_task_id, run_count, accuracy, kind, created_at
            FROM strand.schedules
            WHERE namespace_id = \(namespaceID)
              AND (\(queue)::text IS NULL OR queue = \(queue))
              AND (
                \(afterQueue)::text IS NULL
                OR queue > \(afterQueue)
                OR (queue = \(afterQueue) AND name > \(afterName))
              )
            ORDER BY queue ASC, name ASC
            LIMIT \(limit)
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

    /// Returns tasks fired by the given schedule, newest first.
    ///
    /// Tasks are identified by their idempotency key prefix
    /// `"$schedule:<scheduleID>:"`.  The `limit` is capped at 100.
    package static func listScheduleRuns(
        on client: PostgresClient,
        namespaceID: String,
        scheduleID: UUID,
        limit: Int,
        logger: Logger
    ) async throws -> [ScheduleRunRow] {
        let stream = try await client.query(
            """
            SELECT id, state, attempt, created_at, completed_at, scheduling_metadata
            FROM strand.tasks
            WHERE namespace_id = \(namespaceID)
              AND schedule_id  = \(scheduleID)
            ORDER BY created_at DESC
            LIMIT \(min(limit, 100))
            """,
            logger: logger
        )
        var rows: [ScheduleRunRow] = []
        for try await row in stream {
            var col = row.makeIterator()
            let id = try col.next()!.decode(UUID.self, context: .default)
            let state = try col.next()!.decode(String.self, context: .default)
            let attempt = try col.next()!.decode(Int.self, context: .default)
            let createdAt = try col.next()!.decode(Date.self, context: .default)
            let completedAt = try col.next()!.decode(Date?.self, context: .default)
            let partitionTime = try col.next()!.decode(SchedulingMetadata?.self, context: .default)?.partitionTime
            rows.append(
                ScheduleRunRow(
                    id: id,
                    state: state,
                    attempt: attempt,
                    createdAt: createdAt,
                    completedAt: completedAt,
                    partitionTime: partitionTime
                )
            )
        }
        return rows
    }
}

private struct ScheduleUpsertError: Error, CustomStringConvertible {
    var description: String { "Schedule upsert returned no rows" }
}
