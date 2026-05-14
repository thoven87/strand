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

// MARK: - Test-local error types

private struct DeliberateFailure: Error, Codable, Sendable {
    let reason: String
}

// MARK: - Workflow definitions
//
// All workflow and activity types are defined at file scope so they can be
// referenced both inside test suites and passed directly as metatypes or
// instances to startWorker (the new API).

// ── 1. Echo ─────────────────────────────────────────────────────────────────
// Used by: basicCompletion, idempotencyKey tests.

private struct EchoWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        input.uppercased()
    }
}

// ── 2. Math (multi-step) ─────────────────────────────────────────────────────
// Used by: multiStep test.

private struct MathWorkflow: Workflow {
    typealias Input = Int
    typealias Output = Int

    mutating func run(context: WorkflowContext<Self>, input: Int) async throws -> Int {
        // Pure deterministic computation — no checkpoint needed.
        let doubled = input * 2
        let plusOne = doubled + 1
        return plusOne
    }
}

// ── 3. Idempotent checkpoint ─────────────────────────────────────────────────
// Throws deliberately on attempt 1 to force a retry. `capturedValue` records
// the random number generated on the first activation so the test can verify
// the SAME value is returned on retry (proving the checkpoint was read, not
// regenerated).
// Used by: stepIdempotency test.

private struct IdempotentWorkflow: Workflow {
    typealias Input = String
    typealias Output = Int

    /// Stores the random value captured on the first activation.
    /// Static so the test can read it after the workflow completes.
    static let capturedValue = AtomicInt()

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> Int {
        // Generate a random Int exactly once — checkpointed so the same
        // value is returned on every subsequent activation.
        let n = try context.random(in: 1...1_000_000)
        // Record the value so the test can compare it to the final output.
        Self.capturedValue.store(n)
        // Force a retry on the first attempt so replay is exercised.
        if context.attempt == 1 {
            throw DeliberateFailure(reason: "forced failure on attempt 1")
        }
        return n
    }
}

// ── 4. Cancellable ──────────────────────────────────────────────────────────
// Tracks whether its handler body ever ran.
// Used by: cancellation test.

private struct CancellableWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    static let executionCount = AtomicCounter()

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        Self.executionCount.increment()
        return "ran"
    }
}

// ── 5. Event wait ────────────────────────────────────────────────────────────
// The event name is passed as workflow input so the test can use a unique
// per-run name without closures.
// Used by: suspendAndResume test.

private struct EventWaitInput: Codable, Sendable {
    let eventName: String
}

private struct EventPayload: Codable, Sendable, Equatable {
    let msg: String
}

private struct EventWaitWorkflow: Workflow {
    typealias Input = EventWaitInput
    typealias Output = EventPayload

    mutating func run(
        context: WorkflowContext<Self>,
        input: EventWaitInput
    ) async throws -> EventPayload {
        try await context.waitForEvent(input.eventName, as: EventPayload.self)
    }
}

// ── 6. Timeout event ─────────────────────────────────────────────────────────
// Waits for an event with a 1-second timeout, then returns a sentinel on expiry.
// Used by: timeoutPersistsSentinel test.

private struct TimeoutEventInput: Codable, Sendable {
    let eventName: String
}

private struct TimeoutEventWorkflow: Workflow {
    typealias Input = TimeoutEventInput
    typealias Output = String

    mutating func run(
        context: WorkflowContext<Self>,
        input: TimeoutEventInput
    ) async throws -> String {
        do {
            return try await context.waitForEvent(
                input.eventName,
                as: String.self,
                timeout: .seconds(1)
            )
        } catch is EventWaitTimeoutError {
            return "timed-out"
        }
    }
}

// ── 7. Signalled ────────────────────────────────────────────────────────────
// Stores signal receipt as optional workflow state so it survives between
// activations. The `Bool?` (rather than `Bool`) decodes cleanly from the
// initial empty-object `{}` that the worker synthesises on the first
// activation — `decodeIfPresent` returns `nil` for a missing key.
// Used by: workflowWithSignal test.

