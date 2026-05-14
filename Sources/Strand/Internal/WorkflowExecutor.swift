import DequeModule
import NIOCore

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - WorkflowCommand
//
// A pure value type describing one operation the handler wants to perform.
// No DB handles, no continuations — just data. The worker reads this after
// drain() and applies each command to Postgres atomically.

/// A command emitted by the workflow handler during activation.
///
/// All `WorkflowContext` operations (runActivity, sleep, waitForEvent, uuid, random)
/// emit a `WorkflowCommand` into the executor's buffer instead of writing to the DB
/// directly. After `drain()` the worker applies every command atomically — making
/// the handler body 100% free of DB I/O.
enum WorkflowCommand: Sendable {
    /// Schedule an activity and suspend until it completes (or pre-load fast path).
    case scheduleActivity(
        name: String,
        input: ByteBuffer,
        options: ActivityOptions,
        seqNum: Int,  // monotonic activation counter — unique per command within this activation
        idempotencyKey: String
    )

    /// Schedule a durable timer and suspend until it fires.
    case startTimer(wakeAt: Date, seqNum: Int)

    /// Register a named-event wait and suspend until the event arrives.
    case awaitEvent(eventName: String, seqNum: Int, timeoutAt: Date?)

    /// Persist a computed value as a checkpoint (uuid/random result or activity fast-path).
    /// Non-suspending — the handler continues immediately after emitting this.
    /// `name` is optional debug metadata — not used as a lookup key.
    case writeCheckpoint(seqNum: Int, name: String?, value: ByteBuffer)

    /// Emitted by `sleep(until:)` when the timer has already elapsed on re-activation
    /// (replay fast-path). Non-suspending — the worker writes a TIMER_FIRED history event.
    case timerFired(seqNum: Int)

    /// Emitted by `waitForEvent` when the run was woken by a matching event payload
    /// (replay fast-path). Non-suspending — the worker writes an EVENT_RECEIVED history event.
    case eventReceived(eventName: String)

    /// Emitted by `waitForEvent` when the deadline elapsed without an event arriving.
    /// Carries `seqNum` so `applyScheduleCommands` can write the TimeoutSentinel
    /// checkpoint and `EVENT_WAIT_TIMED_OUT` history row atomically.
    case eventWaitTimedOut(eventName: String, seqNum: Int)

    /// Emitted by `condition(_:timeout:)` when the predicate became true.
    /// `seqNum` is non-nil only for the timeout variant — used by `applyScheduleCommands`
    /// to write the `ConditionResultSentinel` checkpoint and `CONDITION_MET` history row
    /// atomically. `nil` for the no-timeout `condition(_:)` overload (no checkpoint guard).
    case conditionMet(seqNum: Int?)

    /// Emitted by `condition(_:timeout:)` when the deadline elapsed.
    /// Always carries `seqNum` (the deadline checkpoint slot) so `applyScheduleCommands`
    /// can atomically write the `ConditionResultSentinel` and `CONDITION_TIMED_OUT`.
    case conditionTimedOut(seqNum: Int)

    /// Records that a child workflow result was delivered to the handler.
    /// Non-suspending — processed by the step-2 loop to write a `CHILD_WORKFLOW_COMPLETED`
    /// history event. A checkpoint is written alongside this command so the same
    /// seqNum returns via fast-path-1 on all future replays without re-emitting.
    case childWorkflowCompleted(name: String, seqNum: Int)

    /// Emits a named event on the workflow's queue.
    ///
    /// Non-suspending: the handler continues immediately after emitting this command.
    /// `applyScheduleCommands` writes the event to `strand.events` after `drain()` returns,
    /// keeping the handler body 100% free of DB I/O.
    ///
    /// First-write-wins semantics apply: if an event with the same
    /// `(namespace_id, queue, name)` already exists with a non-null payload this
    /// is a no-op (idempotent replay safety).
    case emitEvent(name: String, payload: ByteBuffer)

