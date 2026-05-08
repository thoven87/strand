import Logging
import Metrics
import NIOCore
import PostgresNIO
import Synchronization
import Testing
import Tracing

@testable import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - TestMetricsFactory
//
// TestMetricsFactory. Injected directly into StrandWorker — no global
// MetricsSystem.bootstrap needed.

final class TestMetricsFactory: MetricsFactory, @unchecked Sendable {
    private let lock = Mutex<State>(State())

    private struct State {
        var counters: [String: Int64] = [:]
        var timerSamples: [String: [Int64]] = [:]
    }

    // MARK: MetricsFactory

    func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        _Counter(factory: self, label: label)
    }
    func makeRecorder(
        label: String,
        dimensions: [(String, String)],
        aggregate: Bool
    )
        -> RecorderHandler
    {
        _Recorder()
    }
    func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        _Timer(factory: self, label: label)
    }
    func destroyCounter(_ handler: CounterHandler) {}
    func destroyRecorder(_ handler: RecorderHandler) {}
    func destroyTimer(_ handler: TimerHandler) {}

    // MARK: Accumulation

    func record(counter label: String, amount: Int64) {
        lock.withLock { $0.counters[label, default: 0] += amount }
    }
    func record(timer label: String, nanoseconds: Int64) {
        lock.withLock { $0.timerSamples[label, default: []].append(nanoseconds) }
    }

    func counterValue(for label: String) -> Int64 {
        lock.withLock { $0.counters[label] ?? 0 }
    }
    func timerSampleCount(for label: String) -> Int {
        lock.withLock { $0.timerSamples[label]?.count ?? 0 }
    }
}

private final class _Counter: CounterHandler, @unchecked Sendable {
    let factory: TestMetricsFactory
    let label: String
    init(factory: TestMetricsFactory, label: String) {
        self.factory = factory
        self.label = label
    }
    func increment(by amount: Int64) { factory.record(counter: label, amount: amount) }
    func reset() {}
}
private final class _Timer: TimerHandler, @unchecked Sendable {
    let factory: TestMetricsFactory
    let label: String
    init(factory: TestMetricsFactory, label: String) {
        self.factory = factory
        self.label = label
    }
    func recordNanoseconds(_ duration: Int64) {
        factory.record(timer: label, nanoseconds: duration)
    }
}
private final class _Recorder: RecorderHandler, @unchecked Sendable {
    func record(_ value: Int64) {}
    func record(_ value: Double) {}
}

// MARK: - TestTracer
//
// Stores spans by operation name so tests can assert on specific spans.

final class TestTracer: Tracer, @unchecked Sendable {
    typealias Span = TestSpan

    private let spans = Mutex<[String: TestSpan]>([:])

    func span(named name: String) -> TestSpan? {
        spans.withLock { $0[name] }
    }

    func startSpan<Instant>(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind kind: SpanKind,
        at instant: @autoclosure () -> Instant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> TestSpan where Instant: TracerInstant {
        spans.withLock { store in
            let s = TestSpan(operationName: operationName, context: context())
            store[operationName] = s
            return s
        }
    }

    func forceFlush() {}
    func extract<Carrier, Extract>(
        _ carrier: Carrier,
        into context: inout ServiceContext,
        using extractor: Extract
    ) where Carrier == Extract.Carrier, Extract: Extractor {}
    func inject<Carrier, Inject>(
        _ context: ServiceContext,
        into carrier: inout Carrier,
        using injector: Inject
    ) where Carrier == Inject.Carrier, Inject: Injector {}
}

final class TestSpan: Tracing.Span, @unchecked Sendable {
    var operationName: String  // nonmutating set satisfied by class reference semantics
    let context: ServiceContext
    var attributes: SpanAttributes = [:]
    var status: SpanStatus?
    let isRecording = true
    var description: String { "TestSpan(\(operationName))" }

    init(operationName: String, context: ServiceContext) {
        self.operationName = operationName
        self.context = context
    }

    func setStatus(_ status: SpanStatus) { self.status = status }
    func addEvent(_ event: SpanEvent) {}
    func addLink(_ link: SpanLink) {}
    func recordError<Instant>(
        _ error: any Error,
        attributes: SpanAttributes,
        at instant: @autoclosure () -> Instant
    ) where Instant: TracerInstant {
        setStatus(.init(code: .error))
    }
    func end<Instant>(at instant: @autoclosure () -> Instant) where Instant: TracerInstant {}
}

// MARK: - Workflow fixtures

private struct SimpleWorkflow: Workflow {
    typealias Input = String
    typealias Output = String
    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        input + "-ok"
    }
}

private struct SimpleActivity: ActivityDefinition {
    typealias Input = String
    typealias Output = String
    var onRan: (@Sendable () -> Void)?
    func run(input: String, context: ActivityContext) async throws -> String {
        onRan?()
        return input.uppercased()
    }
}

private struct ActivityWorkflowM: Workflow {
    typealias Input = String
    typealias Output = String
    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        try await context.runActivity(SimpleActivity.self, input: input)
    }
}

// MARK: - Metrics test suite

@Suite("Integration — Metrics", .tags(.integration), .serialized)
struct MetricsTests {

