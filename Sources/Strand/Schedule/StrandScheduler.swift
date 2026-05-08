import Logging
import NIOCore
public import ServiceLifecycle

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A `Service`-conformant scheduler that fires durable workflow tasks on a
/// configurable ``SchedulePattern`` (cron, interval, daily, weekly, monthly,
/// or one-shot).
///
/// Add `StrandScheduler` to a `ServiceGroup` alongside your `PostgresClient`
/// and `StrandWorker` instances:
///
/// ```swift
/// // Define a schedule
/// try await client.schedule(
///     name: "nightly-report",
///     pattern: .daily(offset: "PT9H"),   // 9 AM UTC every day
///     taskName: "generate-report",
///     params: ReportParams(kind: "daily")
/// )
///
/// // Run the scheduler as a Service
/// let scheduler = StrandScheduler(client: client)
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

    public init(client: StrandClient, options: SchedulerOptions = .init()) {
        self.client = client
        self.options = options
    }

    public func run() async throws {
        let logger = client.logger
        logger.info("scheduler starting")
        defer { logger.info("scheduler stopped") }

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

    private func fireSchedules() async throws {
        let postgres = client.postgres
        let logger = client.logger
        let now = Date.now

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
        // (PostgresCodable conformance handles the BYTEA encoding inside the query binding).
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
            "$schedule:\(row.id.uuidString):\(row.scheduledAt.timeIntervalSince1970)"

        _ = try await Queries.enqueueTask(
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
            firedAt: now,
            nextRunAt: nextRunAt,
            logger: logger
        )

        logger.debug(
            "schedule fired",
            metadata: [
                "strand.schedule_name": .string(row.name),
                "strand.schedule_id": .string(row.id.uuidString),
                "strand.task_name": .string(row.taskName),
                "strand.queue": .string(row.queue),
                "strand.scheduled_at": .string(row.scheduledAt.ISO8601Format()),
            ]
        )
    }
}
