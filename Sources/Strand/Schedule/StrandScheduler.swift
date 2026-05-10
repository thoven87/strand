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
/// Use the static factory methods to build schedules fluently:
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
/// For schedules created at runtime (e.g. from an HTTP API), use
/// ``StrandClient/schedule(name:pattern:workflowType:input:queue:startsAt:endsAt:options:)``
/// directly — it is always a live database call.
public struct StrandSchedule: Sendable {

    // Type erasure: captures the generic W/A parameters so the schedule
    // can be stored in a homogeneous [StrandSchedule] array.
    // Private — callers only see the factory methods.
    private let _body: @Sendable (StrandClient) async throws -> Void

    private init(_ body: @escaping @Sendable (StrandClient) async throws -> Void) {
        self._body = body
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

    // MARK: ActivityDefinition

    /// Declares a recurring activity schedule.
    ///
    /// The activity fires directly — no wrapping workflow is created.
    public static func activity<A: ActivityDefinition>(
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

    public init(
        client: StrandClient,
        options: SchedulerOptions = .init(),
        schedules: [StrandSchedule] = []
    ) {
        self.client = client
        self.options = options
        self.schedules = schedules
    }

    public func run() async throws {
        let logger = client.logger
        logger.info("scheduler starting")
        defer { logger.info("scheduler stopped") }

        // Upsert all statically-declared schedules before the poll loop starts.
        // Any failure is propagated immediately — a bad schedule definition is
        // a programming error (wrong pattern, invalid input encoding, DB schema
        // mismatch) that should surface loudly at startup rather than silently
        // skipping a schedule and causing confusing production behaviour.
        for declaration in schedules {
            try await declaration._apply(to: client)
        }

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

    private func pollLoop() async throws {
        while true {
            // 1. Fire anything that is already due.
            do { try await fireSchedules() } catch {
                client.logger.info(
                    "scheduler fire error: \(String(reflecting: error))"
                )
            }

            // 2. Find the next scheduled fire time across all active schedules.
            let nextFireAt = try? await ScheduleQueries.nextScheduledFireTime(
                on: client.postgres,
                namespaceID: client.namespaceID,
                logger: client.logger
            )

            // 3. Sleep until next fire (but never longer than sleepCap so newly-added
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

    private func fireSchedules(now: Date = .now) async throws {
        let postgres = client.postgres
        let logger = client.logger

        let rows = try await ScheduleQueries.pollDueSchedules(
            on: postgres,
            namespaceID: client.namespaceID,
            now: now,
            logger: logger
        )

        for row in rows {
            do {
                try await fire(row, now: now)
            } catch {
                logger.error(
                    "failed to fire schedule '\(row.name)': \(String(reflecting: error))"
                )
            }
        }
    }

    private func fire(_ row: ScheduleRow, now: Date) async throws {
        let postgres = client.postgres
        let logger = client.logger

        let pattern = try JSON.decode(SchedulePattern.self, from: row.patternBuffer)

        // Advance from the SCHEDULED fire time, not the actual wall-clock time.
        // Using `now` here would accumulate drift: a scheduler that fires 30 s
        // late on every poll shifts every subsequent slot by 30 s. Using
        // `row.scheduledAt` keeps fire times pinned to the original cadence.
        var nextRunAt = try ScheduleCalculator.nextRunTime(
            for: pattern,
            after: row.scheduledAt,
            timezone: pattern.timezone
        )

        // Respect ends_at: disable the schedule once no more valid runs exist.
        if let endsAt = row.endsAt, let next = nextRunAt, next >= endsAt {
            nextRunAt = nil
        }

        // Compute partition time: the period boundary the task covers, with the
        // schedule's own offset stripped. Pass PT0M as the partition-offset config
        // so calculatePartitionTime truncates to the boundary (day/week/month/interval)
        // without any additional look-back.
        //
        // Examples:
        //   .daily(offset: "PT15M")   fires 00:15 → partitionTime 00:00
        //   .weekly(offset: "P6DT9H") fires Fri 09:00 → partitionTime Sun 00:00
        //   .interval(90 min)         fires 01:45 → partitionTime 01:30
        let partitionConfig = try PartitionOffsetConfig(offset: "PT0M")
        let partitionTime: Date?
        do {
            partitionTime = try ScheduleCalculator.calculatePartitionTime(
                executionTime: row.scheduledAt,
                schedule: pattern,
                partitionOffset: partitionConfig
            )
        } catch {
            logger.info(
                "schedule '\(row.name)': could not compute partition time — metadata will be nil",
                metadata: ["error": "\(error)", "schedule_id": "\(row.id)"]
            )
            partitionTime = nil
        }

        // Build scheduling metadata. Passed directly to enqueueTask as SchedulingMetadata?
        let schedulingMeta = SchedulingMetadata(
            executionTime: now,
            partitionTime: partitionTime,
            scheduleOffset: pattern.partitionOffset,  // nil when offset is PT0M/PT0H
            scheduleId: row.id.uuidString,
            scheduledBy: row.name
        )
        let headersBuf = row.headersBuffer  // user-provided headers only; no mutation needed

        // Idempotency key: schedule_id + scheduled fire time.
        // Safe across multiple scheduler instances and restarts.
        let idempotencyKey =
            "$schedule:\(row.id):\(row.scheduledAt.timeIntervalSince1970)"

        let enqueuedRow = try await Queries.enqueueTask(
            on: postgres,
            namespaceID: client.namespaceID,
            queue: row.queue,
            taskName: row.taskName,
            paramsBuffer: row.paramsBuffer,
            headersBuffer: headersBuf,
            schedulingMetadata: schedulingMeta,
            retryStrategyBuffer: row.retryStrategyBuffer,
            maxAttempts: row.maxAttempts,
            cancellationBuffer: row.cancellationBuffer,
            idempotencyKey: idempotencyKey,
            kind: row.kind,
            logger: logger
        )

        try await ScheduleQueries.markScheduleFired(
            on: postgres,
            namespaceID: client.namespaceID,
            id: row.id,
            // firedAt = wall-clock time the task was actually enqueued.
            // Shown in the dashboard as "Last run" so users see when the
            // schedule most recently did work, not when the slot was due.
            firedAt: now,
            // slotAt = the canonical slot boundary this fire covers.
            // Stored in last_slot_at and used by _schedule as the
            // catch-up base so interval arithmetic stays pinned to the
            // original cadence rather than drifting toward wall-clock time.
            slotAt: row.scheduledAt,
            nextRunAt: nextRunAt,
            lastTaskID: enqueuedRow.taskID,
            logger: logger
        )

        logger.debug(
            "schedule fired",
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