    /// Schedule a child workflow and suspend until it completes.
    case scheduleChildWorkflow(
        name: String,
        queue: String?,  // nil = inherit orchestrator's queue
        input: ByteBuffer,
        seqNum: Int,  // monotonic activation counter — unique per command within this activation
        idempotencyKey: String,
        priority: TaskPriority,  // .normal when unspecified
        maxAttempts: Int?,  // nil = worker default
        fairnessKey: String?,  // nil = no per-tenant isolation
        fairnessWeight: Double,  // 1.0 = default weight
        retryStrategy: RetryStrategy?,  // nil = worker default
        scheduledAt: Date?,  // nil = immediately
        deadlineAt: Date?  // nil = no total execution budget
    )
}

// MARK: - StrandWorkflowExecutor

/// The deterministic serial executor for workflow activations.
///
/// One instance is created per workflow type at registration time and stored in
/// `_WorkflowTaskCache<W>`. The handler `Task` stays alive between activations,
/// parked on `CheckedContinuation`s here. On re-activation the worker calls the
/// Resume API (`resumeActivity`, `resumeAllTimers`, etc.) to deliver real results,
/// then calls `drain()` to continue the handler from where it paused.
///
/// **Why `@unchecked Sendable`**
///
/// All access occurs on the drain loop caller's thread. Never share this object
/// across concurrent tasks or call `drain()` from two threads at once.
/// A local activity scheduled for in-process execution post-drain.
struct LocalActivityEntry {
    /// Registered activity name, used to look up the runner in `_WorkerExec`.
    let name: String
    /// JSON-encoded input passed to the activity handler.
    let input: ByteBuffer
    /// Activation sequence number — result is persisted here so re-activations fast-path it.
    let seqNum: Int
    /// Parked continuation. Linked immediately after the task suspends.
    var continuation: CheckedContinuation<ByteBuffer, Error>?
}

/// One registered condition: a predicate to be evaluated post-drain and the
/// continuation to resume when it is satisfied.
struct ConditionEntry {
    /// Reads `stateBox` via `withValue`. Evaluated only after `drain()` returns,
    /// when `run()` has suspended and no longer holds exclusive access on the box.
    let predicate: @Sendable () -> Bool
    /// Deadline for `condition(_:timeout:)` waits; `nil` for indefinite conditions.
    let wakeAt: Date?
    /// Original timeout duration — used only for the error message in
    /// `resumeExpiredConditions()` to match the fresh-activation message exactly.
    let timeout: Duration?
    /// Parked continuation. Linked immediately after the task suspends via
    /// `linkConditionContinuation(_:forID:)`.
    /// Resumed with `true` when the predicate is satisfied, `false` on timeout.
    var continuation: CheckedContinuation<Bool, Error>?
}

final class StrandWorkflowExecutor: TaskExecutor & SerialExecutor, @unchecked Sendable {

    // MARK: - Job queue

    /// Jobs buffered by `enqueue(_:)`. Processed in FIFO order by `drain()`.
    ///
    /// `Deque` (from swift-collections) provides O(1) `popFirst()` AND O(1) `append()`.
    /// `ContiguousArray.removeFirst()` is O(n) — it shifts every element down on each
    /// dequeue. For a workflow that fans out many activities the difference is material.
    private var jobQueue: Deque<UnownedJob> = {
        var d = Deque<UnownedJob>()
        d.reserveCapacity(64)  // pre-size for the average workflow fan-out
        return d
    }()

    /// Guards against re-entrant calls to `drain()`.
    /// A job running inside the drain loop must never call `drain()` again.
    private var isDraining = false

    // MARK: - Pre-loaded results (set before drain, read by emitScheduleActivity)

    /// Activity results already known before this activation.
    /// Keyed by seq_num — the monotonic activation counter assigned when the
    /// operation was first scheduled.
    ///
    /// When `WorkflowContext.runActivity` finds a hit here it emits a `writeCheckpoint`
    /// command and returns immediately — no suspension, no DB round-trip.
    /// This is the replay fast path that makes re-activations idempotent.
    private var preloadedResults: [Int: ByteBuffer] = [:]

    /// Terminal non-success states for child activities/workflows (FAILED, CANCELLED).
    /// Keyed by seq_num → `(state, failureReason)`. Checked by fast path 2a in
    /// `runActivity` and `runChildWorkflow`: if present, throw immediately instead of
    /// registering an event_wait after the completion signal already fired.
    private var preloadedNonCompletions: [Int: (state: TaskState, failureReason: ByteBuffer?)] =
        [:]

    // MARK: - Commands (accumulated during drain, applied by worker after drain)