    // ── 1 ───────────────────────────────────────────────────────────────────
    @Test("workflow completion increments tasks_claimed, tasks_completed; records duration")
    func workflowMetrics() async throws {
        let metrics = TestMetricsFactory()

        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [SimpleWorkflow.self],
                metricsFactory: metrics
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                SimpleWorkflow.self,
                options: .init(),
                input: "ping"
            )
            let result = try await handle.result(timeout: .seconds(10))
            #expect(result == "ping-ok")
        }

        #expect(metrics.counterValue(for: StrandMetrics.tasksClaimed) >= 1)
        #expect(metrics.counterValue(for: StrandMetrics.tasksCompleted) >= 1)
        #expect(metrics.timerSampleCount(for: StrandMetrics.taskDuration) >= 1)
        #expect(metrics.counterValue(for: StrandMetrics.tasksFailed) == 0)
    }

    // ── 2 ───────────────────────────────────────────────────────────────────
    @Test("failing workflow increments tasks_failed counter")
    func failedWorkflowMetrics() async throws {
        let metrics = TestMetricsFactory()
        struct FailingWorkflow: Workflow {
            typealias Input = String
            typealias Output = String
            struct Boom: Error {}
            mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
                throw Boom()
            }
        }

        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [FailingWorkflow.self],
                metricsFactory: metrics
            )
            defer { workerTask.cancel() }

            let handle = try await client.startWorkflow(
                FailingWorkflow.self,
                options: .init(),
                input: "x"
            )
            let snap = try await awaitTerminal(
                client: client,
                taskID: handle.taskID,
                timeout: .seconds(10)
            )
            #expect(snap.state == .failed)
        }

        #expect(metrics.counterValue(for: StrandMetrics.tasksFailed) >= 1)
        #expect(metrics.counterValue(for: StrandMetrics.tasksCompleted) == 0)
    }

    // ── 3 ───────────────────────────────────────────────────────────────────
    @Test("activity execution emits task duration samples for both workflow and activity tasks")
    func activityMetrics() async throws {
        let metrics = TestMetricsFactory()

        try await withTestEnvironment { client in
            try await confirmation("SimpleActivity ran") { confirm in
                let workerTask = startWorker(
                    postgres: client.postgres,
                    queueName: client.queueName,
                    logger: client.logger,
                    workflows: [ActivityWorkflowM.self],
                    activities: [SimpleActivity(onRan: { confirm() })],
                    metricsFactory: metrics
                )
                defer { workerTask.cancel() }

                let handle = try await client.startWorkflow(
                    ActivityWorkflowM.self,
                    options: .init(),
                    input: "hello"
                )
                // handle.result() only returns after the activity completed,
                // so confirmation sees exactly 1 confirm() call.
                let result = try await handle.result(timeout: .seconds(30))
                #expect(result == "HELLO")
            }
        }

        // Workflow + activity are each claimed tasks → at least 2 duration samples.
        #expect(metrics.timerSampleCount(for: StrandMetrics.taskDuration) >= 2)
        #expect(metrics.counterValue(for: StrandMetrics.tasksCompleted) >= 2)
    }
}

// MARK: - Tracing test suite
//
// InstrumentationSystem.bootstrap has a once-only precondition (like LoggingSystem).
// All tracing assertions are in a single test so bootstrap is called exactly once.

@Suite("Integration — Tracing", .tags(.integration), .serialized)
struct TracingTests {

    @Test("workflow and activity spans are emitted with strand.* attributes")
    func allSpans() async throws {
        let tracer = TestTracer()
        InstrumentationSystem.bootstrap(tracer)

        // ── Workflow span ─────────────────────────────────────────────────────
        try await withTestEnvironment { client in
            let workerTask = startWorker(
                postgres: client.postgres,
                queueName: client.queueName,
                logger: client.logger,
                workflows: [SimpleWorkflow.self]
            )
            defer { workerTask.cancel() }
            let handle = try await client.startWorkflow(
                SimpleWorkflow.self,
                options: .init(),
                input: "trace-test"
            )
            _ = try await handle.result(timeout: .seconds(10))
        }

        let wfSpan = tracer.span(named: "SimpleWorkflow")
        #expect(wfSpan != nil, "expected SimpleWorkflow span")
        if let span = wfSpan {
            if case .string(let v)? = span.attributes[StrandLogKeys.taskName]?.toSpanAttribute() {
                #expect(v == "SimpleWorkflow")
            } else {
                Issue.record("strand.task.name attribute missing")
            }
            if case .string(let k)? = span.attributes[StrandLogKeys.taskKind]?.toSpanAttribute() {
                #expect(k == "WORKFLOW")
            } else {
                Issue.record("strand.task.kind attribute missing")
            }
            #expect(span.attributes[StrandLogKeys.queue] != nil)
            #expect(span.attributes[StrandLogKeys.taskID] != nil)
        }

        // ── Activity span ─────────────────────────────────────────────────────
        try await withTestEnvironment { client in
            try await confirmation("SimpleActivity ran") { confirm in
                let workerTask = startWorker(
                    postgres: client.postgres,
                    queueName: client.queueName,
                    logger: client.logger,
                    workflows: [ActivityWorkflowM.self],
                    activities: [SimpleActivity(onRan: { confirm() })]
                )
                defer { workerTask.cancel() }
                let handle = try await client.startWorkflow(
                    ActivityWorkflowM.self,
                    options: .init(),
                    input: "span-test"
                )
                _ = try await awaitTerminal(client: client, taskID: handle.taskID, timeout: .seconds(30))
            }
        }

        let actSpan = tracer.span(named: "SimpleActivity")
        #expect(actSpan != nil, "expected SimpleActivity span")
        if let span = actSpan {
            if case .string(let v)? = span.attributes[StrandLogKeys.taskName]?.toSpanAttribute() {
                #expect(v == "SimpleActivity")
            } else {
                Issue.record("strand.task.name attribute missing")
            }
            if case .string(let k)? = span.attributes[StrandLogKeys.taskKind]?.toSpanAttribute() {
                #expect(k == "ACTIVITY")
            } else {
                Issue.record("strand.task.kind attribute missing")
            }
        }
    }
}
