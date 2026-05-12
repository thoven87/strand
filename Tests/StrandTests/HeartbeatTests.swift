import Logging
import NIOCore
import PostgresNIO
import Synchronization
import Testing

@testable import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Shared observers

/// Store for values captured inside activity handlers so tests can
/// assert on them after the worker has finished.
private final class HeartbeatObserver: @unchecked Sendable {
    private let _lock = Mutex<State>(State())

    private struct State {
        var detailsOnAttempt1: Int? = nil  // heartbeatDetails seen on attempt 1 (should be nil)
        var detailsOnAttempt2: Int? = nil  // heartbeatDetails seen on attempt 2 (should be last checkpoint)
        var lastHeartbeatStored: Int = 0  // last value passed to heartbeat(_:) on attempt 1
    }

    var detailsOnAttempt1: Int? { _lock.withLock { $0.detailsOnAttempt1 } }
    var detailsOnAttempt2: Int? { _lock.withLock { $0.detailsOnAttempt2 } }
    var lastHeartbeatStored: Int { _lock.withLock { $0.lastHeartbeatStored } }

    func recordDetailsOnAttempt1(_ v: Int?) { _lock.withLock { $0.detailsOnAttempt1 = v } }
    func recordDetailsOnAttempt2(_ v: Int?) { _lock.withLock { $0.detailsOnAttempt2 = v } }
    func recordHeartbeat(_ v: Int) { _lock.withLock { $0.lastHeartbeatStored = v } }
}

// MARK: - Activity definitions

/// Processes `input` items one at a time, heartbeating after each one.
/// On attempt 1: fails after processing `failAfter` items, leaving the last
/// heartbeat at `failAfter`.
/// On attempt 2: resumes from `heartbeatDetails`, processes remaining items.
private struct ProgressActivity: ActivityDefinition {
    typealias Input = ProgressInput
    typealias Output = Int  // total items processed

    let observer: HeartbeatObserver

    func run(input: ProgressInput, context: ActivityContext) async throws -> Int {
        // Record what heartbeatDetails returns at the start of each attempt.
        let resumeFrom = context.heartbeatDetails(as: Int.self)
        if context.attempt == 1 {
            observer.recordDetailsOnAttempt1(resumeFrom)
        } else {
            observer.recordDetailsOnAttempt2(resumeFrom)
        }

        var processed = resumeFrom ?? 0

        for _ in processed..<input.totalItems {
            processed += 1
            // Store progress after every item.
            try await context.heartbeat(processed)
            // Only track the stored value on attempt 1 — attempt 2 would
            // overwrite it and make the sanity assertion misleading.
            if context.attempt == 1 { observer.recordHeartbeat(processed) }

            // Deliberate failure on attempt 1 once we reach failAfter.
            if context.attempt == 1 && processed == input.failAfter {
                throw HeartbeatTestError(processed: processed)
            }
        }
        return processed
    }
}

private struct ProgressInput: Codable, Sendable {
    let totalItems: Int
    let failAfter: Int
}

private struct HeartbeatTestError: Error, Codable, Sendable {
    let processed: Int
}

/// Wraps ProgressActivity and calls liveness-only `heartbeat()` (no details)
/// between items to verify it does NOT overwrite stored progress.
private struct LivenessHeartbeatActivity: ActivityDefinition {
    typealias Input = ProgressInput
    typealias Output = Int

    let observer: HeartbeatObserver

    func run(input: ProgressInput, context: ActivityContext) async throws -> Int {
        let resumeFrom = context.heartbeatDetails(as: Int.self)
        if context.attempt == 1 {
            observer.recordDetailsOnAttempt1(resumeFrom)
        } else {
            observer.recordDetailsOnAttempt2(resumeFrom)
        }

        var processed = resumeFrom ?? 0

        for _ in processed..<input.totalItems {
            processed += 1
            // Alternate: store progress, then a liveness-only heartbeat.
            try await context.heartbeat(processed)  // stores details
            try await context.heartbeat()  // liveness only — must NOT clear details
            observer.recordHeartbeat(processed)

            if context.attempt == 1 && processed == input.failAfter {
                throw HeartbeatTestError(processed: processed)
            }
        }
        return processed
    }
}