    /// Commands emitted by the handler during this activation.
    /// Read by the worker after `drain()` returns.
    private(set) var pendingCommands: [WorkflowCommand] = []

    // MARK: - Continuations (indexed by checkpoint name)

    /// Activity continuations parked by `suspendActivity(seqNum:continuation:)`.
    private var activityContinuations: [Int: CheckedContinuation<ByteBuffer, Error>] = [:]
    /// Timer continuations parked by `suspendTimer(seqNum:continuation:)`.
    private var timerContinuations: [Int: CheckedContinuation<Void, Error>] = [:]
    /// Event-wait continuations parked by `suspendEvent(seqNum:eventName:continuation:)`.
    private var eventContinuations: [Int: CheckedContinuation<ByteBuffer, Error>] = [:]
    /// Maps event name → seqNum for parked event continuations.
    /// Populated by `suspendEvent`; lets the worker look up the right continuation
    /// when a named event fires on a cached re-activation.
    private var eventNameToSeqNum: [String: Int] = [:]
    /// Condition entries keyed by auto-incrementing ID. Each entry stores the
    /// predicate closure and (after the task suspends) its continuation.
    /// Predicates are evaluated POST-drain so `stateBox.value` is never read
    /// while `run()` holds exclusive access.
    private var conditionEntries: [Int: ConditionEntry] = [:]
    private var nextConditionID: Int = 0

    // MARK: - Local activity tracking
    //
    // Local activities run in-process within the same activation (no DB task row).
    // Registration is split across two steps that both happen during drain():
    //   Step 1 — scheduleLocalActivity(): records the entry and parks a continuation.
    //   Step 2 — post-drain: the worker executes the activity, checkpoints the result,
    //             then calls resolveLocalActivity() / failLocalActivity() to resume.
    private(set) var localActivityEntries: [Int: LocalActivityEntry] = [:]
    private var nextLocalActivityID: Int = 0

    // MARK: - TaskExecutor / SerialExecutor conformance

    /// Buffer a Swift concurrency job for later synchronous execution by `drain()`.
    ///
    /// The Swift runtime calls this whenever it needs to schedule work on this
    /// executor: task creation, resumption after `await`, child-task completion, etc.
    /// The job is stored rather than executed immediately so that `drain()` can
    /// control the exact moment of execution and guarantee a deterministic total order
    /// over all jobs within one activation.
    func enqueue(_ job: consuming ExecutorJob) {
        jobQueue.append(UnownedJob(job))
        // DO NOT drain here — the worker calls drain() explicitly.
    }

