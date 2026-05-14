public import Logging
import NIOCore
import PostgresNIO

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// MARK: - Private helpers

/// Checkpoint sentinel persisted when a `waitForEvent` call times out.
/// Detected on the next activation to immediately re-throw the timeout error.
struct TimeoutSentinel: Codable {
    let timeout: Bool
    init() { self.timeout = true }
    private enum CodingKeys: String, CodingKey { case timeout = "$timeout" }
    static func detect(in buffer: ByteBuffer) -> Bool {
        (try? JSON.decode(TimeoutSentinel.self, from: buffer))?.timeout == true
    }
}

/// Checkpoint sentinel stored when a `sleep` completes. On replay,
/// detecting this sentinel causes `sleep` to return immediately without
/// emitting `.timerFired`, ensuring the `TIMER_FIRED` history event is
/// written exactly once regardless of subsequent re-activations.
struct SleepCompletedSentinel: Codable {
    let slept: Bool
    init() { self.slept = true }
    private enum CodingKeys: String, CodingKey { case slept = "$slept" }
    static func detect(in buffer: ByteBuffer) -> Bool {
        (try? JSON.decode(SleepCompletedSentinel.self, from: buffer))?.slept == true
    }
}

/// Checkpoint sentinel written when a `condition(timeout:)` call resolves (either
/// predicate satisfied or deadline elapsed). Overrides the deadline checkpoint so
/// replay can return the result immediately without re-evaluating the predicate.
/// Stored in the same `seqNum` slot as the deadline timestamp.
struct ConditionResultSentinel: Codable {
    /// `true` = predicate was satisfied; `false` = deadline elapsed.
    let met: Bool
    private enum CodingKeys: String, CodingKey { case met = "$conditionMet" }
    /// Returns the stored result if `buffer` contains this sentinel, `nil` otherwise.
    static func detect(in buffer: ByteBuffer) -> Bool? {
        (try? JSON.decode(ConditionResultSentinel.self, from: buffer))?.met
    }
}

// MARK: - _WorkflowActivation

/// Holds all mutable per-activation state for a single workflow execution attempt.
///
/// One instance is created per worker claim. The `WorkflowContext` struct holds a
/// reference to this object and routes all API calls through it.
///
/// ## Why `final class` instead of `actor`
/// A workflow activation is executed by exactly one async task at a time — the worker
/// claims a run, the handler executes to completion or suspension, then the run is
/// There is no concurrent access to `checkpointCache`, `activationCounter`, or
/// `watchdog` during a single activation. Using a `final class` instead of an `actor`
/// eliminates unnecessary actor hops on every checkpoint/cache access, keeping the hot
/// path synchronous and simple.
///
/// ## Why `@unchecked Sendable`
/// `WorkflowContext<W>: Sendable` stores a reference to this object. The `@unchecked`
/// is safe because the invariant above (single-task exclusive access) is enforced by
/// the worker's claim mechanism — never by Swift's type system.
final class _WorkflowActivation<W: Workflow>: @unchecked Sendable {

    // MARK: - Identity (set once in init, never mutated)

    let taskUUID: UUID
    let runUUID: UUID
    let taskName: String
    let queueName: String
    let attempt: Int
    let claimTimeoutSeconds: Int
    /// The event name the run was woken by, if any (non-nil on re-activations after a wait).
    let wakeEvent: String?
    /// The payload delivered with `wakeEvent`, if any.
    let eventPayload: ByteBuffer?
    let headers: [String: String]
    /// Decoded once at activation time — `nil` for directly-enqueued workflows.
    let schedulingMetadata: SchedulingMetadata?
    /// The namespace this activation belongs to. Scopes all DB writes to the
    /// correct tenant; defaults to `"default"` for single-tenant deployments.
    let namespace: String
    /// Wall-clock time captured at the start of this activation. Returned by
    /// `WorkflowContext.activationTime` so the value is stable for the duration
    /// of the activation rather than drifting with `Date.now`.
    let activationTime: Date

    // MARK: - Dependencies (set once in init, never mutated)

    let postgres: PostgresClient
    let logger: Logger
    /// Deterministic serial executor used to drain the handler's job queue during activation.
    let executor: StrandWorkflowExecutor
    /// Heap-allocated workflow value shared between handler invocations and signal delivery.
    let stateBox: ArcBox<W>

    // MARK: - Mutable replay state

    /// Checkpoint values loaded at activation start. Keyed by seq_num (Int).
    var checkpointCache: [Int: ByteBuffer]
    /// Monotonic activation counter — each context call produces a unique seq_num.
    var activationCounter: ActivationCounter

    /// The `#fileID` and `#line` of the most recent `WorkflowContext` call (runActivity,
    /// sleep, waitForEvent, condition). Stamped onto the `FailureReason` when the
    /// handler throws — tells the dashboard which line in the workflow handler failed.
    /// Updated by WorkflowContext public functions; read by activate() on handler failure.
    var lastCallSite: (fileID: String, line: Int)? = nil

    // MARK: - Init

