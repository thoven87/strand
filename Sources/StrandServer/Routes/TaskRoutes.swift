import Hummingbird
import PostgresNIO
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct TaskRoutes {
    let client: StrandClient
    let postgres: PostgresClient

    private struct EnqueueTaskBody: Decodable {
        let name: String
        let params: String
        let idempotencyKey: String?
        let maxAttempts: Int?
    }

    private struct SignalBody: Decodable {
        let name: String
        let payload: String?  // optional JSON string; forwarded as raw bytes
    }

    func register(on router: some RouterMethods<StrandRequestContext>) {

        // GET /api/:namespace/task-definitions
        // One row per (name, kind) for root tasks — both WORKFLOW and ACTIVITY.
        // Used by the Tasks definitions page in the dashboard.
        router.get("task-definitions") { _, ctx -> [TaskDefinitionResponse] in
            let rows = try await ManagementQueries.listTaskDefinitions(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                kind: nil,  // all kinds
                logger: self.client.logger
            )
            return rows.map(TaskDefinitionResponse.init)
        }

        // GET /api/:namespace/task-kinds
        // Returns (name, kind) for every distinct task name — including child
        // workflows — so the dashboard can badge them in the metrics latency table.
        router.get("task-kinds") { req, ctx -> [[String: String]] in
            let limit = req.uri.queryParameters.get("limit").flatMap(Int.init) ?? 200
            let pairs = try await ManagementQueries.listTaskKinds(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                limit: min(limit, 2_000),
                logger: self.client.logger
            )
            return pairs.map { ["name": $0.name, "kind": $0.kind.rawValue] }
        }

        // GET /api/:namespace/task-definitions/:name/activity?days=7
        // Returns daily run counts for the last N days.
        // Used by the sparkline on the Tasks definitions page.
        router.get("task-definitions/:name/activity") { req, ctx -> [DailyRunCountResponse] in
            let name = try ctx.parameters.require("name")
            let days = req.uri.queryParameters.get("days").flatMap(Int.init) ?? 7
            let rows = try await ManagementQueries.taskDefinitionActivity(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                name: name,
                days: max(1, min(days, 90)),
                logger: self.client.logger
            )
            return rows.map {
                DailyRunCountResponse(date: $0.date, total: $0.total, failed: $0.failed)
            }
        }

        // GET /api/:namespace/tasks?queue=&state=&limit=&cursor=
        // Global cross-queue task list. `queue` is optional; omit for all queues.
        router.get("tasks") { req, ctx -> CursorPageResponse<TaskSummaryResponse> in
            let qp = req.uri.queryParameters
            let queue = qp.get("queue")  // nil = all queues
            let state = qp.get("state")
            let name = qp.get("name")
            let kind = qp.get("kind").flatMap { TaskKind(rawValue: $0) }  // "WORKFLOW" | "ACTIVITY" | nil = all
            let rootOnly: Bool? = qp.get("rootOnly").map { $0 == "true" }
            let limit = qp.get("limit").flatMap(Int.init) ?? 50
            let cursor = qp.get("cursor").flatMap { UUID(uuidString: $0) }
            do {
                let page = try await ManagementQueries.listTasks(
                    on: self.postgres,
                    namespaceID: ctx.namespaceID,
                    queue: queue,
                    state: state,
                    name: name,
                    kind: kind,
                    rootOnly: rootOnly,
                    cursor: cursor,
                    limit: min(limit, 200),
                    logger: self.client.logger
                )
                return CursorPageResponse(
                    items: page.items.map(TaskSummaryResponse.init),
                    nextCursor: page.nextCursor
                )
            } catch {
                ctx.logger.error(
                    "Failed to list tasks:",
                    metadata: [
                        "error": "\(String(reflecting: error))"
                    ]
                )
                throw error
            }
        }

        router.get("queues/:queue/tasks") {
            req,
            ctx -> CursorPageResponse<TaskSummaryResponse> in
            let queue = try ctx.parameters.require("queue")
            let qp = req.uri.queryParameters
            let state = qp.get("state")
            let name = qp.get("name")
            let limit = qp.get("limit").flatMap(Int.init) ?? 50
            let cursor = qp.get("cursor").flatMap { UUID(uuidString: $0) }
            let page = try await ManagementQueries.listTasks(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                queue: queue,
                state: state,
                name: name,
                cursor: cursor,
                limit: min(limit, 200),
                logger: self.client.logger
            )
            return CursorPageResponse(
                items: page.items.map(TaskSummaryResponse.init),
                nextCursor: page.nextCursor
            )
        }

        router.post("queues/:queue/tasks") { req, ctx -> EnqueueResultResponse in
            let queue = try ctx.parameters.require("queue")
            let body = try await req.decode(as: EnqueueTaskBody.self, context: ctx)
            let result = try await self.client.enqueueRaw(
                queue: queue,
                namespaceID: ctx.namespaceID,
                taskName: body.name,
                paramsBuffer: ByteBuffer(string: body.params)
            )
            return EnqueueResultResponse(from: result)
        }

        router.get("queues/:queue/tasks/:taskID") { _, ctx -> TaskDetailResponse in
            let taskID = try ctx.parameters.require("taskID", as: UUID.self)
            guard
                let row = try await ManagementQueries.getTask(
                    on: self.postgres,
                    namespaceID: ctx.namespaceID,
                    taskID: taskID,
                    logger: self.client.logger
                )
            else {
                throw HTTPError(.notFound, message: "Task not found")
            }
            return TaskDetailResponse(from: row)
        }

        // GET /api/:namespace/queues/:queue/tasks/:taskID/children
        // Returns tasks spawned by this task (parent_task_id = taskID).
        // Used by the task detail page to show activities a workflow launched.
        router.get("queues/:queue/tasks/:taskID/children") {
            req,
            ctx -> CursorPageResponse<TaskSummaryResponse> in
            let taskID = try ctx.parameters.require("taskID", as: UUID.self)
            let qp = req.uri.queryParameters
            let limit = qp.get("limit").flatMap(Int.init) ?? 50
            let cursor = qp.get("cursor").flatMap { UUID(uuidString: $0) }

            let page = try await ManagementQueries.listChildTasks(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                parentTaskID: taskID,
                cursor: cursor,
                limit: min(limit, 200),
                logger: self.client.logger
            )
            return CursorPageResponse(
                items: page.items.map(TaskSummaryResponse.init),
                nextCursor: page.nextCursor
            )
        }

        router.post("queues/:queue/tasks/:taskID/cancel") { _, ctx -> SimpleResponse in
            let taskID = try ctx.parameters.require("taskID", as: UUID.self)
            try await self.client.cancelTask(id: taskID, namespaceID: ctx.namespaceID)
            return SimpleResponse(message: "cancelled", id: taskID.uuidString)
        }

        router.post("queues/:queue/tasks/:taskID/retry") { req, ctx -> EnqueueResultResponse in
            let taskId = try ctx.parameters.require("taskID", as: UUID.self)
            // Body is optional — callers that send no body get default RetryOptions.
            let options =
                (try? await req.decode(as: RetryOptions.self, context: ctx)) ?? RetryOptions()
            do {
                let result = try await self.client.requeueTask(id: taskId, options: options, namespaceID: ctx.namespaceID)
                return EnqueueResultResponse(from: result)
            } catch {
                self.client.logger.error(
                    "Failed to re-run task",
                    metadata: [
                        "task_id": .stringConvertible(taskId),
                        "error": .string(String(reflecting: error)),
                    ]
                )
                throw HTTPError(.internalServerError, message: "Failed to re-run task")
            }
        }

        // GET /api/:namespace/queues/:queue/tasks/:taskID/history
        router.get("queues/:queue/tasks/:taskID/history") { _, ctx -> [HistoryEventResponse] in
            let taskID = try ctx.parameters.require("taskID", as: UUID.self)
            let rows = try await WorkflowStateQueries.listHistory(
                on: self.postgres,
                taskID: taskID,
                logger: self.client.logger
            )
            return rows.map(HistoryEventResponse.init)
        }

        // POST /api/:namespace/queues/:queue/tasks/:taskID/signal
        router.post("queues/:queue/tasks/:taskID/signal") { req, ctx -> SimpleResponse in
            let taskID = try ctx.parameters.require("taskID", as: UUID.self)
            let body = try await req.decode(as: SignalBody.self, context: ctx)
            let payloadBuf: ByteBuffer? = body.payload.map { ByteBuffer(string: $0) }
            try await self.client._sendSignal(
                name: body.name,
                payload: payloadBuf,
                toWorkflowTaskID: taskID,
                namespaceID: ctx.namespaceID
            )
            return SimpleResponse(message: "signal sent", id: taskID.uuidString)
        }

        // GET /api/:namespace/queues/:queue/tasks/:taskID/state
        // Returns the persisted workflow state, or `null` when none has been
        // written yet (state is only persisted on the first signal delivery or
        // workflow completion). 404 would be misleading here since "no state
        // yet" is a perfectly valid condition for any running workflow.
        router.get("queues/:queue/tasks/:taskID/state") { _, ctx -> WorkflowStateResponse? in
            let taskID = try ctx.parameters.require("taskID", as: UUID.self)
            guard
                let buf = try await WorkflowStateQueries.loadState(
                    on: self.postgres,
                    taskID: taskID,
                    namespaceID: ctx.namespaceID,
                    logger: self.client.logger
                )
            else {
                return nil
            }
            return WorkflowStateResponse(state: String(buffer: buf))
        }

        // GET /api/:namespace/tasks/:taskID/trace
        router.get("tasks/:taskID/trace") { _, ctx -> [TraceSpanResponse] in
            let taskID = try ctx.parameters.require("taskID", as: UUID.self)
            let rows = try await ManagementQueries.traceTask(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                rootTaskID: taskID,
                logger: self.client.logger
            )
            guard let root = rows.first(where: { $0.depth == 0 }) else {
                throw HTTPError(.notFound, message: "Task not found")
            }
            // Derive WAIT / SLEEP / SIGNAL / EMIT spans from workflow_history
            // for every workflow-kind task in the tree.
            let workflowIDs = rows.filter { $0.kind == .workflow }.map { $0.id }
            let historySpans = try await ManagementQueries.executionHistorySpansForTrace(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                workflowTaskIDs: workflowIDs,
                logger: self.client.logger
            )
            return Self.buildTrace(rows: rows, historySpans: historySpans, rootCreatedAt: root.createdAt)
        }
    }

    // MARK: - Trace helpers

    private static func buildTrace(
        rows: [TraceSpanRow],
        historySpans: [ManagementQueries.ExecutionHistorySpanRow],
        rootCreatedAt: Date
    ) -> [TraceSpanResponse] {
        let now = Date()
        var childrenByParent: [UUID: [TraceSpanRow]] = [:]
        for row in rows {
            if let parentID = row.parentTaskID {
                childrenByParent[parentID, default: []].append(row)
            }
        }
        // Group execution history spans by parent workflow task ID.
        var historyByTask: [UUID: [ManagementQueries.ExecutionHistorySpanRow]] = [:]
        for s in historySpans {
            historyByTask[s.workflowTaskID, default: []].append(s)
        }
        let roots = rows.filter { $0.depth == 0 }
        return roots.map {
            buildSpan(
                $0,
                childrenByParent: childrenByParent,
                historyByTask: historyByTask,
                rootCreatedAt: rootCreatedAt,
                now: now
            )
        }
    }

    private static func buildSpan(
        _ row: TraceSpanRow,
        childrenByParent: [UUID: [TraceSpanRow]],
        historyByTask: [UUID: [ManagementQueries.ExecutionHistorySpanRow]],
        rootCreatedAt: Date,
        now: Date
    ) -> TraceSpanResponse {
        let startMs = max(0.0, row.createdAt.timeIntervalSince(rootCreatedAt) * 1000)
        let endDate = row.finishedAt ?? now
        let durationMs = max(0.0, endDate.timeIntervalSince(row.createdAt) * 1000)
        let queuedMs = row.startedAt.map { max(0.0, $0.timeIntervalSince(row.createdAt) * 1000) }

        let childRows = (childrenByParent[row.id] ?? []).sorted { $0.createdAt < $1.createdAt }
        var children: [TraceSpanResponse] = childRows.map {
            buildSpan(
                $0,
                childrenByParent: childrenByParent,
                historyByTask: historyByTask,
                rootCreatedAt: rootCreatedAt,
                now: now
            )
        }

        // Inject execution history spans (WAIT / SLEEP / SIGNAL / EMIT) for workflow nodes.
        if row.kind == .workflow {
            let histSpans = (historyByTask[row.id] ?? []).map {
                buildHistorySpan(
                    $0,
                    rootCreatedAt: rootCreatedAt,
                    workflowFinishedAt: row.finishedAt,
                    now: now
                )
            }
            // Merge task children and execution history spans in start-time order.
            children = (children + histSpans).sorted { $0.startMs < $1.startMs }
        }

        return TraceSpanResponse(
            id: row.id.uuidString,
            name: row.name,
            kind: WorkflowSpanKind(taskKind: row.kind),
            state: spanState(from: row.state),
            startMs: startMs,
            durationMs: durationMs,
            queuedMs: queuedMs,
            attempt: row.attempt,
            maxAttempts: row.maxAttempts,
            errorMessage: row.failureBuffer.map { String(buffer: $0) },
            workerID: row.workerID,
            createdAt: row.createdAt,
            startedAt: row.startedAt,
            completedAt: row.finishedAt,
            taskId: row.id,
            children: children,
            emissionId: nil,
            eventPayload: nil
        )
    }

    /// Builds a `TraceSpanResponse` from an execution history span.
    ///
    /// - The span `id` is deterministic: computed from the workflow task UUID and
    ///   the history sequence number so the UI key is stable across polling intervals.
    /// - `taskId` is set to the containing workflow's task ID so the trace inspector
    ///   "View task" button navigates to the workflow detail page.
    /// - `workflowFinishedAt`: when the parent workflow has completed but a WAIT/SLEEP
    ///   span has no recorded `endedAt` (e.g. EVENT_RECEIVED was not written for a
    ///   cached-handler-Task resume), caps the duration at the workflow's finish time
    ///   rather than the current wall-clock, avoiding multi-hour phantom durations.
    private static func buildHistorySpan(
        _ row: ManagementQueries.ExecutionHistorySpanRow,
        rootCreatedAt: Date,
        workflowFinishedAt: Date?,
        now: Date
    ) -> TraceSpanResponse {
        let startMs = max(0.0, row.startedAt.timeIntervalSince(rootCreatedAt) * 1000)
        // Use the recorded end, or fall back to the workflow's finish time (cap for
        // spans missing their END event), or finally the current wall-clock time.
        let endDate = row.endedAt ?? workflowFinishedAt ?? now
        let durationMs = max(0.0, endDate.timeIntervalSince(row.startedAt) * 1000)
        return TraceSpanResponse(
            id: "\(row.workflowTaskID.uuidString)-\(row.seqNum)",
            name: row.name,
            kind: row.spanKind,
            state: row.state,
            startMs: startMs,
            durationMs: durationMs,
            queuedMs: nil,
            attempt: 0,
            maxAttempts: nil,
            errorMessage: nil,
            workerID: nil,
            createdAt: row.startedAt,
            startedAt: nil,
            completedAt: row.endedAt,
            taskId: row.workflowTaskID,
            children: [],
            emissionId: row.emissionID,
            eventPayload: row.receivedPayload.map { String(buffer: $0) }
        )
    }

    private static func spanState(from state: TaskState) -> WorkflowSpanState {
        switch state {
        case .pending: return .pending
        case .running: return .running
        case .sleeping: return .waiting  // suspended on sleep/child/event
        case .waiting: return .waiting  // suspended on signal/event
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .continuedAsNew: return .completed  // terminal — workflow continued as new
        }
    }
}