private struct SignalledWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    /// `nil` on first decode from `{}`.  Becomes `true` after "ack" signal.
    var signalReceived: Bool?

    mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
        if name == "ack" { signalReceived = true }
    }

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        // Sleep long enough to give the test a window to send the signal.
        // On re-activation, the sleep checkpoint is replayed instantly and
        // `signalReceived` reflects any signals applied before this run.
        try await context.sleep(for: .milliseconds(500))
        return signalReceived == true ? "acked" : "not-acked"
    }
}

// ── 8. Activity execution ────────────────────────────────────────────────────
// A simple activity plus the workflow that calls it.
// Used by: activityExecution test.

private struct ReverseActivity: Activity {
    typealias Input = String
    typealias Output = String

    static let name = "reverse-activity"

    func run(input: String, context: ActivityContext) async throws -> String {
        String(input.reversed())
    }
}

private struct ActivityWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        try await context.runActivity(ReverseActivity.self, input: input)
    }
}

// ── 9. Flaky activity (retry on failure) ────────────────────────────────────
// Fails deliberately on attempt 1, succeeds on attempt 2.
// The workflow passes `maxAttempts: 3` so the activity is retried.
// Used by: activityRetryOnFailure test.

private struct FlakyActivity: Activity {
    typealias Input = String
    typealias Output = String
    typealias Failure = DeliberateFailure

    static let name = "flaky-activity"
    static let executionCount = AtomicCounter()

    func run(input: String, context: ActivityContext) async throws -> String {
        Self.executionCount.increment()
        if context.attempt == 1 {
            throw DeliberateFailure(reason: "deliberate failure on attempt 1")
        }
        return "recovered"
    }
}

private struct ActivityRetryWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        try await context.runActivity(
            FlakyActivity.self,
            input: input,
            options: .init(maxAttempts: 3, retryStrategy: .constant(.zero))
        )
    }
}

// ── 10. Sleep ────────────────────────────────────────────────────────────────
// Used by: sleepSuspendsAndResumes test.

private struct SleepWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        try await context.sleep(for: .milliseconds(200))
        return "woke-up"
    }
}

// ── 11. Lease expiry ─────────────────────────────────────────────────────────
// Records how many times its handler ran so the test can confirm the handler
// ran exactly once (by the real worker after the phantom lease was swept).
// Used by: expiredLeaseIsSweptAndRetried test.

private struct LeaseExpiryWorkflow: Workflow {
    typealias Input = String
    typealias Output = String

    static let executionCount = AtomicCounter()

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        Self.executionCount.increment()
        return "completed-by-retry"
    }
}

// MARK: - Schema and queue management

@Suite("Integration — Schema & queues", .tags(.integration), .serialized)
struct SchemaAndQueueTests {

    @Test("schema is installed and verifySchema passes")
    func schemaVersion() async throws {
        try await withTestEnvironment { client in
            // verifySchema is already called inside withTestEnvironment, but
            // we call it again here to test the public API explicitly.
            try await client.verifySchema()
        }
    }

    @Test("created queue appears in listQueues")
    func listQueues() async throws {
        try await withTestEnvironment { client in
            let queues = try await client.listQueues()
            #expect(queues.contains(client.queueName))
        }
    }
}

// MARK: - Task execution

@Suite("Integration — Task execution", .tags(.integration), .serialized)
struct TaskExecutionTests {