    init(
        taskUUID: UUID,
        runUUID: UUID,
        taskName: String,
        queueName: String,
        attempt: Int,
        claimTimeoutSeconds: Int,
        wakeEvent: String?,
        eventPayload: ByteBuffer?,
        headers: [String: String],
        schedulingMetadata: SchedulingMetadata?,
        postgres: PostgresClient,
        logger: Logger,
        executor: StrandWorkflowExecutor,
        stateBox: ArcBox<W>,
        checkpointCache: [Int: ByteBuffer],
        namespace: String,
        activationTime: Date
    ) {
        self.taskUUID = taskUUID
        self.runUUID = runUUID
        self.taskName = taskName
        self.queueName = queueName
        self.attempt = attempt
        self.claimTimeoutSeconds = claimTimeoutSeconds
        self.wakeEvent = wakeEvent
        self.eventPayload = eventPayload
        self.headers = headers
        self.schedulingMetadata = schedulingMetadata
        self.postgres = postgres
        self.logger = logger
        self.executor = executor
        self.stateBox = stateBox
        self.checkpointCache = checkpointCache
        self.activationCounter = ActivationCounter()
        self.namespace = namespace
        self.activationTime = activationTime
    }

    // MARK: - Activation sequence counter

    /// Returns the next monotonic sequence number, advancing the counter.
    func nextSeqNum() -> Int {
        activationCounter.next()
    }

    // MARK: - Checkpoint cache

    /// Returns a cached checkpoint value by seq_num, or `nil` if not yet computed this task lifetime.
    func cachedCheckpoint(for seqNum: Int) -> ByteBuffer? {
        checkpointCache[seqNum]
    }

    /// Updates the in-memory checkpoint cache only (no DB write).
    func cacheCheckpoint(seqNum: Int, buffer: ByteBuffer) {
        checkpointCache[seqNum] = buffer
    }

    // MARK: - Persistence helpers

    /// Writes a checkpoint to the DB and updates the in-memory cache.
    /// Also extends the claim lease and renews the watchdog.
    func persistCheckpoint(seqNum: Int, name: String?, buffer: ByteBuffer) async throws {
        try await Queries.setCheckpointState(
            on: postgres,
            namespaceID: namespace,
            taskID: taskUUID,
            seqNum: seqNum,
            name: name,
            stateBuffer: buffer,
            runID: runUUID,
            extendClaimBySeconds: claimTimeoutSeconds,
            logger: logger
        )
        checkpointCache[seqNum] = buffer
    }

    /// Transitions the run to SLEEPING at `wakeAt` via a DB update.
    func scheduleRun(wakeAt: Date) async throws {
        try await Queries.scheduleRun(
            on: postgres,
            namespaceID: namespace,
            runID: runUUID,
            taskID: taskUUID,
            wakeAt: wakeAt,
            logger: logger
        )
    }

    /// Extends the worker claim lease by `seconds` seconds.
    func extendClaim(by seconds: Int) async throws {
        try await Queries.extendClaim(
            on: postgres,
            namespaceID: namespace,
            runID: runUUID,
            extendBySeconds: seconds,
            logger: logger
        )
    }
}

// MARK: - WorkflowContext

/// The orchestration API surface available inside a ``Workflow/run(context:input:)`` handler.
///
/// `WorkflowContext<W>` is a lightweight struct that wraps a reference to the
/// class-backed `_WorkflowActivation<W>`. Pass it by value; all state mutations are
/// visible through the shared reference.
///
/// ## Determinism contract
/// Every operation that can block the workflow must go through a `WorkflowContext`
/// method. The context ensures:
/// - Completed steps are replayed from the checkpoint cache (no re-execution).
/// - Suspend points release the worker slot between activations.
/// - Non-deterministic values (dates, random numbers) are captured via ``uuid()``, ``random(in:)``, or ``now``.
public struct WorkflowContext<W: Workflow>: Sendable {

    // MARK: - Internal

    let _impl: _WorkflowActivation<W>

    init(activation: _WorkflowActivation<W>) {
        self._impl = activation
    }

    // MARK: - Identity properties

    /// The stable task UUID for this workflow instance (from `strand.tasks.id`).
    public var workflowID: UUID { _impl.taskUUID }

    /// The wall-clock time when this workflow task was first enqueued.
    ///
    /// Extracted from the UUIDv7 timestamp embedded in ``workflowID`` — zero cost,
    /// no extra DB column or stored state required. Unlike ``activationTime``, this
    /// value is **identical across every activation** of the same workflow instance,
    /// making it safe to use for end-to-end duration calculations:
    ///
    /// ```swift
    /// let duration = context.activationTime.timeIntervalSince(context.taskCreatedAt)
    /// ```
    ///
    /// Returns `nil` only when called on a non-v7 UUID (in practice, never).
    public var taskCreatedAt: Date? { _impl.taskUUID.v7CreatedAt }

    /// The UUID of the current run attempt (from `strand.runs.id`).
    public var runID: UUID { _impl.runUUID }

    /// Current attempt number (1-based).
    public var attempt: Int { _impl.attempt }

    /// Logger scoped to this workflow activation.
    public var logger: Logger { _impl.logger }

    /// Wall-clock time captured at the start of this activation.
    ///
    /// The value is stable within a single activation — every read returns
    /// the same `Date` — but it is **not** checkpointed. Each new activation
    /// of the same workflow instance will observe a later time, so
    /// `context.activationTime` must never drive conditional branches whose
    /// outcome needs to be the same on replay.
    ///
    /// **Safe use — computing a one-shot sleep deadline:**
    /// ```swift
    /// // On the first activation `sleep(until:)` checkpoints the target date;
    /// // on replay it reads the checkpoint, so the deadline is stable.
    /// try await context.sleep(until: context.activationTime.addingTimeInterval(3_600))
    /// ```
    ///
    /// **Unsafe use — branching on time:**
    /// ```swift
    /// // WRONG: activationTime changes between activations; the branch may
    /// // take a different path on replay, breaking determinism.
    /// if context.activationTime > cutoffDate { ... }
    /// ```
    /// For time-dependent branching that must survive replays, store the
    /// relevant timestamp as an activity result or a `sleep(until:)` target
    /// so it is durably checkpointed.
    public var activationTime: Date { _impl.activationTime }

