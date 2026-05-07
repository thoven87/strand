import DequeModule
public import Logging
import NIOCore
// Re-export PostgresNIO so callers can use PostgresClient without an explicit import.
public import PostgresNIO

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// MARK: - StrandClient

/// Strand client. A lightweight value type — safe to copy and pass across tasks.
/// All methods are `async` because they perform database work, not because of
/// actor isolation (there is none — this is a struct, not an actor).
public struct StrandClient: Sendable {

    public let postgres: PostgresClient
    /// The queue this client dispatches tasks to by default.
    public let queueName: String
    /// The namespace this client operates in.
    public let namespaceID: String
    public let logger: Logger
    let options: StrandOptions

    public init(
        postgres: PostgresClient,
        queue: String = "default",
        namespace: String = "default",
        logger: Logger = Logger(label: "dev.strand"),
        options: StrandOptions = .init()
    ) {
        precondition(!queue.isEmpty, "Queue name must not be empty")
        precondition(
            queue.utf8.count <= 57,
            "Queue name \"\(queue)\" exceeds 57 UTF-8 bytes"
        )
        self.postgres = postgres
        self.queueName = queue
        self.namespaceID = namespace
        self.options = options
        self.logger = logger
    }

    // MARK: - Enqueue (by task name)

    /// Enqueues a task by its registered name with fully typed params.
    ///
    /// Use this when you want fire-and-forget dispatch without a typed handle:
    /// ```swift
    /// let enq = try await client.enqueue(taskName: "process-order", params: order)
    /// ```
    @discardableResult
    public func enqueue<P: Codable & Sendable>(
        taskName: String,
        params: P,
        options enqueueOpts: EnqueueOptions = .init()
    ) async throws -> EnqueueResult {
        try await _enqueue(
            queue: enqueueOpts.queue ?? queueName,
            taskName: taskName,
            params: params,
            maxAttempts: enqueueOpts.maxAttempts ?? options.defaultMaxAttempts,
            retryStrategy: enqueueOpts.retryStrategy ?? options.defaultRetryStrategy,
            cancellation: enqueueOpts.cancellation,
            headers: enqueueOpts.headers,
            idempotencyKey: enqueueOpts.idempotencyKey,
            priority: enqueueOpts.priority,
            delayUntil: enqueueOpts.delayUntil,
            maxDuration: enqueueOpts.maxDuration,
            fairnessKey: enqueueOpts.fairnessKey,
            fairnessWeight: enqueueOpts.fairnessWeight
        )
    }

    // MARK: - Activity enqueue / run

    /// Enqueues an ``Activity`` as a standalone unit of work — no workflow required.
    ///
    /// The activity runs independently with `kind = 'ACTIVITY'` so the dashboard can
    /// distinguish leaf executions from orchestrators.
    ///
    /// ```swift
    /// // Fire-and-forget:
    /// let enq = try await client.enqueue(chargeCard, params: ChargeInput(amount: 99.99))
    /// // Wait for the result later:
    /// let result: ChargeResult = try await client.awaitTaskResult(id: enq.taskID)
    /// ```
    @discardableResult
    public func enqueue<P: Codable & Sendable, R: Codable & Sendable>(
        _ activity: Activity<P, R>,
        params: P,
        options: ActivityOptions = .init()
    ) async throws -> EnqueueResult {
        try await _enqueue(
            queue: options.queue ?? activity.queue ?? queueName,
            taskName: activity.name,
            params: params,
            maxAttempts: options.maxAttempts ?? activity.defaultMaxAttempts
                ?? self.options.defaultMaxAttempts,
            retryStrategy: options.retryStrategy ?? self.options.defaultRetryStrategy,
            cancellation: options.cancellation,
            headers: options.headers,
            idempotencyKey: options.idempotencyKey,
            priority: options.priority,
            delayUntil: options.delayUntil,
            maxDuration: options.maxDuration,
            fairnessKey: options.fairnessKey,
            fairnessWeight: options.fairnessWeight,
            kind: .activity,
            parentTaskID: nil
        )
    }

    /// Enqueues an ``Activity`` and polls until it completes, returning the decoded result.
    ///
    /// Equivalent to a standalone activity call from outside a workflow handler.
    public func runActivity<P: Codable & Sendable, R: Decodable & Sendable>(
        _ activity: Activity<P, R>,
        params: P,
        options: ActivityOptions = .init()
    ) async throws -> R {
        let enq = try await enqueue(activity, params: params, options: options)
        return try await awaitTaskResult(id: enq.taskID)
    }

    // MARK: - Standalone ActivityDefinition dispatch