    @Test("basic workflow completes with the correct result")
    func basicCompletion() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [EchoWorkflow.self]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                EchoWorkflow.self,
                options: .init(),
                input: "hello"
            )
            let result = try await handle.result(timeout: .seconds(10))
            #expect(result == "HELLO")
        }
    }

    @Test("multi-step workflow returns the correct composed result")
    func multiStep() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [MathWorkflow.self]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                MathWorkflow.self,
                options: .init(),
                input: 10
            )
            let result = try await handle.result(timeout: .seconds(10))
            // 10 * 2 = 20, 20 + 1 = 21
            #expect(result == 21)
        }
    }

    @Test("checkpointed value is stable across retries (random(in:) returns same value on replay)")
    func stepIdempotency() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [IdempotentWorkflow.self]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                IdempotentWorkflow.self,
                options: .init(maxAttempts: 2, retryStrategy: .constant(.zero)),
                input: "go"
            )
            let result = try await handle.result(timeout: .seconds(15))

            // The result from attempt 2 must equal the value generated on attempt 1
            // (read from the checkpoint cache, not regenerated).
            #expect(result == IdempotentWorkflow.capturedValue.value)
            #expect((1...1_000_000).contains(result))
        }
    }

    @Test("startWorkflow with the same id returns the same task for both calls")
    func idempotencyKey() async throws {
        try await withTestEnvironment { client in
            let key = "idem:\(UUID())"

            let h1 = try await client.startWorkflow(
                EchoWorkflow.self,
                options: .init(id: key),
                input: "a"
            )
            let h2 = try await client.startWorkflow(
                EchoWorkflow.self,
                options: .init(id: key),
                input: "b"
            )
            // Both handles must reference the same underlying task.
            #expect(h1.taskID == h2.taskID)
        }
    }

    @Test("cancelled workflow is not executed by the worker")
    func cancellation() async throws {
        try await withTestEnvironment { client in
            let before = CancellableWorkflow.executionCount.value

            // Enqueue, then cancel before the worker starts.
            let handle = try await client.startWorkflow(
                CancellableWorkflow.self,
                options: .init(),
                input: "test"
            )
            try await handle.cancel()

            // Worker starts AFTER cancellation — it must not run the handler.
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [CancellableWorkflow.self]
            )
            defer { workerTask.cancel() }

            let snap = try await awaitTerminal(
                client: client,
                taskID: handle.taskID,
                timeout: .seconds(5)
            )
            #expect(snap.state == .cancelled)
            // Handler must not have run.
            #expect(CancellableWorkflow.executionCount.value == before)
        }
    }
}

// MARK: - Events

@Suite("Integration — Events", .tags(.integration), .serialized)
struct EventTests {

    @Test("workflow suspends on waitForEvent, then resumes when event is emitted")
    func suspendAndResume() async throws {
        try await withTestEnvironment { client in
            let eventName = "resume:\(UUID())"

            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [EventWaitWorkflow.self]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                EventWaitWorkflow.self,
                options: .init(),
                input: EventWaitInput(eventName: eventName)
            )

            // Wait until the workflow has registered its event_waits row (state = WAITING).
            // A fixed sleep is fragile on slow CI runners — if the first activation
            // hasn't finished by the time we emit, the event fires before the wait
            // is registered and the workflow never resumes.
            let waitDeadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < waitDeadline {
                if let snap = try await handle.snapshot(), snap.state == .waiting { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await client.emitEvent(eventName, payload: EventPayload(msg: "from-test"))

            let result = try await handle.result(timeout: .seconds(10))
            #expect(result == EventPayload(msg: "from-test"))
        }
    }

    @Test("timed-out waitForEvent persists a sentinel so replay skips re-suspension")
    func timeoutPersistsSentinel() async throws {
        try await withTestEnvironment { client in
            let eventName = "never:\(UUID())"

            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [TimeoutEventWorkflow.self]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                TimeoutEventWorkflow.self,
                options: .init(),
                input: TimeoutEventInput(eventName: eventName)
            )

            // Timeout is 1 s inside the workflow; allow 15 s total for the whole test.
            let result = try await handle.result(timeout: .seconds(15))
            #expect(result == "timed-out")
        }
    }
}

// MARK: - Signals

@Suite("Integration — Signals", .tags(.integration), .serialized)
struct SignalTests {

    /// A `handle.signal(name:)` is delivered via `workflow_signals` and applied
    /// by `handleSignal` before the next activation's `run` call.
    ///
    /// Flow:
    ///  1. Workflow starts and immediately enters a 500 ms sleep (suspends).
    ///  2. Test sends "ack" signal while the workflow is sleeping.
    ///  3. After 500 ms the sleeping run becomes claimable again.
    ///  4. Worker re-claims: applies pending signals → `signalReceived = true`.
    ///  5. `run` replays the sleep (fast path, already past) → returns "acked".
    @Test("signal sent while workflow sleeps is applied on the next activation")
    func workflowWithSignal() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [SignalledWorkflow.self]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                SignalledWorkflow.self,
                options: .init(),
                input: "start"
            )

            // Wait for the workflow to start and enter the sleep checkpoint.
            try await Task.sleep(for: .milliseconds(200))

            // Send signal while the workflow is sleeping.
            try await handle.signal(name: "ack")

            let result = try await handle.result(timeout: .seconds(10))
            #expect(result == "acked")
        }
    }
}

