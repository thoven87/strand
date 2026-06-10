import Logging
import NIOCore
public import ServiceLifecycle

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// MARK: - StrandSchedule

/// A static schedule definition passed to ``StrandScheduler`` at construction
/// time and upserted to the database when the scheduler starts.
///
/// ## Pattern-based schedules
///
/// Use the `pattern:` overloads for cron, interval, and built-in patterns:
///
/// ```swift
/// let scheduler = StrandScheduler(
///     client: client,
///     schedules: [
///         .workflow(
///             "daily-report",
///             pattern: .daily(offset: "PT9H"),
///             workflowType: DailyReportWorkflow.self,
///             input: ReportInput()
///         ),
///         .activity(
///             "hourly-cleanup",
///             pattern: .interval(.seconds(3600)),
///             activityType: CleanupActivity.self,
///             input: CleanupInput()
///         ),
///     ]
/// )
/// ```
///
/// ## Custom timetables
///
/// Use the `timetable:` overloads when the firing cadence can’t be expressed as
/// a fixed cron or interval — for example, to skip bank holidays or fire only
/// on quarter-end dates.  Implement ``StrandTimeTable`` and pass an instance:
///
/// ```swift
/// struct WorkingDayTimetable: StrandTimeTable {
///     func nextRunTime(after last: Date?, earliest: Date) async throws -> Date? {
///         // advance earliest to the next Mon–Fri non-holiday
///         var d = earliest
///         while isWeekendOrHoliday(d) { d = nextDay(d) }
///         return d
///     }
/// }
///
/// let scheduler = StrandScheduler(
///     client: client,
///     schedules: [
///         .workflow(
///             "daily-settlement",
///             timetable: WorkingDayTimetable(),
///             workflowType: SettlementWorkflow.self,
///             input: SettlementInput()
///         )
///     ]
/// )
/// ```
///
/// The timetable instance lives entirely in memory; only its `description`
/// string is persisted to the database.  Re-register the same implementation
/// on every scheduler restart.
///
/// For schedules created at runtime (e.g. from an HTTP API), use
/// ``StrandClient/schedule(name:pattern:workflowType:input:queue:startsAt:endsAt:options:)``
/// directly — it is always a live database call.
public struct StrandSchedule: Sendable {

    // Type erasure: captures the generic W/A parameters so the schedule
    // can be stored in a homogeneous [StrandSchedule] array.
    // Private — callers only see the factory methods.
    private let _body: @Sendable (StrandClient) async throws -> Void

    /// Carries the timetable instance for ``StrandScheduler`` to extract
    /// at init time.  Non-nil only for timetable-based schedules.
    /// `package` so StrandScheduler (same module) can read it without
    /// exposing the type to external callers.
    package let _timetableEntry: _TimetableEntry?

    package struct _TimetableEntry: Sendable {
        let name: String
        let table: any StrandTimeTable
    }

    private init(
        _ body: @escaping @Sendable (StrandClient) async throws -> Void,
        timetable: _TimetableEntry? = nil
    ) {
        self._body = body
        self._timetableEntry = timetable
    }

    /// Applies this schedule to the database using `client`.
    /// Called by ``StrandScheduler/run()`` at startup.
    func _apply(to client: StrandClient) async throws {
        try await _body(client)
    }

    // MARK: Workflow

    /// Declares a recurring workflow schedule.
    ///
    /// The schedule is upserted to the database when ``StrandScheduler/run()``
    /// is called.  On a name conflict the existing row is updated in place.
    public static func workflow<W: Workflow>(
        _ name: String,
        pattern: SchedulePattern,
        workflowType: W.Type = W.self,
        input: W.Input,
        queue: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        options: ScheduleOptions = .init()
    ) -> StrandSchedule {
        StrandSchedule { client in
            _ = try await client.schedule(
                name: name,
                pattern: pattern,
                workflowType: workflowType,
                input: input,
                queue: queue,
                startsAt: startsAt,
                endsAt: endsAt,
                options: options
            )
        }
    }

