import Logging
package import NIOCore
import PostgresNIO

#if canImport(FoundationEssentials)
public import FoundationEssentials  // UUID in public taskID
#else
public import Foundation
#endif

// MARK: - WorkflowHandle

/// A handle to a running or completed workflow instance.
///
/// Returned by `StrandClient.startWorkflow(_:options:input:)`. Use it to:
/// - Poll for the final result (`result(timeout:)`).
/// - Send named signals that mutate workflow state (`signal(name:)` / `signal(name:payload:)`).
/// - Cancel the workflow (`cancel()`).
/// - Inspect the current state without blocking (`snapshot()`).
///
/// The handle is a lightweight value type — it stores only the workflow's stable task UUID
/// and a reference to the originating client. It may be freely passed across task boundaries.
public struct WorkflowHandle<W: Workflow>: Sendable {

    // MARK: - Public identity

    /// Human-readable stable identifier for this workflow instance.
    ///
    /// When `WorkflowOptions.id` is set explicitly that value is used.
    /// When omitted Strand generates `"<WorkflowName>-<epochMs>"` — e.g.
    /// `"MissionControlWorkflow-1746218580123"` — which is stored as the
    /// `idempotency_key` so `StrandClient.workflow(id:)` can locate the run.
    public let workflowID: String

    /// The stable UUID of the workflow's task row (`strand.tasks.id`).
    ///
    /// This is the **logical identity** of the workflow — it never changes across
    /// retries, signals, or sleep cycles. Use it to cancel, signal, or attach to
    /// the workflow programmatically.
    ///
    /// > Note: This is the *task* ID, not a *run* ID. Each retry creates a new
    /// > `strand.runs` row with a different UUID. Use `snapshot()` to get the
    /// > current run's ID if you need it.
    public let taskID: UUID

    /// The run UUID of the **first** attempt (`strand.runs.id`).
    ///
    /// Run IDs change on each retry — `initialRunID` is only the first attempt's ID.
    /// Use `snapshot()` to read the current (latest) run state.
    public let initialRunID: UUID

    // MARK: - Package-internal

    let client: StrandClient

    // MARK: - Init

    init(workflowID: String, taskID: UUID, initialRunID: UUID, client: StrandClient) {
        self.workflowID = workflowID
        self.taskID = taskID
        self.initialRunID = initialRunID
        self.client = client
    }

    // MARK: - Signals

    /// Sends a named signal with no payload to the workflow.
    ///
    /// Signals are delivered in arrival order at the start of the next activation.
    /// The workflow's `handleSignal(name:payload:)` method is called before `run(context:input:)`.
    ///
    /// - Parameter name: Registered signal name (must match the handler in the workflow).
    public func signal(name: String) async throws {
        // StrandClient must expose:
        // package func _sendSignal(name: String, payload: ByteBuffer?, toWorkflowTaskID: UUID) async throws
        try await client._sendSignal(name: name, payload: nil, toWorkflowTaskID: taskID)
    }

    /// Sends a named signal with a typed payload to the workflow.
    ///
    /// The payload is JSON-encoded into a BYTEA column and forwarded verbatim to
    /// `Workflow.handleSignal(name:payload:)` on the next activation.
    ///
    /// - Parameters:
    ///   - name: Registered signal name.
    ///   - payload: Any `Codable & Sendable` value. Decoded inside the workflow handler.
    public func signal<P: Codable & Sendable>(name: String, payload: P) async throws {
        let buf = try JSON.encode(payload)
        try await client._sendSignal(name: name, payload: buf, toWorkflowTaskID: taskID)
    }

    /// Type-safe signal dispatch using a ``WorkflowSignal``.
    ///
    /// ```swift
    /// // Instead of: try await handle.signal(name: "pause")
    /// try await handle.signal(OrderWorkflow.Pause.self)
    /// ```
    ///
    /// The signal name is derived from `S.signalName` (defaults to the type name
    /// lowercased). No payload is sent; use the payload overload for signals that
    /// carry data.
    public func signal<S: WorkflowSignal>(
        _ definition: S.Type
    ) async throws where S.W == W, S.Input == StrandVoid {
        try await client._sendSignal(name: S.signalName, payload: nil, toWorkflowTaskID: taskID)
    }