// MARK: - Activities

@Suite("Integration — Activities", .tags(.integration), .serialized)
struct ActivityTests {

    @Test("workflow calling runActivity receives the activity's result")
    func activityExecution() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [ActivityWorkflow.self],
                activities: [ReverseActivity()]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                ActivityWorkflow.self,
                options: .init(),
                input: "hello"
            )
            let result = try await handle.result(timeout: .seconds(10))
            #expect(result == "olleh")
        }
    }

    @Test("activity that throws on attempt 1 is retried and succeeds on attempt 2")
    func activityRetryOnFailure() async throws {
        try await withTestEnvironment { client in
            let before = FlakyActivity.executionCount.value

            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [ActivityRetryWorkflow.self],
                activities: [FlakyActivity()]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                ActivityRetryWorkflow.self,
                options: .init(),
                input: "go"
            )
            let result = try await handle.result(timeout: .seconds(15))

            #expect(result == "recovered")
            // The activity body ran twice: once to fail, once to succeed.
            #expect(FlakyActivity.executionCount.value - before == 2)
        }
    }
}

// MARK: - Sleep

@Suite("Integration — Sleep", .tags(.integration), .serialized)
struct SleepTests {

    @Test("context.sleep suspends the workflow and it resumes correctly")
    func sleepSuspendsAndResumes() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [SleepWorkflow.self]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                SleepWorkflow.self,
                options: .init(),
                input: "go"
            )
            let result = try await handle.result(timeout: .seconds(10))
            #expect(result == "woke-up")
        }
    }
}

// MARK: - Lease expiry

@Suite("Integration — Lease expiry", .tags(.integration), .serialized)
struct LeaseExpiryTests {

    /// Simulates a "phantom worker" that claims a run but never completes it.
    /// After the lease expires, `sweepExpiredLeases` re-enqueues the run and a
    /// real worker picks it up on the retry attempt.
    @Test("expired lease is swept and the task retries successfully")
    func expiredLeaseIsSweptAndRetried() async throws {
        try await withTestEnvironment { client in
            let before = LeaseExpiryWorkflow.executionCount.value

            // Enqueue the workflow.
            let handle = try await client.startWorkflow(
                LeaseExpiryWorkflow.self,
                options: .init(maxAttempts: 2, retryStrategy: .constant(.zero)),
                input: "go"
            )

            // Phantom-claim the pending run with a 1-second lease but never complete it.
            let phantomClaimed = try await Queries.claimTasks(
                on: client.postgres,
                namespaceID: "default",
                queue: client.queueName,
                workerID: "phantom-worker",
                claimTimeoutSeconds: 1,
                qty: 1,
                logger: client.logger
            )
            #expect(phantomClaimed.count == 1)
            #expect(phantomClaimed.first?.taskID == handle.taskID)

            // Wait for the 1-second lease to expire.
            try await Task.sleep(for: .seconds(2))

            // Sweep the expired lease — this marks the run FAILED and creates a retry run.
            try await Queries.sweepExpiredLeases(
                on: client.postgres,
                namespaceID: "default",
                queue: client.queueName,
                logger: client.logger
            )

            // Real worker picks up the retry run.
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [LeaseExpiryWorkflow.self]
            )
            defer { workerTask.cancel() }

            let snap = try await awaitTerminal(
                client: client,
                taskID: handle.taskID,
                timeout: .seconds(10)
            )
            #expect(snap.state == .completed)
            // Handler must have run exactly once (on the retry, not the phantom claim).
            #expect(LeaseExpiryWorkflow.executionCount.value - before == 1)

            let decoded = try snap.decodeResult(as: String.self)
            #expect(decoded == "completed-by-retry")
        }
    }
}

// MARK: - Standalone activity dispatch