    // MARK: Workflow (timetable)

    /// Declares a recurring workflow schedule driven by a custom
    /// ``StrandTimeTable`` implementation.
    ///
    /// Use this overload when the firing times cannot be expressed as a cron
    /// expression, interval, or built-in pattern — for example to skip bank
    /// holidays, fire only on quarter-end business days, or follow an
    /// irregular event calendar.
    ///
    /// The timetable instance is held in memory by the scheduler and is
    /// **never serialised to the database**.  Only the `description` property
    /// is stored (shown in the Loom schedule list).  Re-register the same
    /// timetable implementation on every scheduler restart.
    ///
    /// ```swift
    /// .workflow(
    ///     "settlement",
    ///     timetable: UKWorkingDayTimetable(year: 2026),
    ///     workflowType: SettlementWorkflow.self,
    ///     input: SettlementInput()
    /// )
    /// ```
    public static func workflow<W: Workflow>(
        _ name: String,
        timetable: some StrandTimeTable,
        workflowType: W.Type = W.self,
        input: W.Input,
        queue: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        options: ScheduleOptions = .init()
    ) -> StrandSchedule {
        let tt = timetable  // capture value
        return StrandSchedule(
            { client in
                // The client upserts the schedule row with next_run_at = nil.
                // StrandScheduler.seedTimetableSchedules() seeds next_run_at
                // (and sets is_active = true) after all _apply calls complete.
                _ = try await client.schedule(
                    name: name,
                    pattern: .timetable(description: tt.description),
                    workflowType: workflowType,
                    input: input,
                    queue: queue,
                    startsAt: startsAt,
                    endsAt: endsAt,
                    options: options
                )
            },
            timetable: _TimetableEntry(name: name, table: tt)
        )
    }

    // MARK: Activity (timetable)

    /// Declares a recurring activity schedule driven by a custom timetable.
    public static func activity<A: Activity>(
        _ name: String,
        timetable: some StrandTimeTable,
        activityType: A.Type,
        input: A.Input,
        queue: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        options: ScheduleOptions = .init()
    ) -> StrandSchedule {
        let tt = timetable
        return StrandSchedule(
            { client in
                _ = try await client.schedule(
                    name: name,
                    pattern: .timetable(description: tt.description),
                    activityType: activityType,
                    input: input,
                    queue: queue,
                    startsAt: startsAt,
                    endsAt: endsAt,
                    options: options
                )
            },
            timetable: _TimetableEntry(name: name, table: tt)
        )
    }

    // MARK: Activity (pattern)

    /// Declares a recurring activity schedule.
    ///
    /// The activity fires directly — no wrapping workflow is created.
    public static func activity<A: Activity>(
        _ name: String,
        pattern: SchedulePattern,
        activityType: A.Type,
        input: A.Input,
        queue: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        options: ScheduleOptions = .init()
    ) -> StrandSchedule {
        StrandSchedule { client in
            _ = try await client.schedule(
                name: name,
                pattern: pattern,
                activityType: activityType,
                input: input,
                queue: queue,
                startsAt: startsAt,
                endsAt: endsAt,
                options: options
            )
        }
    }
}

