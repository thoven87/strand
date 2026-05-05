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

        // GET /api/:namespace/tasks?queue=&state=&limit=&cursor=
        // Global cross-queue task list. `queue` is optional; omit for all queues.
        router.get("tasks") { req, ctx -> CursorPageResponse<TaskSummaryResponse> in
            let qp = req.uri.queryParameters
            let queue = qp.get("queue")  // nil = all queues
            let state = qp.get("state")
            let name = qp.get("name")
            let kind = qp.get("kind").flatMap { TaskKind(rawValue: $0) }  // "WORKFLOW" | "ACTIVITY" | nil = all
            let limit = qp.get("limit").flatMap(Int.init) ?? 50
            let cursor = qp.get("cursor").flatMap { UUID(uuidString: $0) }
            let page = try await ManagementQueries.listTasks(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                queue: queue,
                state: state,
                name: name,
                kind: kind,
                cursor: cursor,
                limit: min(limit, 200),
                logger: self.client.logger
            )
            return CursorPageResponse(
                items: page.items.map(TaskSummaryResponse.init),
                nextCursor: page.nextCursor
            )
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
            let result = try await self.client.enqueue(
                taskName: body.name,
                params: body.params,
                options: EnqueueOptions(
                    queue: queue,
                    maxAttempts: body.maxAttempts,
                    idempotencyKey: body.idempotencyKey
                )
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
            try await self.client.cancelTask(id: taskID)
            return SimpleResponse(message: "cancelled", id: taskID.uuidString)
        }

        router.post("queues/:queue/tasks/:taskID/retry") { req, ctx -> EnqueueResultResponse in
            let taskId = try ctx.parameters.require("taskID", as: UUID.self)
            // Body is optional — callers that send no body get default RetryOptions.
            let options =
                (try? await req.decode(as: RetryOptions.self, context: ctx)) ?? RetryOptions()
            do {
                let result = try await self.client.requeueTask(id: taskId, options: options)
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
                toWorkflowTaskID: taskID
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
            return Self.buildTrace(rows: rows, rootCreatedAt: root.createdAt)
        }
    }

    // MARK: - Trace helpers

    private static func buildTrace(rows: [TraceSpanRow], rootCreatedAt: Date) -> [TraceSpanResponse] {
        let now = Date()
        var childrenByParent: [UUID: [TraceSpanRow]] = [:]
        for row in rows {
            if let parentID = row.parentTaskID {
                childrenByParent[parentID, default: []].append(row)
            }
        }
        let roots = rows.filter { $0.depth == 0 }
        return roots.map {
            buildSpan(
                $0,
                childrenByParent: childrenByParent,
                rootCreatedAt: rootCreatedAt,
                now: now
            )
        }
    }

    private static func buildSpan(
        _ row: TraceSpanRow,
        childrenByParent: [UUID: [TraceSpanRow]],
        rootCreatedAt: Date,
        now: Date
    ) -> TraceSpanResponse {
        let startMs = max(0.0, row.createdAt.timeIntervalSince(rootCreatedAt) * 1000)
        let endDate = row.finishedAt ?? now
        let durationMs = max(0.0, endDate.timeIntervalSince(row.createdAt) * 1000)
        let queuedMs = row.startedAt.map { max(0.0, $0.timeIntervalSince(row.createdAt) * 1000) }

        let childRows = (childrenByParent[row.id] ?? []).sorted { $0.createdAt < $1.createdAt }
        let children = childRows.map {
            buildSpan(
                $0,
                childrenByParent: childrenByParent,
                rootCreatedAt: rootCreatedAt,
                now: now
            )
        }

        return TraceSpanResponse(
            id: row.id,
            name: row.name,
            kind: row.kind,
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
            children: children
        )
    }

    private static func spanState(from state: TaskState) -> String {
        switch state {
        case .pending: return "PENDING"
        case .running: return "RUNNING"
        case .sleeping: return "WAITING"  // suspended waiting for child/sleep
        case .waiting: return "WAITING"  // suspended waiting for signal/event
        case .completed: return "COMPLETED"
        case .failed: return "FAILED"
        case .cancelled: return "CANCELLED"
        case .continuedAsNew: return "COMPLETED"  // terminal — workflow continued as new
        }
    }
}