    /// Type-safe signal dispatch with a typed payload.
    ///
    /// ```swift
    /// // Instead of: try await handle.signal(name: "priority", payload: ShippingPriority.expedited)
    /// try await handle.signal(OrderWorkflow.SetPriority.self, payload: .expedited)
    /// ```
    public func signal<S: WorkflowSignal>(
        _ definition: S.Type,
        payload: S.Input
    ) async throws where S.W == W {
        let buf = try JSON.encode(payload)
        try await client._sendSignal(name: S.signalName, payload: buf, toWorkflowTaskID: taskID)
    }

    // MARK: - Cancel

    /// Cancels the workflow, transitioning it (and all pending/sleeping runs) to CANCELLED.
    ///
    /// This is a best-effort cancellation: if the workflow is currently executing a
    /// handler, the cancellation takes effect at the next checkpoint boundary.
    public func cancel() async throws {
        try await client.cancelTask(id: taskID)
    }

    // MARK: - Result

    /// Polls until the workflow reaches a terminal state, then decodes and returns its result.
    ///
    /// The poll interval starts at 100 ms and backs off exponentially to a cap of 2 s.
    /// This keeps DB load low for long-running workflows while being responsive for short ones.
    ///
    /// - Parameter timeout: Optional upper bound on total wait time. Throws
    ///   `StrandError.timeout` when exceeded. Pass `nil` to wait indefinitely.
    /// - Throws: `StrandError.timeout` on deadline exceeded.
    ///           `WorkflowError` when the workflow reached FAILED or CANCELLED state.
    ///           `StrandError.serialization` when the result payload cannot be decoded as `W.Output`.
    public func result(timeout: Duration? = nil) async throws -> W.Output {
        let start = ContinuousClock.now
        var delay: Duration = .milliseconds(100)

        while true {
            // Poll the DB for a terminal snapshot.
            if let snap = try await client.fetchTaskResult(id: taskID) {
                switch snap.state {
                case .completed:
                    return try snap.decodeResult(as: W.Output.self)
                case .failed, .cancelled:
                    throw WorkflowError(workflowName: W.workflowName, state: snap.state)
                case .continuedAsNew:
                    // The workflow restarted itself. The caller's handle points to
                    // the old instance which is now done. Treat as a completion
                    // without a result value.
                    throw WorkflowError(workflowName: W.workflowName, state: snap.state)
                case .pending, .running, .sleeping, .waiting:
                    break  // Still in progress — keep polling.
                }
            }

            // Check timeout before sleeping to surface it promptly.
            if let t = timeout, ContinuousClock.now - start >= t {
                throw StrandError.timeout(
                    message:
                        "Workflow \(W.workflowName) (\(workflowID)) did not complete within timeout"
                )
            }

            try await Task.sleep(for: delay)
            // Exponential backoff, capped at 2 s.
            if delay < .seconds(2) {
                delay = min(delay * 2, .seconds(2))
            }
        }
    }

    // MARK: - Snapshot

    /// Returns the current state snapshot without blocking.
    ///
    /// Returns `nil` if no task with `taskID` is found (should not happen for a
    /// handle returned by the client, but guards against stale handles).
    public func snapshot() async throws -> TaskResultSnapshot? {
        try await client.fetchTaskResult(id: taskID)
    }

    // MARK: - Query

    /// Typed query using a ``WorkflowQuery``-conforming type generated by `@WorkflowQuery`.
    ///
    /// Reads the last persisted state from `strand.workflow_state` and calls the
    /// query's `run(workflow:)` method without creating a new workflow activation.
    ///
    /// ```swift
    /// let status = try await handle.query(SignalWorkflow.GetStatus.self)
    /// print(status.isPaused)   // reads directly from persisted state
    /// ```
    public func query<Q: WorkflowQuery>(_ queryType: Q.Type) async throws -> Q.Output where Q.W == W {
        try await query { workflow in
            try Q.run(workflow: workflow)
        }
    }

    /// Reads the current workflow state and calls `fn` on it synchronously.
    ///
    /// Does not block the workflow — reads the last persisted state from
    /// `strand.workflow_state` and applies `fn` without creating an activation.
    ///
    /// ```swift
    /// let isPaused = try await orderHandle.query { $0.isPaused }
    /// let count    = try await orderHandle.query { $0.processedItems.count }
    /// ```
    ///
    /// - Parameter fn: A function that reads (does not mutate) the workflow struct.
    /// - Returns: The value returned by `fn`.
    public func query<R: Sendable>(
        _ fn: @Sendable (W) throws -> R
    ) async throws -> R {
        let buf = try await WorkflowStateQueries.loadState(
            on: client.postgres,
            taskID: taskID,
            namespaceID: client.namespaceID,
            logger: client.logger
        )
        // nil means the workflow has started but hasn't saved state yet
        // (first activation, no signals delivered). Use W() — the Workflow
        // protocol requires init() and all properties must have default values.
        // JSON.decode(W.self, from: "{}") would throw keyNotFound for every
        // non-optional property even when defaults are declared.
        let state = if let buf { try JSON.decode(W.self, from: buf) } else { W() }
        return try fn(state)
    }