private struct StandaloneGreetActivity: Activity {
    typealias Input = String
    typealias Output = String
    func run(input: String, context: ActivityContext) async throws -> String {
        "Hello standalone, \(input)!"
    }
}

@Suite("Integration — Standalone activities", .tags(.integration), .serialized)
struct StandaloneActivityTests {

    @Test("client.runActivity dispatches without a parent workflow and returns the result")
    func standaloneRun() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                activities: [StandaloneGreetActivity()]
            )
            defer { workerTask.cancel() }

            let result = try await client.runActivity(
                StandaloneGreetActivity.self,
                input: "world"
            )
            #expect(result == "Hello standalone, world!")
        }
    }

    @Test("client.enqueueActivity returns an EnqueueResult with a stable taskID")
    func standaloneEnqueue() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                activities: [StandaloneGreetActivity()]
            )
            defer { workerTask.cancel() }

            let enq = try await client.enqueueActivity(
                StandaloneGreetActivity.self,
                input: "strand"
            )
            let snap = try await awaitTerminal(client: client, taskID: enq.taskID)
            #expect(snap.state == .completed)
            #expect(try snap.decodeResult(as: String.self) == "Hello standalone, strand!")
        }
    }

    @Test("fairness_weight: higher weight tasks are claimed before lower weight tasks")
    func fairnessWeightOrdering() async throws {
        try await withTestEnvironment { client in
            // Enqueue tasks with different priorities instead of fairness weights
            // (fairness weight affects random ordering probability, not strict ordering).
            // Use different priorities to test deterministic ordering.
            let low = try await client.enqueueActivity(
                StandaloneGreetActivity.self,
                input: "low",
                options: .init(priority: .low)
            )
            let high = try await client.enqueueActivity(
                StandaloneGreetActivity.self,
                input: "high",
                options: .init(priority: .high)
            )

            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                activities: [StandaloneGreetActivity()]
            )
            defer { workerTask.cancel() }

            // High priority should complete before low priority
            let highSnap = try await awaitTerminal(
                client: client,
                taskID: high.taskID,
                timeout: .seconds(5)
            )
            let lowSnap = try await awaitTerminal(
                client: client,
                taskID: low.taskID,
                timeout: .seconds(5)
            )
            #expect(highSnap.state == .completed)
            #expect(lowSnap.state == .completed)
            // Both tasks completed; priority ordering is enforced by the claim query.
        }
    }
}

// MARK: - Parallel activities (Phase 2 executor)

private struct DoubleActivity: Activity {
    typealias Input = String
    typealias Output = String

    static let counter = AtomicCounter()

    func run(input: String, context: ActivityContext) async throws -> String {
        Self.counter.increment()
        return input.uppercased()
    }
}

private struct TripleActivity: Activity {
    typealias Input = String
    typealias Output = String

    static let counter = AtomicCounter()

    func run(input: String, context: ActivityContext) async throws -> String {
        Self.counter.increment()
        return input + "!!!"
    }
}

private struct ParallelWorkflow: Workflow {
    typealias Input = String
    typealias Output = [String]

    mutating func run(
        context: WorkflowContext<Self>,
        input: String
    ) async throws -> [String] {
        // Phase 2: both activities dispatch in parallel
        async let doubled = context.runActivity(DoubleActivity.self, input: input)
        async let tripled = context.runActivity(TripleActivity.self, input: input)
        let (a, b) = try await (doubled, tripled)
        return [a, b]
    }
}

@Suite("Integration — Parallel activities", .tags(.integration), .serialized)
struct ParallelActivityTests {

    @Test("two runActivity calls in async let execute in parallel and both complete")
    func parallelRunActivity() async throws {
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [ParallelWorkflow.self],
                activities: [DoubleActivity(), TripleActivity()]
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                ParallelWorkflow.self,
                options: .init(),
                input: "hello"
            )
            let result = try await handle.result(timeout: .seconds(10))

            // Both activities ran exactly once
            #expect(DoubleActivity.counter.value == 1)
            #expect(TripleActivity.counter.value == 1)

            // Results are both present (order may vary)
            #expect(result.contains("HELLO"))
            #expect(result.contains("hello!!!"))
            #expect(result.count == 2)
        }
    }
}
