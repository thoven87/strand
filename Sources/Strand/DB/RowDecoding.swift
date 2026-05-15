public import NIOCore
public import PostgresNIO

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - ClaimedTask

/// A run row returned by the claim CTE in ``Queries/claimTasks``.
struct ClaimedTask: Sendable {
    let runID: UUID
    let taskID: UUID
    let attempt: Int
    /// Optimistic concurrency version. Passed to completeRun/failRun for CAS.
    let version: Int
    let taskName: String
    let paramsBuffer: ByteBuffer
    let retryStrategyBuffer: ByteBuffer?
    let maxAttempts: Int?
    let headersBuffer: ByteBuffer?
    /// Set when the run was re-claimed after an event wait.
    let wakeEvent: String?
    /// Non-nil when the run was woken by a matching event emission.
    let eventPayloadBuffer: ByteBuffer?

    // MARK: - Typed fields decoded from headers (once, at claim time)

    /// The decoded key-value headers forwarded with this task.
    /// Decoded once here; all consumers read from this dictionary, not from `headersBuffer`.
    let headers: [String: String]

    /// UUID of the parent workflow that spawned this task (from `strand.tasks.parent_task_id`).
    /// `nil` for root tasks enqueued directly by `StrandClient`.
    /// Decoded directly from the DB column — no string header round-trip.
    let parentWorkflowID: UUID?

    /// Task kind: `.workflow` or `.activity`.
    /// Stored as `strand.task.kind` on OTel spans.
    let kind: TaskKind

    /// Per-attempt execution cap in seconds. `nil` falls back to the worker's `claimTimeout`.
    /// Stored in `strand.tasks.timeout_seconds`; decoded from the claim CTE result.
    let timeoutSeconds: Int?

    /// Heartbeat timeout in seconds. When set, `context.heartbeat()` extends the
    /// lease by this duration instead of the worker's `claimTimeout`. Allows fast
    /// re-scheduling when an activity stalls without requiring a short `claimTimeout`.
    let heartbeatTimeoutSeconds: Int?

    /// Scheduling metadata injected by `StrandScheduler`. `nil` for directly-enqueued tasks.
    let schedulingMetadata: SchedulingMetadata?

    /// The wall-clock time at which this run last became PENDING/SLEEPING (i.e. available
    /// for claiming).  Used to compute `wait_time` — how long the task spent in the queue
    /// before a worker picked it up.
    let availableAt: Date

    /// Heartbeat details written by the previous attempt via `context.heartbeat(_:)`.
    /// `nil` on the first attempt or if the previous attempt never called `heartbeat(_:)`.
    /// Exposed to the activity handler via `ActivityContext.heartbeatDetails(as:)`.
    let heartbeatDetails: ByteBuffer?

    /// The absolute deadline for this task (`strand.tasks.deadline_at`). `nil` means no total budget.
    /// Used by activities to compute remaining budget: `deadlineAt.map { $0.timeIntervalSince(.now) }`.
    let deadlineAt: Date?

    /// First task in the `continueAsNew` chain this task belongs to.
    /// `nil` for the first task in a chain, for child tasks, and for activities.
    let firstTaskID: UUID?

    /// `true` when this attempt is the last one allowed.
    ///
    /// Used to decide whether a thrown error should mark the OTel span `ERROR`.
    /// Retryable attempts keep `UNSET` status so Jaeger doesn't count them as
    /// failures; only the terminal attempt is marked `ERROR`.
    var isTerminalAttempt: Bool {
        guard let max = maxAttempts else { return true }  // no cap → always terminal
        return attempt >= max
    }
}