    /// Enqueues an ``ActivityDefinition`` as a standalone unit of work without a
    /// parent workflow. The activity is claimed and executed by any worker that has
    /// it registered in its `activities:` array.
    ///
    /// ```swift
    /// // Fire and forget — the worker executes it independently:
    /// let enq = try await client.enqueueActivity(
    ///     ChargeCardActivity.self,
    ///     input: ChargeInput(amount: 99.99)
    /// )
    ///
    /// // Retrieve the result later:
    /// let handle = WorkflowHandle<Never>(workflowID: enq.taskID.uuidString,
    ///                                   taskID: enq.taskID, client: client)
    /// ```
    @discardableResult
    public func enqueueActivity<A: ActivityDefinition>(
        _ type: A.Type,
        input: A.Input,
        options: ActivityOptions = .init()
    ) async throws -> EnqueueResult {
        try await _enqueue(
            queue: options.queue ?? queueName,
            taskName: A.name,
            params: input,
            maxAttempts: options.maxAttempts ?? A.defaultMaxAttempts
                ?? self.options.defaultMaxAttempts,
            retryStrategy: options.retryStrategy ?? self.options.defaultRetryStrategy,
            cancellation: options.cancellation,
            headers: options.headers,
            idempotencyKey: options.idempotencyKey,
            priority: options.priority,
            delayUntil: options.delayUntil,
            maxDuration: options.maxDuration,
            fairnessKey: options.fairnessKey,
            fairnessWeight: options.fairnessWeight,
            kind: .activity,
            parentTaskID: nil
        )
    }

    /// Enqueues an ``ActivityDefinition`` and polls until it completes, returning
    /// the decoded result. The worker must have this activity registered.
    ///
    /// ```swift
    /// // Dispatch directly from the client, await the result:
    /// let result = try await client.runActivity(
    ///     ChargeCardActivity.self,
    ///     input: ChargeInput(amount: 99.99),
    ///     options: .init(maxAttempts: 3, priority: .high)
    /// )
    /// ```
    public func runActivity<A: ActivityDefinition>(
        _ type: A.Type,
        input: A.Input,
        options: ActivityOptions = .init()
    ) async throws -> A.Output {
        let enq = try await enqueueActivity(type, input: input, options: options)
        let snap = try await pollTerminalSnapshot(
            id: enq.taskID,
            options: AwaitTaskResultOptions(timeout: options.timeout)
        )
        guard snap.state == .completed else {
            throw StrandError.activityFailed(name: A.name, state: snap.state.rawValue)
        }
        return try snap.decodeResult(as: A.Output.self)
    }

    // MARK: - startWorkflow

    /// Enqueues a ``Workflow`` and returns a ``WorkflowHandle`` for signalling,
    /// cancellation, and result polling.
    ///
    /// ```swift
    /// let handle = try await client.startWorkflow(OrderWorkflow.self, input: order)
    ///
    /// // Optionally send a signal:
    /// try await handle.signal(name: "pause")
    ///
    /// // Wait for the final result:
    /// let result: ShipResult = try await handle.result()
    /// ```
    @discardableResult
    public func startWorkflow<W: Workflow>(
        _ type: W.Type,
        options: WorkflowOptions = .init(),
        input: W.Input
    ) async throws -> WorkflowHandle<W> {
        let queue = options.queue ?? queueName
        let taskName = W.workflowName
        let paramsBuffer = try JSON.encode(input)
        let headersBuffer: ByteBuffer? =
            options.headers.isEmpty ? nil : try JSON.encode(options.headers)
        let retryBuf: ByteBuffer? = try options.retryStrategy.map { try JSON.encode($0) }

        // When the caller doesn't set an explicit ID we generate one from the
        // workflow type name + current milliseconds: "MissionControlWorkflow-1746218580123".
        // This is stored as the idempotency_key so `client.workflow(id:)` can find
        // the run by this human-readable string, not just by the raw UUID.
        // We sanitise the type name so generic types (e.g. `Order<PayPal>`) produce
        // a valid, filesystem-safe identifier.
        // Use the caller-supplied ID when provided; otherwise delegate to the workflow
        // type's own ID generator (overridable per type via WorkflowRegistrable).
        let resolvedID = options.id ?? W.generateWorkflowID()

        let row = try await Queries.enqueueTask(
            on: postgres,
            namespaceID: namespaceID,
            queue: queue,
            taskName: taskName,
            paramsBuffer: paramsBuffer,
            headersBuffer: headersBuffer,
            retryStrategyBuffer: retryBuf,
            maxAttempts: options.maxAttempts ?? self.options.defaultMaxAttempts,
            cancellationBuffer: nil,
            idempotencyKey: resolvedID,  // always set — enables client.workflow(id:) lookup
            priority: options.priority.rawValue,
            scheduledAt: options.delayUntil,
            fairnessKey: nil,
            fairnessWeight: 1.0,
            kind: .workflow,
            parentTaskID: nil,
            logger: logger
        )

        return WorkflowHandle<W>(
            workflowID: resolvedID,
            taskID: row.taskID,
            initialRunID: row.runID,
            client: self
        )
    }

    // MARK: - Handle reconstruction

    /// Reconstructs a ``WorkflowHandle`` for a workflow that was started elsewhere,
    /// using the ``WorkflowHandle/taskID`` you stored (e.g. in your database or in a
    /// signed confirmation link).
    ///
    /// No DB round-trip is made — this is a pure in-memory construction.
    ///
    /// ```swift
    /// // Embed taskID in a confirmation link:
    /// let link = "https://app.com/confirm?wfId=\(handle.taskID)"
    ///
    /// // When user clicks:
    /// let taskID = UUID(uuidString: req.query["wfId"])!
    /// let handle = client.attach(taskID: taskID, as: ApprovalWorkflow.self)
    /// try await handle.signal(name: "approve")
    /// ```
    public func attach<W: Workflow>(taskID: UUID, as type: W.Type = W.self) -> WorkflowHandle<W> {
        WorkflowHandle(
            workflowID: taskID.uuidString,
            taskID: taskID,
            initialRunID: taskID,  // attach() doesn't know the run ID; taskID is a safe fallback
            // since signal/snapshot never dereference it
            client: self
        )
    }