// MARK: - Workflows

private struct ProgressWorkflow: Workflow {
    typealias Input = ProgressInput
    typealias Output = Int

    mutating func run(context: WorkflowContext<Self>, input: ProgressInput) async throws -> Int {
        try await context.runActivity(
            ProgressActivity.self,
            input: input,
            options: .init(
                maxAttempts: 3,
                retryStrategy: .constant(.zero)  // retry immediately, no backoff
            )
        )
    }
}

private struct LivenessWorkflow: Workflow {
    typealias Input = ProgressInput
    typealias Output = Int

    mutating func run(context: WorkflowContext<Self>, input: ProgressInput) async throws -> Int {
        try await context.runActivity(
            LivenessHeartbeatActivity.self,
            input: input,
            options: .init(
                maxAttempts: 3,
                retryStrategy: .constant(.zero)
            )
        )
    }
}

// MARK: - Suite

@Suite("Integration — Activity heartbeat details")
struct HeartbeatTests {

    /// Core scenario: heartbeat(_:) stores progress; retry reads it back and resumes.
    ///
    /// - Attempt 1: starts with nil details, processes items 1-5, fails at item 5.
    ///   Last heartbeat stored = 5.
    /// - Attempt 2: heartbeatDetails returns 5; resumes from item 6.
    ///   Processes items 6-10, returns 10.
    @Test("heartbeat(_:) is nil on first attempt and carries last checkpoint to retry")
    func heartbeatDetailsCarriedOnRetry() async throws {
        let observer = HeartbeatObserver()

        try await withTestEnvironment { client in
            let postgres = client.postgres
            let logger = client.logger
            let queue = client.queueName

            let workerTask = startWorker(
                postgres: postgres,
                queueName: queue,
                logger: logger,
                workflows: [ProgressWorkflow.self],
                activities: [ProgressActivity(observer: observer)]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                ProgressWorkflow.self,
                input: ProgressInput(totalItems: 10, failAfter: 5)
            )

            let snap = try await awaitTerminal(
                client: client,
                taskID: handle.taskID,
                timeout: .seconds(15)
            )

            // Workflow must complete (attempt 2 processes items 6-10 successfully).
            #expect(snap.state == .completed)
            let output = try #require(snap.resultJSON.flatMap { try? JSON.decode(Int.self, from: ByteBuffer(string: $0)) })
            #expect(output == 10)

            // Attempt 1 must have seen nil (first attempt, no prior heartbeat).
            #expect(observer.detailsOnAttempt1 == nil)

            // Attempt 2 must have seen 5 (the last heartbeat written on attempt 1).
            #expect(observer.detailsOnAttempt2 == 5)

            // Sanity: the last heartbeat recorded by attempt 1 was indeed 5.
            #expect(observer.lastHeartbeatStored == 5)
        }
    }

    /// Liveness-only `heartbeat()` (no argument) must NOT overwrite stored progress.
    ///
    /// The activity alternates `heartbeat(processed)` then `heartbeat()` between
    /// items. After the failure on attempt 1 the stored progress should still be
    /// the last value-bearing heartbeat, not cleared by the no-arg call.
    @Test("liveness-only heartbeat() does not clear stored progress details")
    func livenessHeartbeatDoesNotClearDetails() async throws {
        let observer = HeartbeatObserver()

        try await withTestEnvironment { client in
            let postgres = client.postgres
            let logger = client.logger
            let queue = client.queueName

            let workerTask = startWorker(
                postgres: postgres,
                queueName: queue,
                logger: logger,
                workflows: [LivenessWorkflow.self],
                activities: [LivenessHeartbeatActivity(observer: observer)]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                LivenessWorkflow.self,
                input: ProgressInput(totalItems: 10, failAfter: 3)
            )

            let snap = try await awaitTerminal(
                client: client,
                taskID: handle.taskID,
                timeout: .seconds(15)
            )

            #expect(snap.state == .completed)

            // Attempt 2 must still see 3 even though a no-arg heartbeat() was
            // called after each heartbeat(processed).
            #expect(observer.detailsOnAttempt2 == 3)
        }
    }
}