/// A `Service`-conformant scheduler that fires durable workflow tasks on a
/// configurable ``SchedulePattern`` (cron, interval, daily, weekly, monthly,
/// or one-shot).
///
/// Add `StrandScheduler` to a `ServiceGroup` alongside your `PostgresClient`
/// and `StrandWorker` instances:
///
/// ```swift
/// let scheduler = StrandScheduler(
///     client: client,
///     schedules: [
///         .workflow(
///             "nightly-report",
///             pattern: .daily(offset: "PT9H"),
///             workflowType: NightlyReportWorkflow.self,
///             input: ReportInput()
///         )
///     ]
/// )
/// ```
///
/// When a schedule fires, Strand injects these headers into the task:
///
/// | Header | Value |
/// |---|---|
/// | `$strand:schedule_id` | Schedule UUID |
/// | `$strand:schedule_name` | Schedule name |
/// | `$strand:execution_time` | ISO 8601 wall-clock time of the fire |
/// | `$strand:scheduled_at` | ISO 8601 time the schedule was due |
///
/// `$strand:scheduled_at` carries the slot the run represents (e.g. the
/// 09:00 boundary), while `$strand:execution_time` is the actual wall-clock
/// fire time. Activities can use `context.schedulingMetadata` to access both.
public struct StrandScheduler: Service {
    private let client: StrandClient
    private let options: SchedulerOptions
    /// Static schedules upserted to the database at startup.
    private let schedules: [StrandSchedule]
    /// In-memory timetable instances keyed by schedule name.
    /// Populated from ``StrandSchedule/workflow(_:timetable:...)`` entries.
    private let timetables: [String: any StrandTimeTable]

    public init(
        client: StrandClient,
        options: SchedulerOptions = .init(),
        schedules: [StrandSchedule] = []
    ) {
        self.client = client
        self.options = options
        self.schedules = schedules
        // Extract every timetable entry so fire() can call nextRunTime without
        // hitting the database.  This runs once at init, not on every poll.
        var tt: [String: any StrandTimeTable] = [:]
        for s in schedules {
            if let entry = s._timetableEntry {
                tt[entry.name] = entry.table
            }
        }
        self.timetables = tt
    }