    // MARK: - Updates

    /// Sends a typed update to the workflow and awaits its result.
    ///
    /// The update is delivered as a specially-prefixed signal. The runtime routes it
    /// to the workflow's `handleUpdate(name:correlationID:payload:)` method, which
    /// validates, mutates state, and returns a typed result — all in a single
    /// workflow activation. The result is published as a named event in `strand.events`
    /// and received here without polling the task state.
    ///
    /// - Parameters:
    ///   - updateType: The `WorkflowUpdateDefinition`-conforming type generated by
    ///     `@WorkflowUpdate`.
    ///   - payload: The update input.
    ///   - timeout: Maximum time to wait for the result. Defaults to 30 s.
    /// - Returns: The typed result returned by the workflow's update handler.
    /// - Throws: `WorkflowUpdateError` when the handler threw a validation error.
    ///           `StrandError.timeout` when the result was not received within `timeout`.
    public func update<U: WorkflowUpdateDefinition>(
        _ updateType: U.Type,
        payload: U.Input,
        timeout: Duration = .seconds(30)
    ) async throws -> U.Output where U.W == W {
        let correlationID = UUID().uuidString
        let signalPayload = try JSON.encode(payload)

        // Send as a regular signal row but with update_correlation_id populated.
        // The worker reads that column to route to handleUpdate instead of handleSignal.
        try await client._sendUpdateSignal(
            updateName: U.updateName,
            correlationID: correlationID,
            payload: signalPayload,
            toWorkflowTaskID: taskID
        )

        // Poll strand.workflow_updates for the result row keyed by correlationID.
        let start = ContinuousClock.now
        var delay: Duration = .milliseconds(50)

        while true {
            if ContinuousClock.now - start >= timeout {
                throw StrandError.timeout(
                    message: "Update '\(U.updateName)' on \(W.workflowName) (\(workflowID)) did not complete within timeout"
                )
            }

            if let row = try await WorkflowStateQueries.findUpdateResult(
                on: client.postgres,
                namespaceID: client.namespaceID,
                correlationID: correlationID,
                logger: client.logger
            ) {
                if let errorMsg = row.error {
                    throw WorkflowUpdateError(errorMsg)
                }
                guard let resultBuf = row.result else {
                    throw WorkflowUpdateError("Update '\(U.updateName)' produced no result")
                }
                return try JSON.decode(U.Output.self, from: resultBuf)
            }

            try await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(1))
        }
    }
}

// MARK: - StrandClient public signal API

extension StrandClient {

    /// Sends a type-safe signal with a typed payload to any workflow task identified by `taskID`.
    ///
    /// Use this when you have a ``WorkflowSignal`` type but only a raw task UUID
    /// (not a typed ``WorkflowHandle``). The signal name is derived from `S.signalName`
    /// and the payload is JSON-encoded automatically.
    ///
    /// ```swift
    /// try await client.signal(
    ///     RoomMonitorWorkflow.UpdateThresholds.self,
    ///     taskID: roomTaskID,
    ///     payload: ThresholdUpdate(newThresholds: raised, reason: "post-incident")
    /// )
    /// ```
    ///
    /// > Note: Unlike `handle.signal(_:payload:)`, this overload does not enforce `S.W`
    /// > at compile time — you are responsible for ensuring `taskID` belongs to
    /// > a workflow that handles the signal.
    public func signal<S: WorkflowSignal>(
        _ definition: S.Type,
        taskID: UUID,
        payload: S.Input
    ) async throws {
        let buf = try JSON.encode(payload)
        try await _sendSignal(name: S.signalName, payload: buf, toWorkflowTaskID: taskID)
    }
}

// MARK: - StrandClient internal signal transport

extension StrandClient {