    /// Returns an unowned reference to `self` as a `SerialExecutor`.
    ///
    /// Passing `complexEquality: self` tells the runtime to call
    /// `isSameExclusiveExecutionContext(other:)` for actor-hop elision checks,
    /// rather than falling back to simple pointer equality.
    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(complexEquality: self)
    }

    /// Returns an unowned reference to `self` as a `TaskExecutor`.
    ///
    /// `ordinary:` is the designated initializer for task executors that do not
    /// require special scheduling semantics (macOS 26 / Swift 6.3).
    func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }

    /// Confirms that `other` is the same exclusive execution context as `self`.
    ///
    /// Called by the runtime because we registered with `complexEquality:` in
    /// `asUnownedSerialExecutor()`. We compare the raw byte representation of both
    /// executor words — semantically equivalent to `UnownedSerialExecutor.==`
    /// without requiring `Equatable` conformance.
    func isSameExclusiveExecutionContext(other: UnownedSerialExecutor) -> Bool {
        // `UnownedSerialExecutor` has a stdlib `==` but is not `Equatable`;
        // compare underlying storage bytes directly.
        var ours = asUnownedSerialExecutor()
        var theirs = other
        return withUnsafeBytes(of: &ours) { a in
            withUnsafeBytes(of: &theirs) { b in a.elementsEqual(b) }
        }
    }

    // MARK: - Drain

    /// Run all buffered jobs synchronously until the queue is empty.
    ///
    /// This is the core of the deterministic activation model. On entry the handler
    /// task (and any `async let` child tasks) have been enqueued but not yet run.
    /// Each call to `runSynchronously(isolatedTo:taskExecutor:)` advances one job to
    /// its next suspension point. Jobs that spawn child tasks or resume continuations
    /// enqueue further jobs synchronously; those are picked up by the next iteration.
    ///
    /// When `drain()` returns the queue is empty and every task has either:
    ///   - **Completed**: the handler result is available externally.
    ///   - **Suspended**: a continuation is stored via one of the `suspend*` methods,
    ///     waiting for an activity result, timer, or event.
    ///
    /// Read `pendingCommands` after this call to discover what the worker needs to
    /// write to Postgres.
    func drain() {
        guard !isDraining else {
            // Re-entrant drain is a programming error: a job running inside the
            // drain loop must not call drain() again.
            return
        }
        isDraining = true
        defer { isDraining = false }

        while let job = jobQueue.popFirst() {
            // O(1) dequeue with Deque. New jobs enqueued during execution of this
            // job are appended to the back and processed in subsequent iterations.
            job.runSynchronously(
                isolatedTo: asUnownedSerialExecutor(),
                taskExecutor: asUnownedTaskExecutor()
            )
        }
    }

    // MARK: - Pre-load API (called by worker before drain)

    /// Pre-populate completed activity results from Postgres.
    ///
    /// Call this BEFORE creating the handler task and calling `drain()`. Typically
    /// the worker reads terminal checkpoints from `strand.task_completions` and passes
    /// them here. Both COMPLETED (result buffer) and FAILED (nil buffer) entries are
    /// included so the fast path can handle failures without hitting the slow path.
    func resolveCompleted(
        _ completions: [(
            seqNum: Int, result: ByteBuffer?, failureReason: ByteBuffer?,
            state: TaskState, kind: TaskKind, name: String
        )]
    ) {
        for (seqNum, result, failureReason, state, _, _) in completions {
            switch state {
            case .completed:
                if let result { preloadedResults[seqNum] = result }
            case .failed, .cancelled:
                preloadedNonCompletions[seqNum] = (state: state, failureReason: failureReason)
            default:
                break  // task_completions only holds terminal states; ignore anything unexpected
            }
        }
    }

    /// Returns the pre-loaded result for `seqNum`, or `nil` if not available.
    /// Called by `WorkflowContext.runActivity` and `runChildWorkflow` on every
    /// call. A non-nil return means the activity completed in a prior activation and
    /// its result was persisted to Postgres; the handler can proceed without suspension.
    func preloadedResult(for seqNum: Int) -> ByteBuffer? {
        preloadedResults[seqNum]
    }

    /// Returns the terminal non-success entry `(state, failureReason)` for
    /// `seqNum`, or `nil` if the activity succeeded or hasn't completed yet.
    /// Fast path 2a in `runActivity` / `runChildWorkflow` uses this to throw the
    /// correct typed error instead of registering an event_wait that never fires.
    func preloadedNonCompletion(
        for seqNum: Int
    ) -> (
        state: TaskState, failureReason: ByteBuffer?
    )? {
        preloadedNonCompletions[seqNum]
    }

    // MARK: - Command emission API (called by WorkflowContext methods during drain)

    /// Append a command to the pending list.
    ///
    /// Called synchronously on the executor by `WorkflowContext` methods — safe
    /// without locks because all access is confined to the drain loop caller.
    func emit(_ command: WorkflowCommand) {
        pendingCommands.append(command)
    }

    // MARK: - Local activity API

    /// Register a local activity for in-process execution post-drain. Returns an ID
    /// that is used to link the `CheckedContinuation` and later resolve the result.
    func scheduleLocalActivity(name: String, input: ByteBuffer, seqNum: Int) -> Int {
        let id = nextLocalActivityID
        nextLocalActivityID += 1
        localActivityEntries[id] = LocalActivityEntry(
            name: name,
            input: input,
            seqNum: seqNum
        )
        return id
    }

    /// Attach the continuation immediately after the task suspends
    /// (called synchronously from within `withCheckedThrowingContinuation`).
    func linkLocalActivityContinuation(
        _ cont: CheckedContinuation<ByteBuffer, Error>,
        forID id: Int
    ) {
        localActivityEntries[id]?.continuation = cont
    }

    /// Resume a local activity’s continuation with a successful result and remove its entry.
    func resolveLocalActivity(id: Int, result: ByteBuffer) {
        if let entry = localActivityEntries.removeValue(forKey: id) {
            entry.continuation?.resume(returning: result)
        }
    }

    /// Resume a local activity’s continuation with an error and remove its entry.
    func failLocalActivity(id: Int, error: Error) {
        if let entry = localActivityEntries.removeValue(forKey: id) {
            entry.continuation?.resume(throwing: error)
        }
    }

    // MARK: - Suspension API (called by WorkflowContext to park a task)

    /// Store an activity continuation. The task suspends after this returns.
    ///
    /// The continuation stays parked until `resumeActivity(seqNum:result:)` or
    /// `resumeActivityFailure(seqNum:error:)` is called on re-activation.
    func suspendActivity(
        seqNum: Int,
        continuation: CheckedContinuation<ByteBuffer, Error>
    ) {
        activityContinuations[seqNum] = continuation
    }

    /// Store a timer continuation. The task suspends after this returns.
    func suspendTimer(
        seqNum: Int,
        continuation: CheckedContinuation<Void, Error>
    ) {
        timerContinuations[seqNum] = continuation
    }

    /// Store an event-wait continuation. The task suspends after this returns.
    /// `eventName` is recorded so the worker can resume this continuation by name
    /// on a cached re-activation (see `seqNum(forEventName:)` and `resumeEvent`).
    func suspendEvent(
        seqNum: Int,
        eventName: String,
        continuation: CheckedContinuation<ByteBuffer, Error>
    ) {
        eventContinuations[seqNum] = continuation
        eventNameToSeqNum[eventName] = seqNum
    }

    // MARK: - Resume API
    //
    // Called by the worker on re-activation to deliver real results to the parked
    // continuations. After calling the appropriate resume method(s), the worker
    // calls drain() to continue the handler from where it paused.
    // All access is from a single drain() caller — no locking needed.

    /// Resume an activity or child-workflow continuation with a successful result.
    func resumeActivity(seqNum: Int, result: ByteBuffer) {
        activityContinuations.removeValue(forKey: seqNum)?.resume(returning: result)
    }

    /// Resume an activity or child-workflow continuation with a failure error.
    func resumeActivityFailure(seqNum: Int, error: Error) {
        activityContinuations.removeValue(forKey: seqNum)?.resume(throwing: error)
    }

    /// Resume all parked timer continuations (timer elapsed; run woken from SLEEPING).
    /// In normal operation at most one timer is active at a time.
    func resumeAllTimers() {
        let keys = Array(timerContinuations.keys)
        for seqNum in keys {
            timerContinuations.removeValue(forKey: seqNum)?.resume()
        }
    }

    /// Resume the event continuation identified by `seqNum` with the delivered payload.
    func resumeEvent(seqNum: Int, payload: ByteBuffer) {
        eventContinuations.removeValue(forKey: seqNum)?.resume(returning: payload)
        eventNameToSeqNum = eventNameToSeqNum.filter { $1 != seqNum }
    }

    /// Resume the event continuation for `eventName` with a timeout error (no payload arrived).
    func resumeEventWithTimeout(seqNum: Int, eventName: String) {
        eventContinuations.removeValue(forKey: seqNum)?
            .resume(throwing: StrandError.timeout(message: "Timed out waiting for event \"\(eventName)\""))
        eventNameToSeqNum.removeValue(forKey: eventName)
    }

    /// Returns the seqNum for the parked event continuation registered under `name`, or `nil`.
    func seqNum(forEventName name: String) -> Int? {
        eventNameToSeqNum[name]
    }

    /// Resume any condition continuations whose deadlines have elapsed.
    /// Returns `true` when at least one was resumed (caller should `drain()` and loop).
    func resumeExpiredConditions() -> Bool {
        let now = Date()
        for (id, entry) in conditionEntries {
            if let wakeAt = entry.wakeAt, now >= wakeAt {
                conditionEntries.removeValue(forKey: id)
                // Timeout is normal control flow — resume with false so the
                // caller can decide what to do (e.g. auto-approve after SLA).
                entry.continuation?.resume(returning: false)
                return true
            }
        }
        return false
    }

    /// Discard all accumulated commands from a previous activation before resuming
    /// cached continuations and re-draining. Only call on the cached activation path.
    func clearPendingCommands() {
        pendingCommands.removeAll()
    }

    // MARK: - Condition API
    //
    // Registration is split across two steps, both within the same drain() call:
    //   Step 1 — registerCondition(): stores the predicate. Not evaluated yet.
    //   Step 2 — linkConditionContinuation(): attaches the continuation after the task
    //             suspends inside withCheckedThrowingContinuation.
    // Post-drain: the worker calls evaluateAndResumeFirstSatisfiedCondition() in a loop;
    //             predicates are safe to evaluate because run() has released exclusive access.

    /// Register a condition predicate and return its ID.
    ///
    /// - Parameters:
    ///   - predicate: Closure that reads `stateBox` via `withValue`. **Not** called
    ///     here — evaluated post-drain by the worker's condition-check loop.
    ///   - wakeAt: Deadline for `condition(_:timeout:)`, `nil` for indefinite waits.
    func registerCondition(
        predicate: @escaping @Sendable () -> Bool,
        wakeAt: Date? = nil,
        timeout: Duration? = nil
    ) -> Int {
        let id = nextConditionID
        nextConditionID += 1
        conditionEntries[id] = ConditionEntry(predicate: predicate, wakeAt: wakeAt, timeout: timeout)
        return id
    }

    /// Store the `CheckedContinuation` for a registered condition (called synchronously
    /// from within `withCheckedThrowingContinuation` while the task is suspending).
    func linkConditionContinuation(_ cont: CheckedContinuation<Bool, Error>, forID id: Int) {
        conditionEntries[id]?.continuation = cont
    }

    /// Evaluate all stored condition predicates and resume the first one that returns
    /// `true`. Removes the satisfied entry. Returns `true` when a condition was
    /// resumed (the caller should `drain()` again and loop).
    ///
    /// Must be called AFTER `drain()` — at that point `run()` has suspended and
    /// no longer holds exclusive access on `stateBox.value`.
    func evaluateAndResumeFirstSatisfiedCondition() -> Bool {
        for (id, entry) in conditionEntries where entry.predicate() {
            conditionEntries.removeValue(forKey: id)
            entry.continuation?.resume(returning: true)
            return true
        }
        return false
    }

    /// `true` when at least one condition predicate is registered but not yet satisfied.
    var hasUnsatisfiedConditions: Bool { !conditionEntries.isEmpty }

    /// The earliest deadline across all pending condition-with-timeout entries.
    /// `nil` when all remaining conditions are indefinite (no timeout).
    var conditionMinWakeAt: Date? {
        conditionEntries.values.compactMap(\.wakeAt).min()
    }

    // MARK: - Teardown

    /// Resume all pending continuations with `StrandError.cancelled`.
    ///
    /// **Only call during true teardown** (workflow completion, real failure, worker
    /// shutdown). The normal suspension path does NOT call this — the handler Task
    /// stays alive between activations, parked on its continuations, and the Resume
    /// API delivers real results on re-activation.
    func cancelPending() {
        for (_, cont) in activityContinuations { cont.resume(throwing: StrandError.cancelled) }
        for (_, cont) in timerContinuations { cont.resume(throwing: StrandError.cancelled) }
        for (_, cont) in eventContinuations { cont.resume(throwing: StrandError.cancelled) }
        for (_, entry) in conditionEntries {
            entry.continuation?.resume(throwing: StrandError.cancelled)
        }
        for (_, entry) in localActivityEntries {
            entry.continuation?.resume(throwing: StrandError.cancelled)
        }
        activityContinuations.removeAll()
        timerContinuations.removeAll()
        eventContinuations.removeAll()
        conditionEntries.removeAll()
        localActivityEntries.removeAll()
        eventNameToSeqNum.removeAll()
    }

    // MARK: - Inspection

    /// `true` when at least one continuation is parked (handler suspended mid-activation).
    ///
    /// The worker checks this after `drain()` to decide between:
    ///   - `true`  → handler is suspended; write commands to DB and finish activation.
    ///   - `false` → handler completed synchronously; finalize the run.
    var hasPendingContinuations: Bool {
        !activityContinuations.isEmpty
            || !timerContinuations.isEmpty
            || !eventContinuations.isEmpty
            || !conditionEntries.isEmpty
            || !localActivityEntries.isEmpty
    }

}