    public func run() async throws {
        let logger = client.logger
        logger.info("scheduler starting")
        defer { logger.info("scheduler stopped") }

        // Ensure the namespace exists before any schedule upsert. Workers call
        // registerNamespace in their own run(), but the scheduler starts
        // concurrently and may fire upsertSchedule before any worker has had a
        // chance to register the namespace — causing a FK violation on
        // strand.schedules.namespace_id. Idempotent: ON CONFLICT DO NOTHING.
        try await client.registerNamespace()

        // Upsert all statically-declared schedules before the poll loop starts.
        // Any failure is propagated immediately — a bad schedule definition is
        // a programming error (wrong pattern, invalid input encoding, DB schema
        // mismatch) that should surface loudly at startup rather than silently
        // skipping a schedule and causing confusing production behaviour.
        for declaration in schedules {
            try await declaration._apply(to: client)
        }

        // Seed next_run_at for timetable schedules whose rows were just upserted
        // with next_run_at = null (the client layer doesn’t compute the first slot
        // — only the scheduler has the in-memory StrandTimeTable instances).
        //
        // This is the guarantee that timetable schedules actually run:
        //   • First registration  → seeds next_run_at + sets is_active = true.
        //   • Restart             → no-op (UPDATE WHERE next_run_at IS NULL;
        //                           the existing value from fire() is preserved).
        await seedTimetableSchedules()

        let (stream, cont) = AsyncStream.makeStream(of: Void.self)

        try await withTaskCancellationOrGracefulShutdownHandler {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.pollLoop() }
                    // Unblock immediately on shutdown — scheduler is stateless.
                    group.addTask { await stream.first { _ in true } }
                    try await group.next()
                    group.cancelAll()
                }
            } catch is CancellationError {}
        } onCancelOrGracefulShutdown: {
            logger.info("scheduler shutting down")
            cont.finish()
        }
    }

    // MARK: - Private

    /// Seeds `next_run_at` for every registered timetable schedule that was
    /// just upserted with `next_run_at = nil`.
    ///
    /// `activateTimetableSchedule` uses `WHERE next_run_at IS NULL` so this is
    /// a no-op on restarts — the value written by ``fire(_:now:)`` after the
    /// last execution is preserved unchanged.
    private func seedTimetableSchedules() async {
        let now = Date.now
        for (name, tt) in timetables {
            let earliest = now
            guard let nextRun = tt.nextRunTime(after: nil, earliest: earliest) else {
                client.logger.warning(
                    "timetable schedule '\(name)' returned nil for initial nextRunTime — schedule will not fire"
                )
                continue
            }
            do {
                try await ScheduleQueries.activateTimetableSchedule(
                    on: client.postgres,
                    namespaceID: client.namespaceID,
                    name: name,
                    queue: client.queueName,
                    nextRunAt: nextRun,
                    logger: client.logger
                )
            } catch {
                client.logger.warning(
                    "failed to seed next_run_at for timetable schedule '\(name)': \(error)"
                )
            }
        }
    }

    private func pollLoop() async throws {
        while true {
            // 1. Fire anything that is already due.
            do { try await fireSchedules() } catch {
                client.logger.info(
                    "scheduler fire error:",
                    metadata: [
                        "error": " \(String(reflecting: error))"
                    ]
                )
            }

            // 2. Process pending backfill slots.
            do { try await processBackfills() } catch {
                client.logger.error(
                    "backfill processing error:",
                    metadata: [
                        "error": " \(String(reflecting: error))"
                    ]
                )
            }

            // 3. Find the next scheduled fire time across all active schedules.
            let nextFireAt = try? await ScheduleQueries.nextScheduledFireTime(
                on: client.postgres,
                namespaceID: client.namespaceID,
                logger: client.logger
            )

            // 4. Sleep until next fire (but never longer than sleepCap so newly-added
            //    schedules are detected promptly).
            let sleepFor: Duration
            let now = Date.now
            if let nextFireAt {
                let secondsUntilFire = nextFireAt.timeIntervalSince(now)
                if secondsUntilFire <= 0 {
                    // Already due — loop immediately without sleeping.
                    continue
                }
                // Sleep the minimum of (time until next fire) and sleepCap.
                let capSeconds =
                    options.sleepCap.components.seconds > 0
                    ? Double(options.sleepCap.components.seconds) : 60
                let cappedSeconds = min(secondsUntilFire, capSeconds)
                sleepFor = .seconds(cappedSeconds)
            } else {
                sleepFor = options.sleepCap
            }

            // cancelWhenGracefulShutdown exits early on both task cancellation
            // and graceful shutdown.
            try await cancelWhenGracefulShutdown {
                try await Task.sleep(for: sleepFor)
            }
        }
    }

    // MARK: - Backfill processing

    /// Drives all RUNNING backfills: for each backfill, counts in-flight tasks,
    /// computes how many new slots can be fired (concurrency - active), and
    /// enqueues them. Advances the cursor and marks backfills complete when the
    /// range is exhausted.
    ///
    /// This runs in the scheduler's poll loop — zero worker task-queue slots
    /// are consumed for orchestration. The actual workflow/activity executions
    /// use worker slots as normal.
    private func processBackfills(now: Date = .now) async throws {
        let backfills = try await BackfillQueries.listRunning(
            on: client.postgres,
            namespaceID: client.namespaceID,
            logger: client.logger
        )
        guard !backfills.isEmpty else { return }

        for backfill in backfills {
            do {
                try await processBackfill(backfill, now: now)
            } catch {
                client.logger.error(
                    "backfill error",
                    metadata: [
                        "backfill_id": .stringConvertible(backfill.id),
                        "error": " \(String(reflecting: error))",
                    ]
                )
            }
        }
    }

    private func processBackfill(_ backfill: BackfillQueries.BackfillRow, now: Date) async throws {
        let logger = client.logger
        let postgres = client.postgres

        // How many slots from this backfill are currently in-flight?
        let active = try await BackfillQueries.countActiveTasks(
            on: postgres,
            backfillID: backfill.id,
            namespaceID: backfill.namespaceID,
            logger: logger
        )
        let slots = backfill.concurrency - active
        guard slots > 0 else { return }

        // Decode the stored SchedulePattern to compute next slot times.
        let pattern = try JSON.decode(SchedulePattern.self, from: backfill.schedulePatternBuffer)

        var cursor = backfill.nextSlotTime
        var fired = 0

        while fired < slots {
            // Compute the next slot strictly after the cursor.
            guard
                let slotAt = try ScheduleCalculator.nextRunTime(
                    for: pattern,
                    after: cursor,
                    timezone: pattern.timezone
                ),
                slotAt < backfill.rangeEnd
            else {
                // Range exhausted.
                // Flush any slots fired in this batch BEFORE marking complete.
                // Without this, completedSlots is never incremented for the
                // last partial batch and nextSlotTime is left at the pre-batch
                // value — producing "COMPLETED" with an understated slot count.
                if fired > 0 {
                    try await BackfillQueries.advanceCursor(
                        on: postgres,
                        backfillID: backfill.id,
                        namespaceID: backfill.namespaceID,
                        nextSlotTime: cursor,
                        firedCount: fired,
                        logger: logger
                    )
                }
                try await BackfillQueries.markCompleted(
                    on: postgres,
                    backfillID: backfill.id,
                    namespaceID: backfill.namespaceID,
                    logger: logger
                )
                logger.debug(
                    "backfill '\(backfill.id)' completed — \(backfill.completedSlots + fired) slots fired"
                )
                return
            }

            // Compute scheduling metadata (same structure as StrandScheduler.fire).
            var partitionTime: Date? = nil
            if let times = try? ScheduleCalculator.calculateExecutionTimes(
                for: pattern,
                executingAt: slotAt,
                timezone: pattern.timezone
            ) {
                partitionTime = times.scheduledTime
            }
            let schedulingMeta = SchedulingMetadata(
                executionTime: now,
                partitionTime: partitionTime ?? slotAt,
                scheduleOffset: pattern.partitionOffset,
                backfillId: backfill.id
            )

            // When allowOverwrite=false, use a key that matches what StrandScheduler.fire()
            // would produce for the same slot so slots already run by the schedule (or a
            // previous backfill for the same schedule) are deduplicated via ON CONFLICT.
            // Standalone backfills (no scheduleId) use a backfill-scoped key to prevent
            // double-firing within the same backfill on retries.
            let idKey: String?
            if backfill.allowOverwrite {
                idKey = nil  // no dedup — always create a fresh task
            } else if let scheduleId = backfill.scheduleId {
                idKey = "$schedule:\(scheduleId):\(slotAt.timeIntervalSince1970)"
            } else {
                idKey = "$backfill:\(backfill.id):\(slotAt.timeIntervalSince1970)"
            }

            _ = try await Queries.enqueueTask(
                on: postgres,
                namespaceID: backfill.namespaceID,
                queue: backfill.queue,
                taskName: backfill.taskName,
                paramsBuffer: backfill.paramsBuffer,
                headersBuffer: backfill.headersBuffer,
                schedulingMetadata: schedulingMeta,
                retryStrategyBuffer: backfill.retryStrategyBuffer,
                maxAttempts: backfill.maxAttempts,
                cancellationBuffer: nil,
                idempotencyKey: idKey,
                kind: backfill.taskKind,
                backfillID: backfill.id,
                scheduleID: backfill.scheduleId,
                logger: logger
            )

            cursor = slotAt
            fired += 1
        }

        if fired > 0 {
            try await BackfillQueries.advanceCursor(
                on: postgres,
                backfillID: backfill.id,
                namespaceID: backfill.namespaceID,
                nextSlotTime: cursor,
                firedCount: fired,
                logger: logger
            )
            logger.debug(
                "backfill '\(backfill.id)': fired \(fired) slots, cursor=\(cursor.ISO8601Format())"
            )
        }
    }

    private func fireSchedules(now: Date = .now) async throws {
        let rows = try await ScheduleQueries.pollDueSchedules(
            on: client.postgres,
            namespaceID: client.namespaceID,
            now: now,
            limit: options.pollLimit,
            logger: client.logger
        )
        guard !rows.isEmpty else { return }

        // Fire all due schedules concurrently — each fire() is independently
        // idempotent so parallel execution is safe.  Errors are isolated per
        // schedule: one failure does not cancel the others.
        await withTaskGroup(of: Void.self) { group in
            for row in rows {
                group.addTask { [self] in
                    do {
                        try await self.fire(row, now: now)
                    } catch {
                        self.client.logger.error(
                            "failed to fire schedule",
                            metadata: [
                                "schedule_name": .stringConvertible(row.name),
                                "error": " \(String(reflecting: error))",
                            ]
                        )
                    }
                }
            }
        }
    }

    private func fire(_ row: ScheduleRow, now: Date) async throws {
        let postgres = client.postgres
        let logger = client.logger
        let pattern = try JSON.decode(SchedulePattern.self, from: row.patternBuffer)

        // Resolve the in-memory timetable for custom-schedule rows.
        // For pattern-based schedules this is always nil.
        let timetable: (any StrandTimeTable)? = timetables[row.name]

        // ── Build the list of slots to fire ──────────────────────────────────────
        // .latest (default): only the single slot in row.scheduledAt.
        // .all:              every overdue slot from row.scheduledAt up to now.
        // .last(n):          the last n overdue slots (oldest-first order).
        //
        // For .all and .last(n), _schedule set next_run_at to the OLDEST overdue
        // slot.  We iterate forward here so a single fire() call catches up the
        // full backlog in one pass instead of requiring one poll cycle per slot.
        // ── Helper: next slot time, delegating to timetable when present ───────────
        // Synchronous: nextRunTime must not perform I/O — data is pre-loaded or
        // maintained in a background-refreshed cache by the timetable itself.
        func nextSlotTime(after cursor: Date) -> Date? {
            if let tt = timetable {
                let earliest = cursor.addingTimeInterval(1)  // strictly after cursor
                return tt.nextRunTime(after: cursor, earliest: earliest)
            }
            return try? ScheduleCalculator.nextRunTime(
                for: pattern,
                after: cursor,
                timezone: pattern.timezone
            )
        }

        let slotsToFire: [Date]
        switch row.accuracy {
        case .latest:
            slotsToFire = [row.scheduledAt]

        case .all:
            // Cap at options.maxCatchupSlots per fire() invocation.  If the
            // backlog is larger, markScheduleFired advances next_run_at to the
            // slot after the last one fired and the remainder is handled on the
            // next poll cycle — no slots are skipped, just spread across polls.
            var slots: [Date] = []
            var cursor = row.scheduledAt
            while cursor <= now && slots.count < options.maxCatchupSlots {
                slots.append(cursor)
                guard let next = nextSlotTime(after: cursor) else { break }
                cursor = next
            }
            slotsToFire = slots

        case .last(let n) where n > 0:
            var slots: [Date] = []
            var cursor = row.scheduledAt
            while cursor <= now && slots.count < options.maxCatchupSlots {
                slots.append(cursor)
                guard let next = nextSlotTime(after: cursor) else { break }
                cursor = next
            }
            // Fire in chronological order, keeping only the last n.
            slotsToFire = Array(slots.suffix(n))

        default:
            slotsToFire = [row.scheduledAt]
        }

        guard !slotsToFire.isEmpty else { return }

        // ── Enqueue one task per slot ─────────────────────────────────────────────
        // Idempotency keys are slot-specific ("$schedule:<id>:<epochSecs>") so
        // concurrent scheduler instances that both observe the same slot produce
        // at most one task row regardless of how many enqueue attempts are made.
        //
        // Crash recovery: if the process crashes after enqueueTask but before
        // markScheduleFired, the next poll re-runs enqueueTask with the same key
        // (ON CONFLICT DO NOTHING → no-op) and retries markScheduleFired.
        let partitionConfig = try PartitionOffsetConfig(offset: "PT0M")
        var lastTaskID = UUID()
        for slotAt in slotsToFire {
            let partitionTime: Date?
            do {
                partitionTime = try ScheduleCalculator.calculatePartitionTime(
                    executionTime: slotAt,
                    schedule: pattern,
                    partitionOffset: partitionConfig
                )
            } catch {
                logger.info(
                    "schedule '\(row.name)': could not compute partition time for slot \(slotAt.ISO8601Format())",
                    metadata: ["error": "\(error)", "strand.schedule_id": "\(row.id)"]
                )
                partitionTime = nil
            }

            let schedulingMeta = SchedulingMetadata(
                executionTime: now,
                partitionTime: partitionTime,
                scheduleOffset: pattern.partitionOffset,
                scheduleId: row.id.uuidString,
                scheduledBy: row.name
            )

            let idempotencyKey = "$schedule:\(row.id):\(slotAt.timeIntervalSince1970)"
            let enqueued = try await Queries.enqueueTask(
                on: postgres,
                namespaceID: client.namespaceID,
                queue: row.queue,
                taskName: row.taskName,
                paramsBuffer: row.paramsBuffer,
                headersBuffer: row.headersBuffer,
                schedulingMetadata: schedulingMeta,
                retryStrategyBuffer: row.retryStrategyBuffer,
                maxAttempts: row.maxAttempts,
                cancellationBuffer: row.cancellationBuffer,
                idempotencyKey: idempotencyKey,
                kind: row.kind,
                scheduleID: row.id,
                logger: logger
            )
            lastTaskID = enqueued.taskID
        }

        // ── Advance next_run_at past the last slot fired ──────────────────────────
        let lastSlot = slotsToFire.last!
        var nextRunAt: Date?
        if let tt = timetable {
            // For timetable schedules the earliest permissible next fire time is
            // now (or startsAt if it's in the future) but always after lastSlot.
            let earliest = max(now, lastSlot.addingTimeInterval(1))
            let proposed = tt.nextRunTime(after: lastSlot, earliest: earliest)
            if let proposed, proposed < earliest {
                logger.warning(
                    "timetable '\(row.name)' returned \(proposed) which is before earliest \(earliest) — discarding"
                )
                nextRunAt = nil
            } else {
                nextRunAt = proposed
            }
        } else {
            nextRunAt = try ScheduleCalculator.nextRunTime(
                for: pattern,
                after: lastSlot,
                timezone: pattern.timezone
            )
        }
        if let endsAt = row.endsAt, let next = nextRunAt, next >= endsAt {
            nextRunAt = nil
        }

        // CAS guard: markScheduleFired only advances next_run_at when it still
        // equals row.scheduledAt.  A concurrent instance that already fired this
        // slot will have changed next_run_at — we detect that and return early.
        let won = try await ScheduleQueries.markScheduleFired(
            on: postgres,
            namespaceID: client.namespaceID,
            id: row.id,
            scheduledAt: row.scheduledAt,
            firedAt: now,
            slotAt: lastSlot,
            nextRunAt: nextRunAt,
            lastTaskID: lastTaskID,
            logger: logger
        )

        guard won else {
            logger.info(
                "schedule '\(row.name)' already advanced by another instance — skipping",
                metadata: ["strand.schedule_id": .stringConvertible(row.id)]
            )
            return
        }

        let slotCount = slotsToFire.count
        logger.debug(
            slotCount == 1
                ? "schedule fired"
                : "schedule fired (\(slotCount) catch-up slots)",
            metadata: [
                "strand.schedule_name": .string(row.name),
                "strand.schedule_id": .stringConvertible(row.id),
                "strand.task_name": .string(row.taskName),
                "strand.queue": .string(row.queue),
                "strand.scheduled_at": .string(row.scheduledAt.ISO8601Format()),
            ]
        )
    }
}
