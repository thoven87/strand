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

    private struct UpdateBody: Decodable {
        let name: String  // @WorkflowUpdate handler name, e.g. "setPriority"
        let payload: String?  // optional JSON string (nil for void-input updates)
        let timeout: Double?  // seconds to wait for result; default 10
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
        // Reads from strand.workflow_history — the granular event-by-event log that
        // feeds the ActivityTimeline (History tab). strand.trace_spans is used for
        // the Trace tab (waterfall) but cannot serve the History tab because each
        // span row collapses the full lifecycle into one record with a single
        // event_type field, losing the individual SCHEDULED/COMPLETED boundaries.
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

        // POST /api/:namespace/queues/:queue/tasks/:taskID/update
        // Dispatches a @WorkflowUpdate handler and long-polls for the result.
        // Body: { name: String, payload: String?, timeout: Double? }
        // Returns UpdateResultResponse — correlationID is always present so callers
        // can re-poll strand.workflow_updates independently on timeout.
        router.post("queues/:queue/tasks/:taskID/update") { req, ctx -> UpdateResultResponse in
            let taskID = try ctx.parameters.require("taskID", as: UUID.self)
            let body = try await req.decode(as: UpdateBody.self, context: ctx)
            let correlationID = UUID().uuidString
            let payloadBuf: ByteBuffer? = body.payload.map { ByteBuffer(string: $0) }

            try await self.client._sendUpdateSignal(
                updateName: body.name,
                correlationID: correlationID,
                payload: payloadBuf,
                toWorkflowTaskID: taskID,
                namespaceID: ctx.namespaceID
            )

            // Long-poll with exponential back-off (50 ms → 500 ms) until the
            // handler result appears in strand.workflow_updates or deadline hits.
            let deadline = Date(timeIntervalSinceNow: body.timeout ?? 10.0)
            var delayMs = 50.0
            while Date() < deadline {
                if let found = try await WorkflowStateQueries.findUpdateResult(
                    on: self.postgres,
                    namespaceID: ctx.namespaceID,
                    correlationID: correlationID,
                    logger: self.client.logger
                ) {
                    return UpdateResultResponse(
                        correlationID: correlationID,
                        result: found.result.map { String(buffer: $0) },
                        error: found.error,
                        timedOut: false
                    )
                }
                let remainingMs = deadline.timeIntervalSinceNow * 1_000
                guard remainingMs > 0 else { break }
                let sleepMs = min(delayMs, remainingMs)
                try await Task.sleep(nanoseconds: UInt64(sleepMs * 1_000_000))
                delayMs = min(delayMs * 2, 500)
            }

            return UpdateResultResponse(
                correlationID: correlationID,
                result: nil,
                error: nil,
                timedOut: true
            )
        }

        // GET /api/:namespace/queues/:queue/tasks/:taskID/version-markers
        // Returns the version markers for a workflow task (empty array for activities or tasks
        // that have never called context.version(changeID:)).
        router.get("queues/:queue/tasks/:taskID/version-markers") { _, ctx -> [VersionMarkerResponse] in
            let taskID = try ctx.parameters.require("taskID", as: UUID.self)
            let rows = try await WorkflowStateQueries.listVersionMarkers(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                taskID: taskID,
                logger: self.client.logger
            )
            return rows.map(VersionMarkerResponse.init(from:))
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

            // 1. Task-level spans (WORKFLOW, ACTIVITY) from trace_spans — always
            //    written atomically inside enqueueTask / completeRun / failRun CTEs.
            let spanRows = try await TraceSpanQueries.getTraceSpans(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                rootTaskID: taskID,
                logger: self.client.logger
            )
            guard !spanRows.isEmpty else {
                throw HTTPError(.notFound, message: "Task not found")
            }

            // 2. History-event spans (SLEEP, WAIT, CONDITION, SIGNAL, UPDATE, EMIT)
            //    derived from workflow_history — the authoritative record, always consistent.
            //    Load all workflow task histories in ONE query (batchListHistory uses
            //    WHERE task_id = ANY(…) on the existing PK index — one round-trip
            //    regardless of how many child workflows are in the trace tree).
            let workflowSpans = spanRows.filter { $0.kind == WorkflowSpanKind.workflow.rawValue }
            var derivedSpans: [TraceSpanQueries.SpanRow] = []
            if !workflowSpans.isEmpty {
                let historyByTask = try await WorkflowStateQueries.batchListHistory(
                    on: self.postgres,
                    taskIDs: workflowSpans.map(\.taskID),
                    logger: self.client.logger
                )
                for span in workflowSpans {
                    let derived = TraceSpanQueries.deriveHistorySpans(
                        from: historyByTask[span.taskID] ?? [],
                        taskID: span.taskID,
                        namespaceID: ctx.namespaceID,
                        rootTaskID: span.rootTaskID
                    )
                    derivedSpans.append(contentsOf: derived)
                }
            }

            return Self.buildTraceFromSpans(spanRows + derivedSpans)
        }
    }

    // MARK: - Trace helpers (OLAP path)

    /// Build a `[TraceSpanResponse]` tree from flat `strand.trace_spans` rows.
    /// One index scan replaces the old recursive CTE + history query path.
    private static func buildTraceFromSpans(
        _ spans: [TraceSpanQueries.SpanRow]
    ) -> [TraceSpanResponse] {
        guard
            let rootSpan = spans.first(where: { $0.parentID == nil || $0.parentID == $0.id })
                ?? spans.first
        else { return [] }
        let rootCreatedAt = rootSpan.queuedAt
        let now = Date()

        // Build parent → children map keyed by parentID string.
        var childrenByParentID: [String: [TraceSpanQueries.SpanRow]] = [:]
        for span in spans {
            if let pid = span.parentID, pid != span.id {
                childrenByParentID[pid, default: []].append(span)
            }
        }

        func buildSpanFromOLAP(_ span: TraceSpanQueries.SpanRow) -> TraceSpanResponse {
            // startMs: offset from the root's enqueue time (same baseline as old buildSpan).
            // durationMs: total wall-clock from enqueue to finish — mirrors the old
            //   `row.createdAt` baseline so the bar covers queue-wait + execution.
            // queuedMs: time from enqueue until a worker first claimed it.
            let startMs = max(0.0, span.queuedAt.timeIntervalSince(rootCreatedAt) * 1000)
            let endDate = span.finishedAt ?? now
            let durationMs = max(0.0, endDate.timeIntervalSince(span.queuedAt) * 1000)
            let queuedMs = span.startedAt.map { max(0.0, $0.timeIntervalSince(span.queuedAt) * 1000) }

            let kind: WorkflowSpanKind = WorkflowSpanKind(rawValue: span.kind) ?? .activity
            let state: WorkflowSpanState = WorkflowSpanState(rawValue: span.state) ?? .waiting

            let kids = (childrenByParentID[span.id] ?? [])
                .sorted { $0.queuedAt < $1.queuedAt }
                .map { buildSpanFromOLAP($0) }

            return TraceSpanResponse(
                id: span.id,
                name: span.name,
                kind: kind,
                state: state,
                startMs: startMs,
                durationMs: durationMs,
                queuedMs: queuedMs,
                attempt: span.attempt,
                maxAttempts: span.maxAttempts,
                errorMessage: span.error,
                workerID: span.workerID,
                createdAt: span.queuedAt,
                startedAt: span.startedAt,
                completedAt: span.finishedAt,
                taskId: span.taskID,
                children: kids,
                emissionId: nil,
                eventPayload: nil
            )
        }

        return [buildSpanFromOLAP(rootSpan)]
    }

}