    /// Inserts a signal row into `strand.workflow_signals` for the target workflow task.
    ///
    /// Signals are delivered in arrival order at the start of the next activation of
    /// `taskID`. The `payload` is stored as BYTEA and forwarded verbatim to
    /// `Workflow.handleSignal(name:payload:)`.
    ///
    /// - Parameters:
    ///   - name: Signal name. Matched by the workflow's `handleSignal` implementation.
    ///   - payload: Optional JSON-encoded payload. `nil` for no-payload signals.
    ///   - taskID: The `strand.tasks.id` of the target workflow.
    /// Sends an `@WorkflowUpdate` request — identical to `_sendSignal` but
    /// populates `update_correlation_id` so the worker routes it to `handleUpdate`.
    package func _sendUpdateSignal(
        updateName: String,
        correlationID: String,
        payload: ByteBuffer?,
        toWorkflowTaskID taskID: UUID,
        namespaceID overrideNS: String? = nil
    ) async throws {
        let ns = overrideNS ?? namespaceID
        try await postgres.withTransaction(logger: logger) { conn in
            try await conn.query(
                """
                INSERT INTO strand.workflow_signals
                    (namespace_id, task_id, signal_name, payload, update_correlation_id)
                VALUES (\(ns), \(taskID), \(updateName), \(payload), \(correlationID))
                """,
                logger: logger
            )
            let wakeStream = try await conn.query(
                """
                UPDATE strand.runs
                SET state = \(TaskState.pending), available_at = NOW(),
                    wake_event = NULL, event_payload = NULL,
                    worker_id = NULL, lease_expires_at = NULL
                WHERE task_id = \(taskID) AND state IN (\(TaskState.sleeping), \(TaskState.waiting))
                RETURNING queue
                """,
                logger: logger
            )
            var wokeQueue: String? = nil
            for try await row in wakeStream {
                var col = row.makeIterator()
                wokeQueue = try col.next()!.decode(String.self, context: .default)
            }
            try await conn.query(
                """
                UPDATE strand.tasks SET state = \(TaskState.pending)
                WHERE id = \(taskID) AND state IN (\(TaskState.sleeping), \(TaskState.waiting))
                """,
                logger: logger
            )
            if let queue = wokeQueue {
                try await conn.notifyWorkers(namespace: ns, queue: queue, logger: logger)
            }
        }
    }

    package func _sendSignal(
        name: String,
        payload: ByteBuffer?,
        toWorkflowTaskID taskID: UUID,
        namespaceID overrideNS: String? = nil
    ) async throws {
        // Signal insertion and run wake must be a single transaction.
        //
        // If the process crashes between two separate writes the signal row
        // would exist in the DB but the run would stay WAITING/SLEEPING
        // indefinitely — there is no background sweeper for that state.
        // Wrapping both in a transaction means either the run wakes and the
        // signal is deliverable, or neither write survives.
        //
        // The UPDATE on strand.runs is a no-op when the run is already PENDING
        // or RUNNING, so it is safe to call unconditionally after every signal.
        let ns = overrideNS ?? namespaceID
        try await postgres.withTransaction(logger: logger) { conn in
            try await conn.query(
                """
                INSERT INTO strand.workflow_signals
                    (namespace_id, task_id, signal_name, payload)
                VALUES (\(ns), \(taskID), \(name), \(payload))
                """,
                logger: logger
            )
            // RETURNING queue so we can notify the correct worker channel
            // without an extra round-trip — and only when a row was actually
            // updated (no spurious notifies for RUNNING/PENDING runs).
            let wakeStream = try await conn.query(
                """
                UPDATE strand.runs
                SET state = \(TaskState.pending), available_at = NOW(),
                    wake_event = NULL, event_payload = NULL,
                    worker_id = NULL, lease_expires_at = NULL
                WHERE task_id = \(taskID) AND state IN (\(TaskState.sleeping), \(TaskState.waiting))
                RETURNING queue
                """,
                logger: logger
            )
            var wokeQueue: String? = nil
            for try await row in wakeStream {
                var col = row.makeIterator()
                wokeQueue = try col.next()!.decode(String.self, context: .default)
            }
            try await conn.query(
                """
                UPDATE strand.tasks SET state = \(TaskState.pending)
                WHERE id = \(taskID) AND state IN (\(TaskState.sleeping), \(TaskState.waiting))
                """,
                logger: logger
            )
            // Wake the worker if a run was actually transitioned to PENDING.
            // Without this notify the worker only discovers the PENDING run on
            // the next pollInterval tick — which is correct but needlessly slow.
            if let queue = wokeQueue {
                try await conn.notifyWorkers(namespace: ns, queue: queue, logger: logger)
            }
        }
    }
}
