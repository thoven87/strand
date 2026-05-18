import DequeModule
public import Logging
import NIOCore
// Re-export PostgresNIO so callers can use PostgresClient without an explicit import.
public import PostgresNIO
import Tracing

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

    // MARK: - Activity (standalone Activity dispatch)

    /// Enqueues an ``Activity`` as a standalone unit of work without a
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
    public func enqueueActivity<A: Activity>(
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
            idempotencyKey: options.id,
            priority: options.priority,
            delayUntil: options.delayUntil,
            maxDuration: options.maxDuration,
            heartbeatTimeoutSeconds: options.heartbeatTimeout.map { Int($0.components.seconds) },
            scheduleToStartTimeoutSeconds: options.scheduleToStartTimeout.map { Int($0.components.seconds) },
            parentClosePolicy: options.cancellationType == .abandon ? .abandon : nil,
            fairnessKey: options.fairnessKey,
            fairnessWeight: options.fairnessWeight,
            kind: .activity,
            parentTaskID: nil
        )
    }

    /// Enqueues an ``Activity`` and polls until it completes, returning
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
    public func runActivity<A: Activity>(
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
            let retryState: ActivityRetryState = snap.state == .cancelled ? .cancelled : .maximumAttemptsReached
            throw ActivityError(activityName: A.name, retryState: retryState, cause: nil)
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
        let workflowDeadlineAt: Date? = options.maxDuration.map { Date.now.addingDuration($0) }

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
            priority: options.priority,
            scheduledAt: options.delayUntil,
            deadlineAt: workflowDeadlineAt,
            fairnessKey: options.fairnessKey,
            fairnessWeight: options.fairnessWeight,
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
        heartbeatTimeoutSeconds: Int? = nil,
        scheduleToStartTimeoutSeconds: Int? = nil,
        parentClosePolicy: ParentClosePolicy? = nil,
        fairnessKey: String? = nil,
        fairnessWeight: Double = 1.0,
        kind: TaskKind = .workflow,
        parentTaskID: UUID? = nil
    ) async throws -> EnqueueResult {
        let deadlineAt: Date? = maxDuration.map { Date.now.addingDuration($0) }
        // Producer span: wraps the DB insert so that the context injected into
        // task headers IS this span's context. The worker's consumer span then
        // addLink-s back here, completing the producer → consumer trace link.
        // Zero-cost no-op when no tracing backend is bootstrapped.
        return try await withSpan(taskName, ofKind: .producer) { span in
            span.attributes[StrandLogKeys.taskName] = SpanAttribute.string(taskName)
            span.attributes[StrandLogKeys.queue] = SpanAttribute.string(queue)
            span.attributes[StrandLogKeys.namespace] = SpanAttribute.string(namespaceID)

            // Inject inside the producer span — ServiceContext.current is the
            // producer span itself, which is what the consumer will link back to.
            var h = headers
            if let ctx = ServiceContext.current {
                InstrumentationSystem.tracer.inject(ctx, into: &h, using: DictionaryInjector())
            }

            let row = try await Queries.enqueueTask(
                on: postgres,
                namespaceID: namespaceID,
                queue: queue,
                taskName: taskName,
                paramsBuffer: try JSON.encode(params),
                headersBuffer: h.isEmpty ? nil : try JSON.encode(h),
                retryStrategyBuffer: try JSON.encode(retryStrategy),
                maxAttempts: maxAttempts,
                cancellationBuffer: try cancellation.map { try JSON.encode($0) },
                idempotencyKey: idempotencyKey,
                priority: priority,
                scheduledAt: delayUntil,
                heartbeatTimeoutSeconds: heartbeatTimeoutSeconds,
                scheduleToStartTimeoutSeconds: scheduleToStartTimeoutSeconds,
                deadlineAt: deadlineAt,
                fairnessKey: fairnessKey,
                fairnessWeight: fairnessWeight,
                kind: kind,
                parentTaskID: parentTaskID,
                parentClosePolicy: parentClosePolicy,
                logger: logger
            )
            return EnqueueResult(
                taskID: row.taskID,
                runID: row.runID,
                attempt: row.attempt,
                createdAt: Date.now
            )
        }
    }

    // MARK: - Events

    /// Forwards raw payload bytes to `Queries.emitEvent`. Used by server routes
    /// that receive JSON directly from an HTTP request body and must not re-encode it.
    /// Not part of the public API — call sites outside `StrandServer` should use
    /// the `Codable` overload instead.
    package func emitEvent(
        _ name: String,
        payloadBuffer: ByteBuffer?,
        queue: String? = nil,
        namespaceID: String? = nil
    ) async throws {
        let stored = payloadBuffer ?? ByteBuffer(string: "null")
        try await Queries.emitEvent(
            on: postgres,
            namespaceID: namespaceID ?? self.namespaceID,
            queue: queue ?? queueName,
            eventName: name,
            payloadBuffer: stored,
            logger: logger
        )
    }

    /// Emits a named event by string — for dynamic names (e.g. `"order.shipped:\(id)"`).
    ///
    /// Pass `namespaceID: ctx.namespaceID` when calling from a server route so
    /// the event lands in the correct tenant. Defaults to the client's own namespace.
    ///
    /// - Parameters:
    ///   - namespaceID: Namespace to scope the emission to. Pass the request-level
    ///     namespace (e.g. `ctx.namespaceID`) when calling from a server route so
    ///     the event lands in the correct tenant. Defaults to the client's own namespace.
    public func emitEvent(
        _ name: String,
        payload: some Codable & Sendable,
        queue: String? = nil,
        namespaceID: String? = nil
    ) async throws {
        try await Queries.emitEvent(
            on: postgres,
            namespaceID: namespaceID ?? self.namespaceID,
            queue: queue ?? queueName,
            eventName: name,
            payloadBuffer: try JSON.encode(payload),
            logger: logger
        )
    }

    /// Emits a typed event by name. Any workflow waiting for `E.name` whose
    /// `matching:` predicate is satisfied by this payload will be woken.
    ///
    /// ```swift
    /// // From an HTTP handler — routing is done by the waiter's predicate:
    /// try await client.emit(OrderApprovedEvent.self,
    ///     payload: ApprovalPayload(orderId: "abc-123", approved: true))
    /// ```
    public func emit<E: WorkflowEvent>(
        _ eventType: E.Type,
        payload: E.Payload,
        queue: String? = nil
    ) async throws {
        try await emitEvent(E.name, payload: payload, queue: queue)
    }

    // MARK: - Task control

    public func cancelTask(id taskID: UUID, namespaceID overrideNS: String? = nil) async throws {
        try await Queries.cancelTask(
            on: postgres,
            namespaceID: overrideNS ?? namespaceID,
            taskID: taskID,
            logger: logger
        )
    }

    /// Cancels multiple tasks atomically.
    ///
    /// Each task’s descendants are also cancelled. Any `awaitTaskResult`
    /// calls waiting on these tasks are unblocked with a `.cancelled` state.
    ///
    /// For cancelling a single task prefer ``cancelTask(id:)``.
    /// For a large batch consider chunking into groups of 500–1000.
    @discardableResult
    public func cancelTasks(_ taskIDs: [UUID]) async throws -> Int {
        try await Queries.cancelTasksBatch(
            on: postgres,
            namespaceID: namespaceID,
            taskIDs: taskIDs,
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
        options: RetryOptions = .init(),
        namespaceID overrideNS: String? = nil
    ) async throws
        -> EnqueueResult
    {
        let ns = overrideNS ?? namespaceID
        // Peek at state to choose the right path.
        guard
            let snap = try await ManagementQueries.getTask(
                on: postgres,
                namespaceID: ns,
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
                namespaceID: ns,
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
            // FAILED, CANCELLED, or any other terminal state.
            //
            // Step 1: reset descendant tasks based on the retry mode.
            //   - failedOnly           -> descendants in FAILED/CANCELLED state
            //   - failedAndDependents  -> above + temporally later descendants
            //   - all                  -> every descendant regardless of state
            // Deletes their task_completions rows and creates fresh PENDING runs so
            // the parent's next activation re-runs them instead of replaying cached
            // failures. Safe no-op when the selected task has no descendants
            // (e.g. a plain activity).
            try await Queries.resetChildTasks(
                on: postgres,
                rootTaskID: taskID,
                namespaceID: ns,
                mode: options.mode,
                resetHistory: options.resetHistory,
                logger: logger
            )
            // Step 2: retry the root task itself.
            let (runID, attempt) = try await Queries.retryTask(
                on: postgres,
                namespaceID: ns,
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

    /// Ensures this client's namespace exists in `strand.namespaces`.
    /// Idempotent — safe to call on every boot (`ON CONFLICT DO NOTHING`).
    /// `StrandWorker` calls this automatically; call it explicitly when a
    /// service (e.g. `StrandScheduler`) operates in a namespace before any
    /// worker has had a chance to register it.
    public func registerNamespace() async throws {
        try await Queries.registerNamespace(on: postgres, namespaceID: namespaceID, logger: logger)
    }

    // MARK: - Queue management

    public func createQueue(_ name: String, namespaceID overrideNS: String? = nil) async throws {
        try await Queries.createQueue(
            on: postgres,
            namespaceID: overrideNS ?? namespaceID,
            name: name,
            logger: logger
        )
    }

    public func dropQueue(_ name: String, namespaceID overrideNS: String? = nil) async throws {
        try await Queries.dropQueue(
            on: postgres,
            namespaceID: overrideNS ?? namespaceID,
            name: name,
            logger: logger
        )
    }

    public func pauseQueue(_ name: String, namespaceID overrideNS: String? = nil) async throws {
        try await Queries.pauseQueue(
            on: postgres,
            namespaceID: overrideNS ?? namespaceID,
            name: name,
            logger: logger
        )
    }

    public func resumeQueue(_ name: String, namespaceID overrideNS: String? = nil) async throws {
        try await Queries.resumeQueue(
            on: postgres,
            namespaceID: overrideNS ?? namespaceID,
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
    /// Use this for **runtime schedule creation** (e.g. from an HTTP API or
    /// a workflow).  For schedules known at startup, declare them on
    /// ``StrandScheduler`` instead so they are upserted before the first poll.
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
    /// at 23:20 UTC today. Without recovery, yesterday’s 00:15 slot would fire
    /// and today’s would be lost. With recovery, `nextRunAt` advances to today
    /// 00:15 — the scheduler fires it on the next poll, then schedules
    /// tomorrow 00:15.
    ///
    /// Only the single most-recent missed slot fires. Older slots are skipped.
    /// When `startsAt` is `nil` or in the future, no recovery occurs.
    ///
    /// - Parameters:
    ///   - name: Stable human-readable name, unique within the queue.
    ///   - pattern: When to fire — `.cron`, `.interval`, `.daily`, `.weekly`, `.monthly`, or `.once`.
    ///   - workflowType: The ``Workflow`` type to enqueue on each fire.
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

    /// Schedules an ``Activity``-conforming activity on a recurring pattern.
    ///
    /// The activity fires directly — no wrapping workflow is created.
    /// Buffering / lifecycle semantics are identical to the workflow overload.
    @discardableResult
    public func schedule<A: Activity>(
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

    // MARK: - Schedule implementation

    /// Shared implementation for all `schedule()` overloads.
    /// `now` defaults to `Date.now`; pass a fixed value in tests to make
    /// catch-up assertions deterministic without touching the wall clock.
    @discardableResult
    func _schedule<P: Codable & Sendable>(
        name: String,
        pattern: SchedulePattern,
        taskName: String,
        params: P,
        queue: String? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        kind: TaskKind = .workflow,
        options: ScheduleOptions = .init(),
        now: Date = .now
    ) async throws -> UUID {
        let targetQueue = queue ?? queueName
        let paramsBuffer = try JSON.encode(params)
        let patternBuf = try JSON.encode(pattern)
        let headersBuf = options.headers.isEmpty ? nil : try JSON.encode(options.headers)
        let retryBuf = try options.retryStrategy.map { try JSON.encode($0) }
        let cancelBuf = try options.cancellation.map { try JSON.encode($0) }

        // For an already-running schedule (last_run_at IS NOT NULL in the DB),
        // anchor the catch-up computation from the last fired slot rather than
        // Date.now.  Using Date.now produces `nextRunAt = now + interval`, which
        // is always future and always "wins" comparisons against any overdue or
        // correctly-pending slot in the DB.
        //
        // Using last_run_at lets the accuracy logic correctly identify the
        // most-recently-missed slot (e.g. for .latest: the slot just before NOW()
        // anchored from last_run_at) so re-registration heals rather than
        // corrupts the schedule state.
        let base: Date
        if let explicit = startsAt {
            base = explicit
        } else if let lastSlot = try? await ScheduleQueries.lastSlotAt(
            on: postgres,
            namespaceID: namespaceID,
            queue: targetQueue,
            name: name,
            logger: logger
        ) {
            base = lastSlot
        } else {
            base = Date.now
        }
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
        let registrationTime = now
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
                // Set next_run_at to the oldest missed slot.  fire() will iterate
                // forward from there, enqueuing every overdue slot in a single
                // invocation (up to SchedulerOptions.maxCatchupSlots per poll).
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
    ///
    /// - Parameter recomputeFrom: When provided, `next_run_at` is advanced to
    ///   this date before reactivation, skipping any slots that fell due while
    ///   the schedule was paused.  Pass `Date.now` to resume from the present
    ///   moment.  When `nil` the existing `next_run_at` is preserved.
    public func resumeSchedule(id: UUID, recomputeFrom: Date? = nil) async throws {
        try await ScheduleQueries.resumeSchedule(
            on: postgres,
            namespaceID: namespaceID,
            id: id,
            recomputeFrom: recomputeFrom,
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

    /// Fetches a single schedule by ID.  Returns `nil` when not found.
    ///
    /// The returned `ScheduleSummary` is built from ``ScheduleFullRow``, which
    /// is ever needed.
    public func getSchedule(
        id: UUID,
        queue: String? = nil,
        namespaceID overrideNS: String? = nil
    ) async throws -> ScheduleSummary? {
        let ns = overrideNS ?? namespaceID
        guard
            let row = try await ScheduleQueries.getSchedule(
                on: postgres,
                namespaceID: ns,
                id: id,
                logger: logger
            )
        else { return nil }
        guard let pattern = try? JSON.decode(SchedulePattern.self, from: row.patternBuffer) else {
            return nil
        }
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
            lastTaskID: row.lastTaskID,
            runCount: row.runCount,
            accuracy: row.accuracy,
            kind: row.kind,
            createdAt: row.createdAt
        )
    }

    /// Enqueues a single execution for a specific schedule slot ("run for partition").
    ///
    /// Uses the same idempotency key format as `StrandScheduler.fire()` so a slot
    /// already executed by the regular schedule is blocked via `ON CONFLICT` unless
    /// `allowOverwrite` is `true`.
    @discardableResult
    public func runScheduleSlot(
        scheduleID: UUID,
        partitionTime: Date,
        allowOverwrite: Bool = false,
        namespaceID overrideNS: String? = nil
    ) async throws -> (taskID: UUID, runID: UUID) {
        let ns = overrideNS ?? namespaceID
        guard
            let schedule = try await ScheduleQueries.getSchedule(
                on: postgres,
                namespaceID: ns,
                id: scheduleID,
                logger: logger
            )
        else {
            throw StrandError.database(underlying: QueryError("schedule '\(scheduleID)' not found"))
        }
        let idempotencyKey: String? =
            allowOverwrite
            ? nil
            : "$schedule:\(scheduleID):\(partitionTime.timeIntervalSince1970)"
        let meta = SchedulingMetadata(
            executionTime: Date(),
            partitionTime: partitionTime,
            scheduleId: scheduleID.uuidString,
            scheduledBy: schedule.name
        )
        let enqueued = try await Queries.enqueueTask(
            on: postgres,
            namespaceID: ns,
            queue: schedule.queue,
            taskName: schedule.taskName,
            paramsBuffer: schedule.paramsBuffer,
            headersBuffer: schedule.headersBuffer,
            schedulingMetadata: meta,
            retryStrategyBuffer: schedule.retryStrategyBuffer,
            maxAttempts: schedule.maxAttempts,
            cancellationBuffer: schedule.cancellationBuffer,
            idempotencyKey: idempotencyKey,
            kind: schedule.kind,
            logger: logger
        )
        return (taskID: enqueued.taskID, runID: enqueued.runID)
    }

    /// Lists schedules for `queue` (or all queues when `queue` is `nil`).
    /// Pass an explicit `namespaceID` to override the client's default (used by
    /// the dashboard API layer to honour the per-request namespace from the URL).
    /// Lists schedules with optional keyset pagination.
    ///
    /// To advance through pages pass the `queue` and `name` of the **last row**
    /// on the current page as `afterQueue` and `afterName` respectively.
    public func listSchedules(
        queue: String? = nil,
        namespaceID overrideNS: String? = nil,
        limit: Int = 200,
        afterQueue: String? = nil,
        afterName: String? = nil
    ) async throws -> [ScheduleSummary] {
        let ns = overrideNS ?? namespaceID
        let rows = try await ScheduleQueries.listSchedules(
            on: postgres,
            namespaceID: ns,
            queue: queue,
            limit: limit,
            afterQueue: afterQueue,
            afterName: afterName,
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
                lastTaskID: row.lastTaskID,
                runCount: row.runCount,
                accuracy: row.accuracy,
                kind: row.kind,
                createdAt: row.createdAt
            )
        }
    }

    // MARK: - Backfill

    /// Creates a backfill that retroactively executes `workflowType` for every
    /// schedule slot between `range.lowerBound` (inclusive) and `range.upperBound`
    /// (exclusive).
    ///
    /// The `StrandScheduler` drives execution: it enqueues up to
    /// `options.concurrency` slots per poll cycle without occupying worker
    /// task-queue slots for orchestration.
    @discardableResult
    public func createBackfill<W: Workflow>(
        _ workflowType: W.Type,
        input: W.Input,
        schedule: SchedulePattern,
        range: Range<Date>,
        queue overrideQueue: String? = nil,
        scheduleId: UUID? = nil,
        options: BackfillOptions = .init()
    ) async throws -> BackfillHandle where W.Input: Codable & Sendable {
        let q = overrideQueue ?? queueName
        let paramsBuffer = try JSON.encode(input)
        let patternBuffer = try JSON.encode(schedule)
        let id = UUID.v7()
        // Subtract 1 s so the start is inclusive: nextRunTime finds the slot AT
        // lowerBound when it coincides with a schedule boundary
        // (-1 ms adjustment on BackfillRequest.StartTime).
        let firstSlot =
            try ScheduleCalculator.nextRunTime(
                for: schedule,
                after: range.lowerBound.addingTimeInterval(-1),
                timezone: schedule.timezone
            ) ?? range.lowerBound
        let totalSlots = ScheduleCalculator.countSlots(for: schedule, in: range)
        try await BackfillQueries.createBackfill(
            on: postgres,
            id: id,
            namespaceID: namespaceID,
            queue: q,
            taskName: W.workflowName,
            taskKind: .workflow,
            paramsBuffer: paramsBuffer,
            headersBuffer: nil,
            retryStrategyBuffer: nil,
            maxAttempts: nil,
            schedulePatternBuffer: patternBuffer,
            rangeStart: range.lowerBound,
            rangeEnd: range.upperBound,
            concurrency: options.concurrency,
            allowOverwrite: options.allowOverwrite,
            description: options.description,
            scheduleId: scheduleId,
            nextSlotTime: firstSlot,
            totalSlots: totalSlots,
            logger: logger
        )
        return BackfillHandle(id: id, postgres: postgres, namespaceID: namespaceID, logger: logger)
    }

    /// Creates a backfill for a standalone activity.
    @discardableResult
    public func createBackfill<A: Activity>(
        _ activityType: A.Type,
        input: A.Input,
        schedule: SchedulePattern,
        range: Range<Date>,
        queue overrideQueue: String? = nil,
        scheduleId: UUID? = nil,
        options: BackfillOptions = .init()
    ) async throws -> BackfillHandle where A.Input: Codable & Sendable {
        let q = overrideQueue ?? queueName
        let paramsBuffer = try JSON.encode(input)
        let patternBuffer = try JSON.encode(schedule)
        let id = UUID.v7()
        let firstSlot =
            try ScheduleCalculator.nextRunTime(
                for: schedule,
                after: range.lowerBound.addingTimeInterval(-1),
                timezone: schedule.timezone
            ) ?? range.lowerBound
        let totalSlots = ScheduleCalculator.countSlots(for: schedule, in: range)
        try await BackfillQueries.createBackfill(
            on: postgres,
            id: id,
            namespaceID: namespaceID,
            queue: q,
            taskName: A.name,
            taskKind: .activity,
            paramsBuffer: paramsBuffer,
            headersBuffer: nil,
            retryStrategyBuffer: nil,
            maxAttempts: nil,
            schedulePatternBuffer: patternBuffer,
            rangeStart: range.lowerBound,
            rangeEnd: range.upperBound,
            concurrency: options.concurrency,
            allowOverwrite: options.allowOverwrite,
            description: options.description,
            scheduleId: scheduleId,
            nextSlotTime: firstSlot,
            totalSlots: totalSlots,
            logger: logger
        )
        return BackfillHandle(id: id, postgres: postgres, namespaceID: namespaceID, logger: logger)
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

    /// Forces a specific ``WorkflowContext/version(changeID:)`` gate value for an
    /// in-flight workflow, enabling safe code-deployment migrations.
    ///
    /// When deploying new code guarded by ``WorkflowContext/version(changeID:)``, all
    /// new workflow instances return `true` on their first encounter of that `changeID`.
    /// Call this method on existing in-flight workflows **before** deploying to force
    /// them to take the pre-change code path on their next activation.
    ///
    /// ```swift
    /// // Before deploying the updated code, mark in-flight workflows to use the pre-change path:
    /// let inFlightIDs: [UUID] = try await client.listInFlightTaskIDs(queue: "orders")
    /// for id in inFlightIDs {
    ///     try await client.markVersion(changeID: "v2-parallel-charge", value: false, taskID: id)
    /// }
    /// // Deploy the updated code — in-flight workflows follow the pre-change path, new ones the post-change path.
    /// ```
    ///
    /// - Parameters:
    ///   - changeID: Must match exactly what's passed to ``WorkflowContext/version(changeID:)``.
    ///   - value: `false` pins the workflow to the pre-change code path; `true` to the
    ///     post-change path (the default for new executions).
    ///   - taskID: The task UUID of the in-flight workflow.
    /// - Returns: The `value` that was written.
    @discardableResult
    public func markVersion(
        changeID: String,
        value: Bool,
        taskID: UUID
    ) async throws -> Bool {
        try await WorkflowStateQueries.writeVersionMarker(
            on: postgres,
            namespaceID: namespaceID,
            taskID: taskID,
            changeID: changeID,
            value: value,
            logger: logger
        )
        return value
    }

    /// Returns the migration status for a version gate across all in-flight workflows
    /// in this namespace.
    ///
    /// Use this to determine when it is safe to remove the `else` branch of a
    /// ``WorkflowContext/version(changeID:)`` guard:
    ///
    /// ```swift
    /// let status = try await client.migrationStatus(changeID: "add-fraud-check")
    /// if status.isSafeToRemove {
    ///     // Every in-flight workflow has passed the gate on the new path.
    ///     // Safe to delete the else branch in the next deploy.
    /// } else {
    ///     print("\(status.pendingCount) workflows still on the old path")
    /// }
    /// ```
    ///
    /// - Parameter changeID: Must match exactly what's passed to
    ///   ``WorkflowContext/version(changeID:)``.
    public func migrationStatus(changeID: String) async throws -> MigrationStatus {
        try await WorkflowStateQueries.versionMigrationStatus(
            on: postgres,
            namespaceID: namespaceID,
            changeID: changeID,
            logger: logger
        )
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