    /// Scheduling metadata injected by ``StrandScheduler`` when this workflow was
    /// triggered by a schedule. `nil` when enqueued directly via ``StrandClient``.
    ///
    /// Decoded once when the activation is built — not on every access.
    ///
    /// - `executionTime`: the wall-clock time the schedule fired.
    /// - `partitionTime`: the data interval start for the fired period.
    ///   `nil` for one-shot schedules.
    ///
    /// ```swift
    /// mutating func run(context: WorkflowContext<Self>, input: Input) async throws -> Output {
    ///     if let meta = context.schedulingMetadata {
    ///         let start = meta.partitionTime ?? meta.executionTime
    ///         let end   = start.addingTimeInterval(86_400)
    ///         return try await context.runActivity(ProcessDataActivity.self,
    ///             input: .init(from: start, to: end))
    ///     }
    ///     // ... direct enqueue path
    /// }
    /// ```
    public var schedulingMetadata: SchedulingMetadata? { _impl.schedulingMetadata }

    // MARK: - runActivity

    /// Schedules an activity and suspends until it completes, then returns the decoded result.
    ///
    /// On replay, the result is returned immediately from the checkpoint cache without
    /// re-executing the activity or touching the DB (beyond a fast checkpoint lookup).
    ///
    /// - Parameters:
    ///   - type: The `ActivityDefinition` conforming type to schedule.
    ///   - input: Encoded and forwarded to the activity handler.
    ///   - options: Routing, retry, and timeout overrides. Inherits from workflow defaults if omitted.
    /// - Throws: `A.Failure` directly when the activity failed with a typed failure (if declared).
    ///           `ActivityError` when the activity reached a terminal error state (all retries exhausted or cancelled).
    public func runActivity<A: ActivityDefinition>(
        _ type: A.Type,
        input: A.Input,
        options: ActivityOptions = .init(),
        fileID: String = #fileID,
        line: Int = #line
    ) async throws -> A.Output {
        _impl.lastCallSite = (fileID, line)  // stamp before any throw
        let seqNum = _impl.nextSeqNum()

        // ── Fast path 1: checkpoint cache (result persisted in a prior activation) ──────
        if let cached = _impl.checkpointCache[seqNum] {
            return try JSON.decode(A.Output.self, from: cached)
        }

        // ── Fast path 2a: activity terminated with FAILED or CANCELLED in a prior activation ───
        if let nonSuccess = _impl.executor.preloadedNonCompletion(for: seqNum) {
            _impl.lastCallSite = (fileID, line)
            // Attempt to decode the original typed Failure value from the stored payload.
            // Falls back to ActivityError when Failure = Never or payload is absent.
            if let buf = nonSuccess.failureReason,
                let af = ActivityFailure.decode(from: buf),
                let typedErr = af.decode(A.Failure.self)
            {
                throw typedErr
            }
            let cause = nonSuccess.failureReason.flatMap { ActivityFailure.decode(from: $0) }
            let retryState: ActivityRetryState =
                nonSuccess.state == .cancelled ? .cancelled : .maximumAttemptsReached
            throw ActivityError(activityName: A.name, retryState: retryState, cause: cause)
        }

        // ── Fast path 2: pre-loaded by executor (activity completed this activation) ────
        // The worker called executor.resolveCompleted(_:) before drain(), pre-populating
        // results for all child activities that already finished. No DB round-trip needed.
        if let preloaded = _impl.executor.preloadedResult(for: seqNum) {
            // Cache in memory so subsequent replay within this activation hits fast path 1.
            _impl.checkpointCache[seqNum] = preloaded
            // Emit a checkpoint write so the worker persists this result after drain.
            _impl.executor.emit(.writeCheckpoint(seqNum: seqNum, name: A.name, value: preloaded))
            return try JSON.decode(A.Output.self, from: preloaded)
        }

        // ── Slow path: activity not yet complete — emit command and suspend ─────────────
        let inputBuffer = try JSON.encode(input)
        let idempotencyKey = "\(_impl.taskUUID):\(seqNum)"

        _impl.executor.emit(
            .scheduleActivity(
                name: A.name,
                input: inputBuffer,
                options: options,
                seqNum: seqNum,
                idempotencyKey: idempotencyKey
            )
        )

        // Suspend via continuation until the activity completes on the next activation.
        // The worker resumes with the real result (resumeActivity) or an
        // _ActivityFailureSignal (resumeActivityFailure) on re-activation.
        do {
            let resultBuffer: ByteBuffer = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<ByteBuffer, Error>) in
                _impl.executor.suspendActivity(seqNum: seqNum, continuation: cont)
            }
            return try JSON.decode(A.Output.self, from: resultBuffer)
        } catch let signal as _ActivityFailureSignal {
            // Re-activation delivered a typed failure signal — try to decode A.Failure.
            if let buf = signal.failureReason,
                let af = ActivityFailure.decode(from: buf),
                let typedErr = af.decode(A.Failure.self)
            {
                throw typedErr
            }
            let cause = signal.failureReason.flatMap { ActivityFailure.decode(from: $0) }
            throw ActivityError(activityName: A.name, retryState: signal.retryState, cause: cause)
        }
    }

    /// Convenience overload for activities whose `Input` is `StrandVoid` (the codable unit type).
    ///
    /// ```swift
    /// let result = try await context.runActivity(SendEmailActivity.self)
    /// ```
    public func runActivity<A: ActivityDefinition>(
        _ type: A.Type,
        options: ActivityOptions = .init(),
        fileID: String = #fileID,
        line: Int = #line
    ) async throws -> A.Output where A.Input == StrandVoid {
        try await runActivity(
            type,
            input: StrandVoid(),
            options: options,
            fileID: fileID,
            line: line
        )
    }

    // MARK: - Deterministic values
    //
    // These methods capture non-deterministic values exactly once and cache the result
    // as a durable checkpoint. On replay the cached value is returned without calling
    // the generator again — guaranteeing the workflow produces the same sequence of
    // values on every activation.
    //
    // These are the ONLY correct way to introduce non-determinism into a workflow
    // handler. For I/O (HTTP calls, DB queries, file reads) use
    // ``runActivity(_:input:options:)``.

    /// Internal: capture a pure synchronous value as a durable checkpoint.
    /// Called by ``uuid()`` and ``random(in:)`` to ensure determinism.
    ///
    /// - Note: Synchronous (`throws`, not `async throws`) — the computation must
    ///   never suspend. Emits `.writeCheckpoint` so the worker persists the value
    ///   after `drain()` without any additional DB round-trip inside the handler.
    private func _checkpoint<T: Codable & Sendable>(
        label: String?,
        compute: () -> T
    ) throws(StrandError) -> T {
        let seqNum = _impl.nextSeqNum()
        if let cached = _impl.checkpointCache[seqNum] {
            return try JSON.decode(T.self, from: cached)
        }
        let value = compute()
        let buf = try JSON.encode(value)
        _impl.checkpointCache[seqNum] = buf
        _impl.executor.emit(.writeCheckpoint(seqNum: seqNum, name: label, value: buf))
        return value
    }

    /// Returns a fresh ``UUID`` on the first call; the same UUID on every subsequent
    /// replay. Call sites are distinguished by call order — the Nth call to `uuid()`
    /// always returns the same UUID as long as the call order is stable.
    ///
    /// ```swift
    /// let orderID = try context.uuid()   // stable across replays
    /// let batchID = try context.uuid()   // different UUID, also stable
    /// ```
    /// - Throws: `StrandError.serialization` on the rare case that `UUID` fails to encode.
    public func uuid() throws(StrandError) -> UUID {
        try _checkpoint(label: "uuid") { UUID.v7() }
    }

    /// Returns a random `Int` within `range` on the first call; the cached value
    /// on every subsequent replay.
    ///
    /// ```swift
    /// let jitter = try context.random(in: 100...500)  // ms — stable across replays
    /// ```
    /// - Throws: `StrandError.serialization` on the rare case that the value fails to encode.
    public func random(in range: ClosedRange<Int>) throws(StrandError) -> Int {
        try _checkpoint(label: "random") { Int.random(in: range) }
    }

    /// Returns a random `Double` within `range` on the first call; the cached value
    /// on every subsequent replay.
    ///
    /// ```swift
    /// let ratio = try context.random(in: 0.5...2.0)  // stable across replays
    /// ```
    /// - Throws: `StrandError.serialization` on the rare case that the value fails to encode.
    public func random(in range: ClosedRange<Double>) throws(StrandError) -> Double {
        try _checkpoint(label: "random") { Double.random(in: range) }
    }

    // MARK: - sleep

    /// Suspends the workflow for at least `duration` before continuing.
    ///
    /// The worker slot is released during the sleep. On re-activation the sleep
    /// is skipped instantly (the stored wake time is read from the checkpoint cache).
    public func sleep(
        for duration: Duration,
        fileID: String = #fileID,
        line: Int = #line
    )
        async throws
    {
        _impl.lastCallSite = (fileID, line)
        let seconds =
            Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        try await sleep(until: Date.now.addingTimeInterval(seconds), fileID: fileID, line: line)
    }

    /// Suspends the workflow until at least `wakeAt` before continuing.
    ///
    /// If `wakeAt` is already in the past the call returns immediately.
    public func sleep(until wakeAt: Date, fileID: String = #fileID, line: Int = #line) async throws {
        _impl.lastCallSite = (fileID, line)
        let seqNum = _impl.nextSeqNum()

        // Resolve the actual wake time (persisted on first call so restarts honour it).
        // The checkpoint starts as the wake-time Double and is overwritten with
        // SleepCompletedSentinel when the timer fires, preventing re-emission.
        let resolvedWakeAt: Date
        if let cached = _impl.checkpointCache[seqNum] {
            // Sentinel: sleep already completed — return without emitting anything.
            if SleepCompletedSentinel.detect(in: cached) { return }
            // Wake-time checkpoint: timer not yet fired on previous activation.
            let stored = try JSON.decode(Double.self, from: cached)
            resolvedWakeAt = Date(timeIntervalSince1970: stored)
        } else {
            // First time: persist the wake time so future replays use the same instant.
            let buf = try JSON.encode(wakeAt.timeIntervalSince1970)
            _impl.checkpointCache[seqNum] = buf
            _impl.executor.emit(.writeCheckpoint(seqNum: seqNum, name: "sleep", value: buf))
            resolvedWakeAt = wakeAt
        }

        // Timer already elapsed — write completion sentinel and record TIMER_FIRED.
        if Date.now >= resolvedWakeAt {
            let sentinel = try JSON.encode(SleepCompletedSentinel())
            _impl.checkpointCache[seqNum] = sentinel
            _impl.executor.emit(.writeCheckpoint(seqNum: seqNum, name: "sleep", value: sentinel))
            _impl.executor.emit(.timerFired(seqNum: seqNum))
            return
        }

        // Slow path: timer not yet elapsed — suspend via continuation.
        _impl.executor.emit(.startTimer(wakeAt: resolvedWakeAt, seqNum: seqNum))
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            _impl.executor.suspendTimer(seqNum: seqNum, continuation: cont)
        }
        // Timer fired — write completion sentinel and record TIMER_FIRED.
        let sentinel = try JSON.encode(SleepCompletedSentinel())
        _impl.checkpointCache[seqNum] = sentinel
        _impl.executor.emit(.writeCheckpoint(seqNum: seqNum, name: "sleep", value: sentinel))
        _impl.executor.emit(.timerFired(seqNum: seqNum))
    }

    // MARK: - waitForEvent

    /// Suspends the workflow until an event named `name` is emitted, then returns its payload.
    ///
    /// On replay, the payload is returned instantly from the checkpoint cache.
    /// If `timeout` is set and elapses before the event arrives, throws `StrandError.timeout`.
    ///
    /// - Parameters:
    ///   - name: The event name to wait for (matched against `emitEvent` calls or
    ///     `client.emitEvent` calls from outside the workflow).
    ///   - type: Expected payload type. Must match what the emitter encodes.
    ///   - timeout: Optional maximum wait duration. `nil` = wait forever.
    public func waitForEvent<T: Codable & Sendable>(
        _ name: String,
        as type: T.Type,
        timeout: Duration? = nil,
        fileID: String = #fileID,
        line: Int = #line
    ) async throws -> T {
        _impl.lastCallSite = (fileID, line)
        let seqNum = _impl.nextSeqNum()

        // ── Replay fast paths ────────────────────────────────────────────────────────────

        // Checkpoint cache — either the payload or a timeout sentinel from a prior activation.
        if let cached = _impl.checkpointCache[seqNum] {
            if TimeoutSentinel.detect(in: cached) {
                throw EventWaitTimeoutError(eventName: name)
            }
            return try JSON.decode(T.self, from: cached)
        }

        // Re-activation fast path: this run was woken because our event arrived.
        if _impl.wakeEvent == name {
            if let payload = _impl.eventPayload {
                _impl.checkpointCache[seqNum] = payload
                _impl.executor.emit(
                    .writeCheckpoint(seqNum: seqNum, name: "waitForEvent:\(name)", value: payload)
                )
                _impl.executor.emit(.eventReceived(eventName: name))
                return try JSON.decode(T.self, from: payload)
            } else {
                // Woken by timeout — applyScheduleCommands writes the sentinel checkpoint
                // and EVENT_WAIT_TIMED_OUT history row atomically via writeEventWaitTimedOut.
                _impl.executor.emit(.eventWaitTimedOut(eventName: name, seqNum: seqNum))
                throw EventWaitTimeoutError(eventName: name)
            }
        }

        // ── Slow path: event not yet received — emit command and suspend ─────────────────
        let timeoutAt: Date? = timeout.map { dur in
            Date.now.addingTimeInterval(
                Double(dur.components.seconds)
                    + Double(dur.components.attoseconds) / 1_000_000_000_000_000_000
            )
        }

        _impl.executor.emit(
            .awaitEvent(
                eventName: name,  // raw name — no prefix
                seqNum: seqNum,
                timeoutAt: timeoutAt
            )
        )

        // The executor resumes this continuation with StrandError.timeout (internal)
        // when the timer fires via resumeEventWithTimeout. Convert it to the public
        // EventWaitTimeoutError so user workflows never need to catch StrandError.
        let resultBuffer: ByteBuffer
        do {
            resultBuffer = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<ByteBuffer, Error>) in
                _impl.executor.suspendEvent(seqNum: seqNum, eventName: name, continuation: cont)
            }
        } catch let err as StrandError {
            if case .timeout = err {
                _impl.executor.emit(.eventWaitTimedOut(eventName: name, seqNum: seqNum))
                throw EventWaitTimeoutError(eventName: name)
            }
            throw err
        }

        // Write a checkpoint and record EVENT_RECEIVED so that:
        // (a) crash-recovery fresh activations fast-path through this seqNum, and
        // (b) the trace view shows a complete WAIT span duration.
        // This mirrors what the re-activation fast-path does when wakeEvent == name;
        // the slow path (cached-Task continuation resume) must do the same so both
        // paths leave identical marks in strand.checkpoints and workflow_history.
        _impl.checkpointCache[seqNum] = resultBuffer
        _impl.executor.emit(
            .writeCheckpoint(seqNum: seqNum, name: "waitForEvent:\(name)", value: resultBuffer)
        )
        _impl.executor.emit(.eventReceived(eventName: name))

        return try JSON.decode(T.self, from: resultBuffer)
    }

    // MARK: - emitEvent

    /// Emits a named event on this workflow's queue, waking any tasks waiting for it.
    ///
    /// First-write-wins: if an event with the same name has already been emitted on
    /// the queue, this call is a no-op.
    ///
    /// - Parameters:
    /// Typed `WorkflowEvent` overload — the compiler enforces that the event
    /// name and payload type match between emitter and waiter.
    ///
    /// ```swift
    /// try await context.waitForEvent(OrderShippedEvent.self)
    /// ```
    public func waitForEvent<E: WorkflowEvent>(
        _ eventType: E.Type,
        timeout: Duration? = nil
    ) async throws -> E.Payload {
        try await waitForEvent(E.name, as: E.Payload.self, timeout: timeout)
    }

    /// Typed `WorkflowEvent` overload for emitting — derives the event name from
    /// the event type so the compiler catches mismatches at the call site.
    ///
    /// ```swift
    /// try await context.emitEvent(OrderShippedEvent.self,
    ///     payload: TrackingInfo(number: "1Z999"))
    /// ```
    public func emitEvent<E: WorkflowEvent>(
        _ eventType: E.Type,
        payload: E.Payload
    ) throws {
        try emitEvent(E.name, payload: payload)
    }

    /// Emits a named event on this workflow's queue.
    ///
    /// This method is **non-suspending**: it enqueues a ``WorkflowCommand/emitEvent``
    /// command and returns immediately. The actual Postgres write happens in
    /// `applyScheduleCommands` after `drain()` returns, keeping the handler body
    /// free of direct DB I/O and preserving the deterministic drain-loop invariant.
    ///
    /// First-write-wins: if an event with the same name already exists on the
    /// queue (e.g. from a previous activation that completed this step before a
    /// crash), the command is a safe no-op.
    public func emitEvent(_ name: String, payload: some Codable & Sendable) throws {
        // JSON-encode synchronously — no await, no DB, no suspension.
        let buf = try JSON.encode(payload)
        _impl.executor.emit(.emitEvent(name: name, payload: buf))
    }

    // MARK: - condition

    /// Suspends the workflow until the predicate on current workflow state evaluates `true`.
    ///
    /// Evaluated immediately against the post-signal state — if already `true`, returns
    /// without suspending. Otherwise the run goes `WAITING`; it is re-activated when any
    /// signal arrives (via ``WorkflowHandle/signal(name:)``). The predicate is re-evaluated
    /// at the start of every subsequent activation until it becomes `true`.
    ///
    /// ```swift
    /// struct OrderWorkflow: Workflow {
    ///     var isPaused = false
    ///
    ///     mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
    ///         if name == "pause"  { isPaused = true  }
    ///         if name == "resume" { isPaused = false }
    ///     }
    ///
    ///     mutating func run(context: WorkflowContext<Self>, input: Input) async throws -> Output {
    ///         // Block until a "resume" signal clears the pause flag.
    ///         try await context.condition { !$0.isPaused }
    ///         // ... continue workflow logic ...
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter predicate: A closure that reads (not mutates) workflow state and
    ///   returns `true` when the condition is satisfied. Must be `@Sendable`.
    public func condition(_ predicate: @escaping @Sendable (W) -> Bool) async throws {
        // Two-phase predicate registration:
        //
        // 1. Register the predicate as a `() -> Bool` closure that reads `stateBox`
        //    via `withValue`. The closure is stored WITHOUT being evaluated —
        //    evaluation happens post-drain, after `run()` has suspended and no longer
        //    holds exclusive access on `stateBox.value`.
        //
        // 2. Suspend via `withCheckedThrowingContinuation`. The continuation is linked
        //    to the entry immediately (still during `drain()`).
        //
        // 3. The worker's post-drain condition-check loop calls
        //    `evaluateAndResumeFirstSatisfiedCondition()`. If the predicate is `true`
        //    the continuation is resumed and the handler continues; if `false` the
        //    worker applies WAITING to the DB and the activation ends.
        let stateBox = _impl.stateBox
        let id = _impl.executor.registerCondition {
            stateBox.withValue { predicate($0) }
        }
        // The no-timeout overload is always resumed with true (predicate satisfied);
        // we discard the Bool since there is no timeout path to return false.
        _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            _impl.executor.linkConditionContinuation(cont, forID: id)
        }
        // No seqNum / no completion sentinel — no-timeout conditions have no checkpoint
        // guard, so conditionMet may appear more than once in history across replays.
        // This is benign: ON CONFLICT DO NOTHING in appendHistory prevents duplicate rows
        // for the same seq, and executionHistorySpansForTrace uses only the first CONDITION_MET.
        _impl.executor.emit(.conditionMet(seqNum: nil))
    }

    /// Suspends the workflow until `predicate` evaluates `true` on current state,
    /// or until `timeout` elapses.
    ///
    /// Returns `true` if the predicate was satisfied, `false` if the deadline elapsed
    /// before it became true. Both outcomes are normal — timeout is not an error.
    ///
    /// Evaluated immediately on entry. If already `true`, returns `true` immediately
    /// without suspension. After a signal mutates state the predicate is re-evaluated;
    /// if still `false` and the deadline has not passed the workflow suspends again.
    ///
    /// ```swift
    /// let paused = try await context.condition({ !$0.isPaused }, timeout: .seconds(86400))
    /// // paused == false means the 24 h window elapsed without a resume signal
    /// ```
    ///
    /// - Parameters:
    ///   - predicate: A closure that reads (not mutates) workflow state and
    ///     returns `true` when the condition is satisfied. Must be `@Sendable`.
    ///   - timeout: Maximum duration to wait. When elapsed, returns `false`.
    /// - Returns: `true` when the predicate was satisfied; `false` on timeout.
    @discardableResult
    public func condition(
        _ predicate: @escaping @Sendable (W) -> Bool,
        timeout: Duration
    ) async throws -> Bool {
        // Checkpoint the deadline once so it's stable across activations.
        let seqNum = _impl.nextSeqNum()
        let wakeAt: Date
        if let cached = _impl.checkpointCache[seqNum] {
            // Completion sentinel — condition already resolved in a prior activation.
            if let result = ConditionResultSentinel.detect(in: cached) {
                return result
            }
            // Not a completion sentinel: must be the deadline timestamp.
            let ts = (try? JSON.decode(Double.self, from: cached)) ?? 0
            wakeAt = Date(timeIntervalSince1970: ts)
        } else {
            let seconds =
                Double(timeout.components.seconds)
                + Double(timeout.components.attoseconds) / 1_000_000_000_000_000_000
            wakeAt = Date.now.addingTimeInterval(seconds)
            let buf = try JSON.encode(wakeAt.timeIntervalSince1970)
            _impl.checkpointCache[seqNum] = buf
            _impl.executor.emit(
                .writeCheckpoint(seqNum: seqNum, name: "conditionDeadline", value: buf)
            )
        }

        // Deadline already passed — re-activation after the sleep timer fired
        // with the predicate still `false`. Return false immediately.
        // Emit conditionTimedOut so applyScheduleCommands writes the completion
        // sentinel and CONDITION_TIMED_OUT history row atomically.
        if Date.now >= wakeAt {
            _impl.executor.emit(.conditionTimedOut(seqNum: seqNum))
            return false
        }

        // Same post-drain pattern as the no-timeout overload, with `wakeAt` attached
        // so the worker can apply SLEEPING (not WAITING) to the DB.
        let stateBox = _impl.stateBox
        let id = _impl.executor.registerCondition(
            predicate: { stateBox.withValue { predicate($0) } },
            wakeAt: wakeAt,
            timeout: timeout
        )
        let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            _impl.executor.linkConditionContinuation(cont, forID: id)
        }
        // Record the result so applyScheduleCommands writes sentinel + history atomically.
        if result {
            _impl.executor.emit(.conditionMet(seqNum: seqNum))
        } else {
            _impl.executor.emit(.conditionTimedOut(seqNum: seqNum))
        }
        return result
    }

    // MARK: - continueAsNew

    /// Terminates the current workflow instance and immediately enqueues a new
    /// one with the same type and queue but a fresh input and clean checkpoint state.
    ///
    /// Use this to prevent unbounded checkpoint growth in long-running loops:
    ///
    /// ```swift
    /// mutating func run(context: WorkflowContext<Self>, input: Input) async throws -> Output {
    ///     if checkpoints.count > 1_000 {
    ///         try context.continueAsNew(input: Input(recentCheckpoints: checkpoints.suffix(50)))
    ///     }
    ///     // ... normal workflow logic ...
    /// }
    /// ```
    ///
    /// - Parameter input: The input for the new workflow instance.
    /// - Returns: Never — always throws `_ContinueAsNewSignal`.
    public func continueAsNew(input: W.Input) throws -> Never {
        let encoded = try JSON.encode(input)
        throw _ContinueAsNewSignal(
            workflowName: W.workflowName,
            namespaceID: _impl.namespace,
            queue: _impl.queueName,
            input: encoded
        )
    }

    // MARK: - runLocalActivity

    /// Executes an activity in-process within the current activation — no DB task
    /// row, no queue round-trip, no independent retry.
    ///
    /// Identical in API to `runActivity` but runs on the **same worker process and
    /// same activation**. If the activity throws the whole activation fails.
    ///
    /// Suitable for fast, pure computation (hashing, encoding, cache reads) where
    /// the overhead of a queued activity is unnecessary.
    ///
    /// ```swift
    /// let digest = try await context.runLocalActivity(ComputeHashActivity.self,
    ///                                                  input: rawBytes)
    /// ```
    ///
    /// - Parameters:
    ///   - type: The `ActivityDefinition` conforming type to execute.
    ///   - input: Forwarded verbatim to the activity handler.
    ///   - options: Execution options (reserved for future use).
    public func runLocalActivity<A: ActivityDefinition>(
        _ type: A.Type,
        input: A.Input,
        options: LocalActivityOptions = .init()
    ) async throws -> A.Output {
        let seqNum = _impl.nextSeqNum()

        // Replay fast path: result already persisted in a prior activation.
        if let cached = _impl.checkpointCache[seqNum] {
            return try JSON.decode(A.Output.self, from: cached)
        }

        // Schedule for in-process execution post-drain.
        let inputBuffer = try JSON.encode(input)
        let id = _impl.executor.scheduleLocalActivity(
            name: A.name,
            input: inputBuffer,
            seqNum: seqNum
        )
        let result = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<ByteBuffer, Error>) in
            _impl.executor.linkLocalActivityContinuation(cont, forID: id)
        }
        return try JSON.decode(A.Output.self, from: result)
    }

    /// Convenience overload for activities with no input (`StrandVoid`).
    public func runLocalActivity<A: ActivityDefinition>(
        _ type: A.Type,
        options: LocalActivityOptions = .init()
    ) async throws -> A.Output where A.Input == StrandVoid {
        try await runLocalActivity(type, input: .done, options: options)
    }

    // MARK: - version

    /// Records whether this workflow instance first encountered `changeID` under
    /// new code, enabling safe deployment of logic changes while workflows are in-flight.
    ///
    /// Returns `true` the first time this code path is reached by this workflow instance,
    /// then replays that same stored value on every subsequent activation.
    ///
    /// ```swift
    /// // Deploying a new activity implementation:
    /// if try context.version(changeID: "v2-payment-processor") {
    ///     // New workflows and in-flight workflows reaching this for the first time
    ///     // will use the new path and store 'true' as the checkpoint.
    ///     let r = try await context.runActivity(NewPaymentActivity.self, input: input)
    /// } else {
    ///     // In-flight workflows that already stored 'false' replay the old path.
    ///     let r = try await context.runActivity(LegacyPaymentActivity.self, input: input)
    /// }
    /// ```
    ///
    /// ## Determinism constraint
    ///
    /// `version(changeID:)` consumes a **sequence number** from the same monotonic
    /// counter as `runActivity`, `sleep`, and `waitForEvent`. It must be called at the
    /// **same unconditional position** in the control flow on every activation of this
    /// workflow instance. Placing it inside a branch whose condition can change between
    /// activations (e.g. a signal-mutated flag) shifts all downstream sequence numbers
    /// and corrupts checkpoint replay.
    ///
    /// ```swift
    /// // ✗ WRONG — only reached when isPaused is true; downstream seqNums shift.
    /// if isPaused {
    ///     let _ = try context.version(changeID: "v2-feature")
    /// }
    ///
    /// // ✓ CORRECT — always reached; return value drives the branch.
    /// let useV2 = try context.version(changeID: "v2-feature")
    /// if isPaused && useV2 { ... }
    /// ```
    ///
    /// For a full deployment guide — including `markVersion`, multi-step migrations,
    /// and strategy selection — see <doc:VersioningGuide>.
    ///
    /// - Parameter changeID: A stable, unique string identifying this code change point.
    ///   Use a descriptive name like `"v2-add-notification"` — it must never be reused
    ///   for a different change in the same workflow.
    /// - Returns: `true` on the first encounter; the stored value on replay.
    /// - Throws: `StrandError.serialization` if the version checkpoint cannot be encoded.
    public func version(changeID: String) throws(StrandError) -> Bool {
        let seqNum = _impl.nextSeqNum()

        // Replay fast path — return the value stored when this was first reached.
        if let cached = _impl.checkpointCache[seqNum] {
            return (try? JSON.decode(Bool.self, from: cached)) ?? true
        }

        // First time: store `true` (this activation is running the new code) and return it.
        let buf = try JSON.encode(true)
        _impl.checkpointCache[seqNum] = buf
        _impl.executor.emit(.writeCheckpoint(seqNum: seqNum, name: changeID, value: buf))
        return true
    }

    // MARK: - runChildWorkflow

    /// Enqueues a child workflow and suspends until it completes, then returns its result.
    ///
    /// Semantically identical to `runActivity` but the child is a full `Workflow`
    /// orchestrator rather than a leaf activity. The parent is suspended while the
    /// child runs; it is re-activated when the child reaches a terminal state.
    ///
    /// On replay, the result is returned instantly from the checkpoint cache.
    ///
    /// - Parameters:
    ///   - type: The `Workflow` conforming type to enqueue as a child.
    ///   - options: Queue, priority, and concurrency overrides.
    ///   - input: Forwarded verbatim to the child workflow handler.
    /// - Throws: `StrandError.childWorkflowFailed` when the child reached a terminal error state.
    public func runChildWorkflow<CW: Workflow>(
        _ type: CW.Type,
        options: ChildWorkflowOptions = .init(),
        input: CW.Input
    ) async throws -> CW.Output {
        let seqNum = _impl.nextSeqNum()

        // Fast path 1: checkpoint cache (result from a prior activation)
        if let cached = _impl.checkpointCache[seqNum] {
            return try JSON.decode(CW.Output.self, from: cached)
        }

        // Fast path 2a: child workflow terminated with FAILED or CANCELLED in a prior activation.
        if let nonSuccess = _impl.executor.preloadedNonCompletion(for: seqNum) {
            throw StrandError.childWorkflowFailed(
                name: CW.workflowName,
                state: nonSuccess.state.rawValue
            )
        }

        // Fast path 2: pre-loaded result (child completed in a prior activation).
        // loadCompletedChildActivities covers child workflows too (same parent_task_id JOIN).
        // A checkpoint is written here so subsequent replays use fast path 1.
        if let preloaded = _impl.executor.preloadedResult(for: seqNum) {
            _impl.checkpointCache[seqNum] = preloaded
            _impl.executor.emit(
                .writeCheckpoint(seqNum: seqNum, name: CW.workflowName, value: preloaded)
            )
            _impl.executor.emit(.childWorkflowCompleted(name: CW.workflowName, seqNum: seqNum))
            return try JSON.decode(CW.Output.self, from: preloaded)
        }

        // Slow path: child not yet complete — emit command and suspend via continuation.
        let inputBuffer = try JSON.encode(input)
        let idempotencyKey = "\(_impl.taskUUID):\(seqNum)"
        // Note: options.headers forwarding intentionally omitted from the command —
        // the worker injects parent context headers when enqueuing the child task.

        _impl.executor.emit(
            .scheduleChildWorkflow(
                name: CW.workflowName,
                queue: options.queue,
                input: inputBuffer,
                seqNum: seqNum,
                idempotencyKey: idempotencyKey,
                priority: options.priority,
                maxAttempts: options.maxAttempts,
                fairnessKey: options.fairnessKey,
                fairnessWeight: options.fairnessWeight,
                retryStrategy: options.retryStrategy,
                scheduledAt: options.delayUntil
            )
        )

        do {
            let resultBuffer: ByteBuffer = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<ByteBuffer, Error>) in
                _impl.executor.suspendActivity(seqNum: seqNum, continuation: cont)
            }
            // Slow path: continuation resumed — child completed in this activation.
            // Write a checkpoint so replays use fast path 1.
            _impl.checkpointCache[seqNum] = resultBuffer
            _impl.executor.emit(
                .writeCheckpoint(seqNum: seqNum, name: CW.workflowName, value: resultBuffer)
            )
            _impl.executor.emit(.childWorkflowCompleted(name: CW.workflowName, seqNum: seqNum))
            return try JSON.decode(CW.Output.self, from: resultBuffer)
        } catch let signal as _ActivityFailureSignal {
            throw StrandError.childWorkflowFailed(
                name: CW.workflowName,
                state: signal.state.rawValue
            )
        }
    }
}