    /// Looks up a workflow by the custom string ID set via ``WorkflowOptions/id`` and
    /// returns a typed handle.
    ///
    /// Use this when you embedded a human-readable ID in a link rather than the raw
    /// task UUID — e.g. `WorkflowOptions(id: "order-ORDER-123")`.
    ///
    /// ```swift
    /// // When starting:
    /// try await client.startWorkflow(
    ///     ApprovalWorkflow.self,
    ///     options: WorkflowOptions(id: "order-ORDER-123"),
    ///     input: input)
    ///
    /// // Link: https://app.com/confirm?order=ORDER-123
    ///
    /// // When user clicks:
    /// if let handle = try await client.workflow(id: "order-ORDER-123", as: ApprovalWorkflow.self) {
    ///     try await handle.signal(name: "approve")
    /// }
    /// ```
    ///
    /// - Returns: `nil` when no matching workflow exists in this namespace and queue.
    public func workflow<W: Workflow>(
        id workflowID: String,
        queue: String? = nil,
        as type: W.Type = W.self
    ) async throws -> WorkflowHandle<W>? {
        let targetQueue = queue ?? queueName
        let stream = try await postgres.query(
            """
            SELECT t.id, r.id AS run_id
            FROM strand.tasks t
            JOIN strand.runs r ON r.task_id = t.id
            WHERE t.namespace_id     = \(namespaceID)
              AND t.queue            = \(targetQueue)
              AND t.idempotency_key  = \(workflowID)
            ORDER BY r.attempt DESC
            LIMIT 1
            """,
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else { return nil }
        var col = row.makeIterator()
        let taskID = try col.next()!.decode(UUID.self, context: .default)
        let runID = try col.next()!.decode(UUID.self, context: .default)
        return WorkflowHandle(
            workflowID: workflowID,
            taskID: taskID,
            initialRunID: runID,
            client: self
        )
    }

    // MARK: - awaitWorkflowResult (package)

    /// Polls until `taskID` reaches a terminal state and decodes the result as `T`.
    ///
    /// Package-internal — called by ``WorkflowHandle`` when callers need a typed result
    /// without going through the full snapshot API.
    package func awaitWorkflowResult<T: Decodable & Sendable>(
        taskID: UUID,
        as type: T.Type,
        options: AwaitTaskResultOptions = .init()
    ) async throws -> T {
        let snap = try await pollTerminalSnapshot(id: taskID, options: options)
        guard snap.state == .completed else {
            throw StrandError.activityFailed(
                name: taskID.uuidString,
                state: snap.state.rawValue
            )
        }
        return try snap.decodeResult(as: type)
    }

    // MARK: - Internal enqueue helper

    private func _enqueue<P: Codable & Sendable>(
        queue: String,
        taskName: String,
        params: P,
        maxAttempts: Int?,
        retryStrategy: RetryStrategy,
        cancellation: CancellationPolicy?,
        headers: [String: String],
        idempotencyKey: String?,
        priority: TaskPriority = .normal,
        delayUntil: Date? = nil,
        maxDuration: Duration? = nil,
        fairnessKey: String? = nil,
        fairnessWeight: Float = 1.0,
        kind: TaskKind = .workflow,
        parentTaskID: UUID? = nil
    ) async throws -> EnqueueResult {
        let deadlineAt: Date? = maxDuration.map {
            Date.now.addingTimeInterval(
                Double($0.components.seconds)
                    + Double($0.components.attoseconds) / 1_000_000_000_000_000_000
            )
        }
        let row = try await Queries.enqueueTask(
            on: postgres,
            namespaceID: namespaceID,
            queue: queue,
            taskName: taskName,
            paramsBuffer: try JSON.encode(params),
            headersBuffer: headers.isEmpty ? nil : try JSON.encode(headers),
            retryStrategyBuffer: try JSON.encode(retryStrategy),
            maxAttempts: maxAttempts,
            cancellationBuffer: try cancellation.map { try JSON.encode($0) },
            idempotencyKey: idempotencyKey,
            priority: priority.rawValue,
            scheduledAt: delayUntil,
            deadlineAt: deadlineAt,
            fairnessKey: fairnessKey,
            fairnessWeight: fairnessWeight,
            kind: kind,
            parentTaskID: parentTaskID,
            logger: logger
        )
        return EnqueueResult(
            taskID: row.taskID,
            runID: row.runID,
            attempt: row.attempt,
            createdAt: Date.now
        )
    }

    // MARK: - Events

    /// Emits a named event by string — for dynamic names (e.g. `"order.shipped:\(id)"`).
    public func emitEvent(
        _ name: String,
        payload: some Codable & Sendable,
        queue: String? = nil
    ) async throws {
        try await Queries.emitEvent(
            on: postgres,
            namespaceID: namespaceID,
            queue: queue ?? queueName,
            eventName: name,
            payloadBuffer: try JSON.encode(payload),
            logger: logger
        )
    }

    /// Typed overload — derives the event name from the ``WorkflowEvent`` type.
    ///
    /// The compiler enforces that the payload type matches what the workflow
    /// declared in its ``WorkflowEvent`` conformance.
    ///
    /// ```swift
    /// try await client.emit(OrderShippedEvent.self,
    ///     payload: TrackingInfo(number: "1Z999"),
    ///     queue: "orders")
    /// ```
    public func emit<E: WorkflowEvent>(
        _ eventType: E.Type,
        payload: E.Payload,
        queue: String? = nil
    ) async throws {
        try await emitEvent(E.name, payload: payload, queue: queue)
    }

    // MARK: - Task control

    public func cancelTask(id taskID: UUID) async throws {
        try await Queries.cancelTask(
            on: postgres,
            namespaceID: namespaceID,
            taskID: taskID,
            logger: logger
        )
    }

    /// Requeues a task for execution regardless of its current terminal state.
    ///
    /// - FAILED or CANCELLED: same task ID, attempt incremented.
    ///   The task is still "in progress" semantically — the audit trail stays coherent.
    /// - COMPLETED or CONTINUED_AS_NEW: brand-new task ID with identical params.
    ///   The original completed cleanly; this starts genuinely new work.
    @discardableResult
    public func requeueTask(
        id taskID: UUID,
        options: RetryOptions = .init()
    ) async throws
        -> EnqueueResult
    {
        // Peek at state to choose the right path.
        guard
            let snap = try await ManagementQueries.getTask(
                on: postgres,
                namespaceID: namespaceID,
                taskID: taskID,
                logger: logger
            )
        else {
            throw StrandError.unknownTask(name: taskID.uuidString)
        }
        switch snap.state {
        case .completed, .continuedAsNew:
            // Fresh task — original succeeded, this is new work.
            // The reRunTask path is unaffected by RetryOptions.
            let row = try await Queries.reRunTask(
                on: postgres,
                namespaceID: namespaceID,
                taskID: taskID,
                logger: logger
            )
            return EnqueueResult(
                taskID: row.taskID,
                runID: row.runID,
                attempt: row.attempt,
                createdAt: Date.now
            )
        default:
            // FAILED, CANCELLED, or any other terminal state — same task, next attempt.
            let (runID, attempt) = try await Queries.retryTask(
                on: postgres,
                namespaceID: namespaceID,
                taskID: taskID,
                resetHistory: options.resetHistory,
                logger: logger
            )
            return EnqueueResult(
                taskID: taskID,
                runID: runID,
                attempt: attempt,
                createdAt: Date.now
            )
        }
    }

    public func fetchTaskResult(id taskID: UUID) async throws -> TaskResultSnapshot? {
        guard
            let row = try await Queries.fetchTaskResult(
                on: postgres,
                namespaceID: namespaceID,
                taskID: taskID,
                logger: logger
            )
        else { return nil }
        return taskSnapshot(from: row)
    }

    /// Polls until `taskID` reaches a terminal state, then decodes the result into `T`.
    ///
    /// The return type is inferred from the call-site annotation:
    /// ```swift
    /// let result: OrderOutput = try await client.awaitTaskResult(id: enq.taskID)
    /// // or explicit:
    /// let result = try await client.awaitTaskResult(id: enq.taskID, as: OrderOutput.self)
    /// ```
    public func awaitTaskResult<T: Decodable>(
        id taskID: UUID,
        as type: T.Type = T.self,
        options: AwaitTaskResultOptions = .init()
    ) async throws -> T {
        let snap = try await pollTerminalSnapshot(id: taskID, options: options)
        return try snap.decodeResult(as: type)
    }

    // MARK: - Helpers

    /// Polls the DB until `taskID` is in a terminal state, then returns the snapshot.
    /// Package-internal so `WorkflowHandle` and test helpers can use it directly.
    package func pollTerminalSnapshot(
        id taskID: UUID,
        options: AwaitTaskResultOptions
    ) async throws -> TaskResultSnapshot {
        let start = ContinuousClock.now
        var delay: Duration = .milliseconds(50)
        while true {
            if let row = try await Queries.fetchTaskResult(
                on: postgres,
                namespaceID: namespaceID,
                taskID: taskID,
                logger: logger
            ) {
                let state = TaskState(rawValue: row.state) ?? .pending
                if state == .completed || state == .failed || state == .cancelled {
                    return taskSnapshot(from: row)
                }
            }
            if let t = options.timeout, ContinuousClock.now - start >= t {
                throw StrandError.timeout(message: "Task \(taskID) did not finish within timeout")
            }
            try await Task.sleep(for: delay)
            if delay < .seconds(1) { delay = min(delay * 2, .seconds(1)) }
        }
    }

    func taskSnapshot(from row: TaskResultRow) -> TaskResultSnapshot {
        TaskResultSnapshot(
            taskID: row.taskID,
            state: TaskState(rawValue: row.state) ?? .pending,
            resultJSON: row.resultBuffer.map { String(buffer: $0) },
            failure: nil
        )
    }

    // MARK: - Schema

    public func verifySchema() async throws {
        try await Queries.verifySchema(on: postgres, logger: logger)
        logger.info("schema verified")
    }

    // MARK: - Queue management

    public func createQueue(_ name: String) async throws {
        try await Queries.createQueue(
            on: postgres,
            namespaceID: namespaceID,
            name: name,
            logger: logger
        )
    }

    public func dropQueue(_ name: String) async throws {
        try await Queries.dropQueue(
            on: postgres,
            namespaceID: namespaceID,
            name: name,
            logger: logger
        )
    }

    public func pauseQueue(_ name: String) async throws {
        try await Queries.pauseQueue(
            on: postgres,
            namespaceID: namespaceID,
            name: name,
            logger: logger
        )
    }

    public func resumeQueue(_ name: String) async throws {
        try await Queries.resumeQueue(
            on: postgres,
            namespaceID: namespaceID,
            name: name,
            logger: logger
        )
    }

    /// Enqueues a workflow task using a pre-encoded raw JSON `ByteBuffer` as params.
    ///
    /// This is a `package`-level escape hatch used by `StrandServer` to support
    /// the dashboard trigger endpoint where the caller supplies raw JSON.
    /// `namespaceID` defaults to the client's own namespace; pass an explicit value
    /// to route the task to a different namespace.
    package func enqueueRaw(
        queue: String,
        namespaceID overrideNS: String? = nil,
        taskName: String,
        paramsBuffer: ByteBuffer
    ) async throws -> EnqueueResult {
        let ns = overrideNS ?? self.namespaceID
        let row = try await Queries.enqueueTask(
            on: postgres,
            namespaceID: ns,
            queue: queue,
            taskName: taskName,
            paramsBuffer: paramsBuffer,
            headersBuffer: nil,
            retryStrategyBuffer: nil,
            maxAttempts: nil,
            cancellationBuffer: nil,
            idempotencyKey: nil,
            kind: .workflow,
            logger: logger
        )
        return EnqueueResult(
            taskID: row.taskID,
            runID: row.runID,
            attempt: row.attempt,
            createdAt: Date.now
        )
    }

    public func listQueues() async throws -> [String] {
        try await Queries.listQueues(on: postgres, namespaceID: namespaceID, logger: logger)
    }

    // MARK: - Schedules

    /// Creates or replaces a named schedule.
    ///
    /// The workflow type provides the registered task name — no strings needed.
    /// On name conflict within the queue the schedule is updated in place.
    ///
    /// ```swift
    /// // 9 AM UTC every day
    /// try await client.schedule(
    ///     name: "morning-summary",
    ///     pattern: .daily(offset: "PT9H"),
    ///     workflowType: SummaryWorkflow.self,
    ///     input: SummaryInput()
    /// )
    ///
    /// // Every 90 minutes (ISS orbital period), active since a past date.
    /// // Strand recovers the most recent missed slot on the first poll.
    /// try await client.schedule(
    ///     name: "iss-telemetry",
    ///     pattern: .interval(.seconds(90 * 60)),
    ///     workflowType: SpaceMissionWorkflow.self,
    ///     input: MissionInput(operation: .collectTelemetry),
    ///     startsAt: Date(timeIntervalSinceReferenceDate: 0)  // active since epoch
    /// )
    /// ```
    ///
    /// ## `startsAt` and missed-run recovery
    ///
    /// When `startsAt` is a past date, Strand fast-forwards `nextRunAt` to the
    /// **most recent elapsed slot** rather than the oldest one. On the next
    /// scheduler poll that slot fires immediately, giving you the freshest
    /// missed run. Subsequent fires resume on the normal cadence.
    ///
    /// Example: `.daily(offset: "PT15M")` + `startsAt` = yesterday, registered
    /// at 23:20 UTC today. Without recovery, yesterday's 00:15 slot would fire
    /// and today's would be lost. With recovery, `nextRunAt` advances to today
    /// 00:15 — the scheduler fires it on the next poll, then schedules
    /// tomorrow 00:15.
    ///
    /// Only the single most-recent missed slot fires. Older slots are skipped.
    /// When `startsAt` is `nil` or in the future, no recovery occurs.
    ///
    /// - Parameters:
    ///   - name: Stable human-readable name, unique within the queue.
    ///   - pattern: When to fire — `.cron`, `.interval`, `.daily`, `.weekly`, `.monthly`, or `.once`.
    ///   - workflowType: The ``Workflow`` type to enqueue. The registered name is derived
    ///     from ``WorkflowRegistrable/workflowName``.
    ///   - input: Input forwarded to the workflow on each fire.
    ///   - queue: Target queue. `nil` inherits this client's default queue.
    ///   - startsAt: First eligible fire date. `nil` means active from creation.
    ///     A past date enables missed-run recovery as described above.
    ///   - endsAt: Last eligible fire date. `nil` means runs indefinitely.
    ///     The schedule is deactivated once no future slots remain within the window.
    ///   - options: Retry strategy, max attempts, and extra headers.
    /// - Returns: The schedule's UUID.
    @discardableResult
    public func schedule<W: Workflow>(
        name: String,
        pattern: SchedulePattern,
        workflowType: W.Type,
        input: W.Input,
        queue: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        options: ScheduleOptions = .init()
    ) async throws -> UUID {
        try await _schedule(
            name: name,
            pattern: pattern,
            taskName: W.workflowName,
            params: input,
            queue: queue,
            startsAt: startsAt,
            endsAt: endsAt,
            options: options
        )
    }

    /// Schedules an `ActivityDefinition`-conforming activity on a recurring pattern.
    ///
    /// The activity fires directly — no wrapping workflow is created.
    /// Use this for fire-and-forget work where durable orchestration is not needed.
    /// For retries, error recovery, or multi-step logic, wrap the activity in a
    /// ``WorkflowDefinition`` and use ``schedule(_:workflowType:input:queue:startsAt:endsAt:options:)`` instead.
    @discardableResult
    public func schedule<A: ActivityDefinition>(
        name: String,
        pattern: SchedulePattern,
        activityType: A.Type,
        input: A.Input,
        queue: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        options: ScheduleOptions = .init()
    ) async throws -> UUID {
        try await _schedule(
            name: name,
            pattern: pattern,
            taskName: A.name,
            params: input,
            queue: queue,
            startsAt: startsAt,
            endsAt: endsAt,
            kind: .activity,
            options: options
        )
    }

    /// Schedules an `Activity<P, R>` instance on a recurring pattern.
    ///
    /// The activity fires directly — no wrapping workflow is created.
    @discardableResult
    public func schedule<P: Codable & Sendable, R: Codable & Sendable>(
        name scheduleName: String,
        pattern: SchedulePattern,
        _ activity: Activity<P, R>,
        params: P,
        queue: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        options: ScheduleOptions = .init()
    ) async throws -> UUID {
        try await _schedule(
            name: scheduleName,
            pattern: pattern,
            taskName: activity.name,
            params: params,
            queue: queue ?? activity.queue,
            startsAt: startsAt,
            endsAt: endsAt,
            kind: .activity,
            options: options
        )
    }

    // Private implementation — not public API.
    // The typed `schedule(workflowType:input:)` overload is the only public entry point.
    @discardableResult
    private func _schedule<P: Codable & Sendable>(
        name: String,
        pattern: SchedulePattern,
        taskName: String,
        params: P,
        queue: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        kind: TaskKind = .workflow,
        options: ScheduleOptions = .init()
    ) async throws -> UUID {
        let targetQueue = queue ?? queueName
        let paramsBuffer = try JSON.encode(params)
        let patternBuf = try JSON.encode(pattern)
        let headersBuf = options.headers.isEmpty ? nil : try JSON.encode(options.headers)
        let retryBuf = try options.retryStrategy.map { try JSON.encode($0) }
        let cancelBuf = try options.cancellation.map { try JSON.encode($0) }

        let base = startsAt ?? Date.now
        var nextRunAt = try ScheduleCalculator.initialNextRunTime(
            for: pattern,
            createdAt: base,
            timezone: pattern.timezone
        )

        // When startsAt is in the past, advance nextRunAt to the most recent
        // elapsed slot rather than the oldest one. This fires the freshest
        // missed run on the next scheduler poll instead of stale oldest data.
        //
        // Example: .daily(offset:"PT15M") + startsAt=yesterday registered at
        // 23:20 UTC today → nextRunAt advances to today 00:15 (not yesterday
        // 00:15). The scheduler fires it immediately and then schedules
        // tomorrow 00:15. Without this, yesterday 00:15 fires and today's
        // slot is lost forever.
        //
        // Only the single most-recent elapsed slot is recovered. All older
        // slots are skipped. See the public schedule() doc comment for the
        // full description of this behaviour.
        let registrationTime = Date.now
        if base < registrationTime, let first = nextRunAt, first < registrationTime {
            switch options.accuracy {
            case .latest:
                // Advance to the most-recent elapsed slot — skips stale work.
                if case .interval(let duration, _, _) = pattern {
                    // O(1): jump directly to the most recent interval boundary.
                    // Iterating one step at a time would be O(n) — e.g. a 60-second
                    // interval with startsAt a year ago loops ~525,600 times.
                    let secs = Double(duration.components.seconds)
                    let steps =
                        ((registrationTime.timeIntervalSince1970 - first.timeIntervalSince1970)
                        / secs).rounded(.down)
                    nextRunAt = Date(
                        timeIntervalSince1970: first.timeIntervalSince1970 + steps * secs
                    )
                } else {
                    // daily/weekly/monthly: bounded iterations (≤365/52/12 steps from any
                    // reasonable startsAt), so the loop is acceptable.
                    var candidate = first
                    while let next = try ScheduleCalculator.nextRunTime(
                        for: pattern,
                        after: candidate,
                        timezone: pattern.timezone
                    ),
                        next <= registrationTime
                    {
                        candidate = next
                    }
                    nextRunAt = candidate
                }
            case .all:
                // Keep the oldest missed slot so the scheduler fires them in order.
                nextRunAt = first

            case .last(let n) where n > 0:
                // Fire the last `n` missed slots, skipping older stale ones.
                // Intervals use O(1) arithmetic; cron/daily/weekly/monthly use
                // a Deque sliding window so only n+1 dates are ever in memory.
                if case .interval(let duration, _, _) = pattern {
                    let secs = Double(duration.components.seconds)
                    // timeIntervalSince / addingTimeInterval are the Foundation-idiomatic
                    // form — same pattern as ScheduleCalculator.calculateIntervalScheduledTime.
                    let elapsed = registrationTime.timeIntervalSince(first)
                    let totalSlots = Int(elapsed / secs)
                    let startIndex = max(0, totalSlots - (n - 1))
                    nextRunAt = first.addingTimeInterval(Double(startIndex) * secs)
                } else {
                    var window = Deque<Date>(minimumCapacity: n + 1)
                    window.append(first)
                    var candidate = first
                    while let next = try ScheduleCalculator.nextRunTime(
                        for: pattern,
                        after: candidate,
                        timezone: pattern.timezone
                    ),
                        next <= registrationTime
                    {
                        window.append(next)
                        if window.count > n { window.removeFirst() }  // O(1)
                        candidate = next
                    }
                    nextRunAt = window.first ?? first
                }

            case .last:
                // n <= 0 guard — treat as .latest
                nextRunAt = first
            }
        }

        return try await ScheduleQueries.upsertSchedule(
            on: postgres,
            namespaceID: namespaceID,
            id: UUID.v7(),
            queue: targetQueue,
            name: name,
            taskName: taskName,
            paramsBuffer: paramsBuffer,
            headersBuffer: headersBuf,
            patternBuffer: patternBuf,
            maxAttempts: options.maxAttempts,
            retryStrategyBuffer: retryBuf,
            cancellationBuffer: cancelBuf,
            accuracy: options.accuracy,
            kind: kind,
            startsAt: startsAt,
            endsAt: endsAt,
            nextRunAt: nextRunAt,
            logger: logger
        )
    }

    /// Pauses a schedule — stops it from firing, preserves its state.
    public func pauseSchedule(id: UUID) async throws {
        try await ScheduleQueries.pauseSchedule(
            on: postgres,
            namespaceID: namespaceID,
            id: id,
            logger: logger
        )
    }

    /// Resumes a previously paused schedule.
    public func resumeSchedule(id: UUID) async throws {
        try await ScheduleQueries.resumeSchedule(
            on: postgres,
            namespaceID: namespaceID,
            id: id,
            logger: logger
        )
    }

    /// Permanently deletes a schedule.
    public func deleteSchedule(id: UUID) async throws {
        try await ScheduleQueries.deleteSchedule(
            on: postgres,
            namespaceID: namespaceID,
            id: id,
            logger: logger
        )
    }

    /// Lists schedules for `queue` (or all queues when `queue` is `nil`).
    /// Pass an explicit `namespaceID` to override the client's default (used by
    /// the dashboard API layer to honour the per-request namespace from the URL).
    public func listSchedules(
        queue: String? = nil,
        namespaceID overrideNS: String? = nil
    ) async throws -> [ScheduleSummary] {
        let ns = overrideNS ?? namespaceID
        let rows = try await ScheduleQueries.listSchedules(
            on: postgres,
            namespaceID: ns,
            queue: queue,
            logger: logger
        )
        return try rows.map { row in
            let pattern = try JSON.decode(SchedulePattern.self, from: row.patternBuffer)
            return ScheduleSummary(
                id: row.id,
                name: row.name,
                queue: row.queue,
                taskName: row.taskName,
                pattern: pattern,
                isActive: row.isActive,
                startsAt: row.startsAt,
                endsAt: row.endsAt,
                nextRunAt: row.nextRunAt,
                lastRunAt: row.lastRunAt,
                runCount: row.runCount,
                accuracy: row.accuracy,
                kind: row.kind,
                createdAt: row.createdAt
            )
        }
    }

    // MARK: - Cleanup

    /// Deletes terminal tasks (completed, failed, cancelled) older than `age`
    /// from `queue` (or all queues when `queue` is `nil`).
    ///
    /// Also deletes associated runs, checkpoints, and event-wait registrations.
    /// Returns the number of tasks deleted.
    ///
    /// Safe to call concurrently — uses `FOR UPDATE SKIP LOCKED` internally.
    @discardableResult
    public func cleanup(
        queue: String? = nil,
        olderThan age: Duration? = nil,
        limit: Int = 1000
    ) async throws -> Int {
        try await ManagementQueries.cleanupTasks(
            on: postgres,
            namespaceID: namespaceID,
            queue: queue,
            ageSeconds: age.map { Int($0.components.seconds) },
            limit: limit,
            logger: logger
        )
    }

    // MARK: - Workflow versioning

    /// Forces a specific ``WorkflowContext/version(changeID:)`` checkpoint value for an
    /// in-flight workflow, enabling safe code-deployment migrations.
    ///
    /// When deploying new code with a ``WorkflowContext/version(changeID:)`` guard,
    /// ALL workflow activations (both new and in-flight) return `true` on their first
    /// encounter of that `changeID`. Call this method on existing in-flight workflows
    /// to force them to take the **old** code path on their next activation.
    ///
    /// ```swift
    /// // Before deploying new code, mark in-flight workflows to use old path:
    /// let inFlightIDs: [UUID] = try await client.listInFlightTaskIDs(queue: "orders")
    /// for id in inFlightIDs {
    ///     try await client.markVersion(changeID: "v2-parallel-charge", value: false, taskID: id)
    /// }
    /// // Now deploy the new code — existing workflows use the old path, new ones use new path.
    /// ```
    ///
    /// - Parameters:
    ///   - changeID: Must match exactly what's passed to ``WorkflowContext/version(changeID:)``.
    ///   - value: `false` forces old code path; `true` forces new code path (the default
    ///     for new executions that haven't encountered this `changeID` yet).
    ///   - taskID: The task UUID of the in-flight workflow.
    ///   - callSiteIndex: Which call site to target when `version(changeID:)` is called
    ///     multiple times with the same `changeID`. Defaults to `1` (the first call site).
    /// - Returns: The `value` that was written.
    /// - Throws: ``StrandError/unknownTask(name:)`` when no run is found for `taskID`.
    @discardableResult
    public func markVersion(
        changeID: String,
        value: Bool,
        taskID: UUID,
        callSiteIndex: Int = 1
    ) async throws -> Bool {
        // With the integer-keyed checkpoint schema, `WorkflowContext.version(changeID:)` stores
        // checkpoints keyed by seq_num (monotonic activation counter) with `changeID` as the
        // optional debug label.
        //
        // Strategy:
        //   1. If the version checkpoint was already written (workflow ran past it), look it up
        //      by name and update it in-place.
        //   2. If not yet written (workflow is sleeping before the version call), estimate the
        //      seq_num as (current checkpoint count) + callSiteIndex and INSERT it so the next
        //      activation finds the desired value in its cache.
        let stateBuffer = try JSON.encode(value)

        // Resolve the most recent run for this task.
        let runIDStream = try await postgres.query(
            """
            SELECT id FROM strand.runs
            WHERE task_id = \(taskID)
              AND namespace_id = \(namespaceID)
            ORDER BY attempt DESC
            LIMIT 1
            """,
            logger: logger
        )
        guard let runRow = try await runIDStream.first(where: { _ in true }) else {
            throw StrandError.unknownTask(name: taskID.uuidString)
        }
        var col = runRow.makeIterator()
        let runID = try col.next()!.decode(UUID.self, context: .default)

        // Look up an existing checkpoint by debug name + call-site offset.
        let existingStream = try await postgres.query(
            """
            SELECT seq_num FROM strand.checkpoints
            WHERE task_id = \(taskID)
              AND run_id  = \(runID)
              AND name    = \(changeID)
            ORDER BY seq_num ASC
            LIMIT 1
            OFFSET \(callSiteIndex - 1)
            """,
            logger: logger
        )

        let seqNum: Int
        if let existingRow = try await existingStream.first(where: { _ in true }) {
            // Checkpoint already written — reuse its seq_num.
            var seqCol = existingRow.makeIterator()
            seqNum = try seqCol.next()!.decode(Int.self, context: .default)
        } else {
            // Checkpoint not yet written (workflow sleeping before the version call).
            // Estimate position: (count of already-written checkpoints) + callSiteIndex.
            let countStream = try await postgres.query(
                """
                SELECT COUNT(*) FROM strand.checkpoints
                WHERE task_id = \(taskID) AND run_id = \(runID)
                """,
                logger: logger
            )
            var countCol = try await countStream.first(where: { _ in true })!.makeIterator()
            let count = try countCol.next()!.decode(Int.self, context: .default)
            seqNum = count + callSiteIndex
        }

        try await Queries.setCheckpointState(
            on: postgres,
            namespaceID: namespaceID,
            taskID: taskID,
            seqNum: seqNum,
            name: changeID,
            stateBuffer: stateBuffer,
            runID: runID,
            extendClaimBySeconds: nil,
            logger: logger
        )
        return value
    }
}

// MARK: - StrandOptions

public struct StrandOptions: Sendable {
    public var defaultMaxAttempts: Int
    public var defaultRetryStrategy: RetryStrategy
    public var logger: Logger
    public var onTaskStarted: (@Sendable (TaskInfo) async -> Void)?
    public var onTaskFinished: (@Sendable (TaskInfo, Result<Void, any Error>) async -> Void)?

    public init(
        defaultMaxAttempts: Int = 5,
        defaultRetryStrategy: RetryStrategy = .backoff(
            initial: .seconds(2),
            multiplier: 2,
            cap: .seconds(300)
        ),
        logger: Logger = Logger(label: "dev.strand"),
        onTaskStarted: (@Sendable (TaskInfo) async -> Void)? = nil,
        onTaskFinished: (@Sendable (TaskInfo, Result<Void, any Error>) async -> Void)? = nil
    ) {
        self.defaultMaxAttempts = defaultMaxAttempts
        self.defaultRetryStrategy = defaultRetryStrategy
        self.logger = logger
        self.onTaskStarted = onTaskStarted
        self.onTaskFinished = onTaskFinished
    }
}

// MARK: - TaskInfo

public struct TaskInfo: Sendable {
    public let taskID: String
    public let runID: String
    public let taskName: String
    public let queueName: String
    public let attempt: Int
}
