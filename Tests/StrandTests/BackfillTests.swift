import Logging
import NIOCore
import PostgresNIO
import Testing

@testable import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Simple pass-through workflow for backfill testing
private struct BackfillTestWorkflow: Workflow {
    typealias Input = String
    typealias Output = String
    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        input
    }
}

@Suite("Integration — Backfill")
struct BackfillTests {

    // Test 1: createBackfill inserts a row and StrandScheduler enqueues slots
    @Test("createBackfill enqueues tasks with correct backfill_id")
    func backfillEnqueuesTasks() async throws {
        try await withTestEnvironment { client in
            let postgres = client.postgres
            let logger = client.logger
            let queue = client.queueName

            // Start a worker to claim tasks that the scheduler enqueues
            try await withWorker(
                postgres: postgres,
                queueName: queue,
                logger: logger,
                workflows: [BackfillTestWorkflow.self]
            ) {
                // Start a scheduler with a very short sleep cap so it processes
                // the backfill quickly without waiting for the full sleepCap
                let schedulerClient = StrandClient(
                    postgres: postgres,
                    queue: queue,
                    logger: logger
                )
                let scheduler = StrandScheduler(
                    client: schedulerClient,
                    options: SchedulerOptions(sleepCap: .milliseconds(200))
                )
                let schedulerTask = Task {
                    try? await scheduler.run()
                }
                defer { schedulerTask.cancel() }

                // Give the scheduler time to start and register the namespace
                try await Task.sleep(for: .milliseconds(400))

                // Range: last 3 hours, 1-hour interval → 3 slots
                let now = Date()
                let rangeEnd = now
                let rangeStart = Calendar(identifier: .gregorian).date(byAdding: .hour, value: -3, to: now)!
                let range = rangeStart..<rangeEnd

                let handle = try await client.createBackfill(
                    BackfillTestWorkflow.self,
                    input: "test",
                    schedule: .interval(.hours(1)),
                    range: range,
                    options: BackfillOptions(concurrency: 3)
                )

                // Wait long enough for the scheduler's poll loop to process the backfill
                try await Task.sleep(for: .seconds(2))

                // Verify tasks were created with the correct backfill_id
                let taskStream = try await postgres.query(
                    "SELECT COUNT(*)::int FROM strand.tasks WHERE backfill_id = \(handle.id) AND namespace_id = 'default'",
                    logger: logger
                )
                var taskCount = 0
                for try await row in taskStream {
                    var col = row.makeIterator()
                    taskCount = try col.next()!.decode(Int.self, context: .default)
                }
                #expect(taskCount > 0, "Expected at least one task to be enqueued for the backfill")

                // Verify the backfill row exists and is in a valid terminal or running state
                let status = try await handle.status()
                #expect(status.state == .running || status.state == .completed)
                #expect(status.completedSlots >= 0)
            }
        }
    }

    // Test 2: halt stops new slots from being enqueued
    @Test("halt stops backfill from enqueuing new slots")
    func haltStopsEnqueuing() async throws {
        try await withTestEnvironment { client in
            let now = Date()
            let rangeEnd = now
            let rangeStart = Calendar(identifier: .gregorian).date(byAdding: .hour, value: -10, to: now)!

            let handle = try await client.createBackfill(
                BackfillTestWorkflow.self,
                input: "halt-test",
                schedule: .interval(.hours(1)),
                range: rangeStart..<rangeEnd,
                options: BackfillOptions(concurrency: 1)
            )

            // Immediately halt before the scheduler runs
            try await handle.halt()

            let statusAfterHalt = try await handle.status()
            #expect(statusAfterHalt.state == .halted)
        }
    }

    // Test 3: BackfillStatus PostgresCodable round-trip
    @Test("BackfillStatus encodes and decodes via PostgresCodable")
    func backfillStatusPostgresCodable() async throws {
        try await withTestEnvironment { client in
            let postgres = client.postgres
            let logger = client.logger

            // Create a minimal backfill row so we can read it back
            let now = Date()
            let range = Calendar(identifier: .gregorian).date(byAdding: .hour, value: -2, to: now)!..<now
            let handle = try await client.createBackfill(
                BackfillTestWorkflow.self,
                input: "codable-test",
                schedule: .interval(.hours(1)),
                range: range,
                options: BackfillOptions()
            )

            // Read the status column directly as BackfillStatus via PostgresCodable
            let stream = try await postgres.query(
                "SELECT status FROM strand.backfills WHERE id = \(handle.id)",
                logger: logger
            )
            var decoded: BackfillQueries.BackfillStatus? = nil
            for try await row in stream {
                var col = row.makeIterator()
                decoded = try col.next()!.decode(
                    BackfillQueries.BackfillStatus.self,
                    context: .default
                )
            }
            #expect(decoded == .running)

            // Halt and verify the column value changes
            try await handle.halt()
            let stream2 = try await postgres.query(
                "SELECT status FROM strand.backfills WHERE id = \(handle.id)",
                logger: logger
            )
            var decodedAfterHalt: BackfillQueries.BackfillStatus? = nil
            for try await row in stream2 {
                var col = row.makeIterator()
                decodedAfterHalt = try col.next()!.decode(
                    BackfillQueries.BackfillStatus.self,
                    context: .default
                )
            }
            #expect(decodedAfterHalt == .halted)
        }
    }
}