extension ClaimedTask {
    /// Decode from the column order returned by the claim CTE:
    /// run_id, task_id, attempt, version, task_name, params,
    /// retry_strategy, max_attempts, headers, wake_event, event_payload,
    /// parent_task_id, kind, timeout_seconds, heartbeat_timeout_seconds,
    /// scheduling_metadata, available_at, heartbeat_details, deadline_at,
    /// first_task_id
    init(row: PostgresRow) throws {
        var col = row.makeIterator()
        runID = try col.next()!.decode(UUID.self, context: .default)
        taskID = try col.next()!.decode(UUID.self, context: .default)
        attempt = try col.next()!.decode(Int.self, context: .default)
        version = try col.next()!.decode(Int.self, context: .default)
        taskName = try col.next()!.decode(String.self, context: .default)
        paramsBuffer = try col.next()!.decode(ByteBuffer.self, context: .default)
        retryStrategyBuffer = try col.next()!.decode(ByteBuffer?.self, context: .default)
        maxAttempts = try col.next()!.decode(Int?.self, context: .default)
        headersBuffer = try col.next()!.decode(ByteBuffer?.self, context: .default)
        wakeEvent = try col.next()!.decode(String?.self, context: .default)
        eventPayloadBuffer = try col.next()!.decode(ByteBuffer?.self, context: .default)

        // Decode typed fields from headers once here.
        // All downstream consumers (WorkflowRegistration, Activity._run, etc.)
        // read from these typed fields instead of re-parsing the raw buffer.
        let h: [String: String] =
            headersBuffer.flatMap { try? JSON.decode([String: String].self, from: $0) } ?? [:]
        headers = h
        // parent_task_id is a typed UUID column — decoded directly, no string conversion.
        parentWorkflowID = try col.next()!.decode(UUID?.self, context: .default)
        kind = try col.next()!.decode(TaskKind.self, context: .default)
        timeoutSeconds = try col.next()!.decode(Int?.self, context: .default)
        heartbeatTimeoutSeconds = try col.next()!.decode(Int?.self, context: .default)
        schedulingMetadata = try col.next()!.decode(SchedulingMetadata?.self, context: .default)
        availableAt = try col.next()!.decode(Date.self, context: .default)
        heartbeatDetails = try col.next()!.decode(ByteBuffer?.self, context: .default)
        deadlineAt = try col.next()!.decode(Date?.self, context: .default)
        firstTaskID = try col.next()!.decode(UUID?.self, context: .default)
    }
}

// MARK: - CheckpointRow

/// A single checkpoint row from ``Queries/getCheckpointStates``.
public struct CheckpointRow: Sendable {
    /// Integer primary key — the deterministic sequence number emitted by the executor.
    public let seqNum: Int
    /// Optional human-readable label stored for debugging. May be `nil` when not provided.
    public let name: String?
    public let stateBuffer: ByteBuffer
}

extension CheckpointRow {
    /// Columns: seq_num, name, state
    public init(row: PostgresRow) throws {
        var col = row.makeIterator()
        seqNum = try col.next()!.decode(Int.self, context: .default)
        name = try col.next()!.decode(String?.self, context: .default)
        stateBuffer = try col.next()!.decode(ByteBuffer.self, context: .default)
    }
}

// MARK: - EnqueueRow

/// Returned after enqueuing a task (task INSERT + run INSERT).
struct EnqueueRow: Sendable {
    let taskID: UUID
    let runID: UUID
    let attempt: Int
    let created: Bool  // false when an idempotency-key match was returned
}

// MARK: - TaskResultRow

/// Returned by ``Queries/fetchTaskResult``.
struct TaskResultRow: Sendable {
    let taskID: UUID
    let state: String
    let resultBuffer: ByteBuffer?
    let failureBuffer: ByteBuffer?
}

extension TaskResultRow {
    /// Columns: id, state, result, failure_reason
    init(row: PostgresRow) throws {
        var col = row.makeIterator()
        taskID = try col.next()!.decode(UUID.self, context: .default)
        state = try col.next()!.decode(String.self, context: .default)
        resultBuffer = try col.next()!.decode(ByteBuffer?.self, context: .default)
        failureBuffer = try col.next()!.decode(ByteBuffer?.self, context: .default)
    }
}

// MARK: - AwaitEventResult

/// Three-way outcome of ``Queries/awaitEvent``.
enum AwaitEventResult: Sendable {
    /// Event was already present in `strand.events` — here is its payload.
    case payload(ByteBuffer)
    /// The run was woken after a timeout (wake_event matches, event_payload nil).
    case timedOut
    /// Wait registered; run transitioned to WAITING/SLEEPING.
    case suspended
}

// MARK: - Error mapping

/// Maps a `PSQLError` into a Swift error, passing non-Postgres errors through.
func mapPSQLError(_ error: any Error) throws {
    throw StrandError.database(underlying: error)
}
