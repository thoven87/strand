package import Logging
import NIOCore
package import PostgresNIO

#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif

// MARK: - TraceSpanQueries

/// Write-through helpers for `strand.trace_spans`.
///
/// The engine calls these inside its existing transactions so the OLAP table
/// is always consistent with the transactional tables. Dashboard routes read
/// exclusively from `trace_spans` — no joins, no recursive CTEs.
///
/// ## Span ID conventions
/// - Task spans (WORKFLOW, ACTIVITY): `id = taskID.uuidString`
/// - History spans (SIGNAL, SLEEP, WAIT …): `id = "\(taskID.uuidString):\(seqNum)"`
/// - `parentID` for child tasks: `parentTaskID.uuidString`
/// - `parentID` for history spans: `taskID.uuidString` (the owning workflow)
///
/// ## root_task_id propagation
/// The COALESCE subquery in every INSERT resolves `root_task_id` from the
/// parent span row (which is always inserted before its children) and falls
/// back to `taskID` for root tasks (no parent). This keeps the entire tree
/// addressable with a single `WHERE root_task_id = $1` scan.
package enum TraceSpanQueries {

    // MARK: - Write helpers

    /// Insert or update a WORKFLOW / ACTIVITY task-level span.
    ///
    /// ON CONFLICT preserves existing values for fields the caller passes nil:
    /// worker_id, started_at, finished_at, error are coalesced so lifecycle
    /// updates (claim→complete) never accidentally clear earlier data.
    package static func upsertTaskSpan(
        on conn: PostgresConnection,
        id: String,
        namespaceID: String,
        taskID: UUID,
        parentID: String?,
        kind: WorkflowSpanKind,
        name: String,
        state: WorkflowSpanState,
        maxAttempts: Int? = nil,
        attempt: Int? = nil,
        workerID: String? = nil,
        queuedAt: Date? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        error: String? = nil,
        logger: Logger
    ) async throws {
        let effectiveQueuedAt = queuedAt ?? Date()
        let parentLookup = parentID ?? id
        try await conn.query(
            """
            INSERT INTO strand.trace_spans
                (id, namespace_id, root_task_id, task_id, parent_id,
                 kind, name, state, attempt, worker_id, max_attempts,
                 queued_at, started_at, finished_at, error)
            SELECT \(id), \(namespaceID),
                   COALESCE(
                       (SELECT root_task_id FROM strand.trace_spans WHERE id = \(parentLookup) LIMIT 1),
                       \(taskID)
                   ),
                   \(taskID), \(parentID),
                   \(kind), \(name), \(state),
                   COALESCE(\(attempt), 0),
                   \(workerID), \(maxAttempts),
                   \(effectiveQueuedAt), \(startedAt), \(finishedAt), \(error)
            ON CONFLICT (id) DO UPDATE
                SET state       = EXCLUDED.state,
                    attempt     = GREATEST(EXCLUDED.attempt, strand.trace_spans.attempt),
                    worker_id   = COALESCE(EXCLUDED.worker_id,   strand.trace_spans.worker_id),
                    started_at  = COALESCE(EXCLUDED.started_at,  strand.trace_spans.started_at),
                    finished_at = COALESCE(EXCLUDED.finished_at, strand.trace_spans.finished_at),
                    error       = COALESCE(EXCLUDED.error,       strand.trace_spans.error)
            """,
            logger: logger
        )
    }

    // MARK: - Batch root span insert

    /// Batch-insert root task spans in a single round-trip using `unnest`.
    ///
    /// Use this when enqueueing directly from `StrandClient` (no parent task).
    /// `root_task_id` is set to `task_id` directly — no correlated subquery needed.
    /// All items share the same `kind`, `name`, `state`, `maxAttempts`, and `queuedAt`.
    package static func insertRootSpansBatch(
        on conn: PostgresConnection,
        items: [(spanID: String, taskID: UUID)],
        namespaceID: String,
        kind: WorkflowSpanKind,
        name: String,
        state: WorkflowSpanState,
        maxAttempts: Int?,
        queuedAt: Date,
        logger: Logger
    ) async throws {
        guard !items.isEmpty else { return }
        let spanIDs = items.map { $0.spanID }
        let taskIDs = items.map { $0.taskID }
        try await conn.query(
            """
            INSERT INTO strand.trace_spans
                (id, namespace_id, root_task_id, task_id, parent_id,
                 kind, name, state, attempt, worker_id, max_attempts,
                 queued_at, started_at, finished_at, error)
            SELECT
                u.span_id, \(namespaceID), u.task_id, u.task_id, NULL,
                \(kind), \(name), \(state),
                0, NULL, \(maxAttempts),
                \(queuedAt), NULL, NULL, NULL
            FROM unnest(\(spanIDs), \(taskIDs)) AS u(span_id, task_id)
            ON CONFLICT (id) DO UPDATE
                SET state       = EXCLUDED.state,
                    attempt     = GREATEST(EXCLUDED.attempt, strand.trace_spans.attempt),
                    worker_id   = COALESCE(EXCLUDED.worker_id,   strand.trace_spans.worker_id),
                    started_at  = COALESCE(EXCLUDED.started_at,  strand.trace_spans.started_at),
                    finished_at = COALESCE(EXCLUDED.finished_at, strand.trace_spans.finished_at),
                    error       = COALESCE(EXCLUDED.error,       strand.trace_spans.error)
            """,
            logger: logger
        )
    }

    // MARK: - Batch child span insert

    /// Batch-insert child task spans in a single round-trip using a multi-row VALUES INSERT.
    ///
    /// Unlike `insertRootSpansBatch`, child spans share a parent and may carry per-item
    /// `kind`, `name`, `maxAttempts`, and `queuedAt`. `root_task_id` is resolved once from
    /// the parent span via a WITH CTE — no per-row correlated subquery needed.
    package static func insertChildSpansBatch(
        on conn: PostgresConnection,
        items: [(spanID: String, taskID: UUID, kind: WorkflowSpanKind, name: String, maxAttempts: Int?, queuedAt: Date)],
        namespaceID: String,
        parentSpanID: String,
        state: WorkflowSpanState,
        logger: Logger
    ) async throws {
        guard !items.isEmpty else { return }
        var interp = PostgresQuery.StringInterpolation(
            literalCapacity: 400 + items.count * 200,
            interpolationCount: items.count * 8 + 4
        )
        // Resolve root_task_id once from the parent span — shared by all child rows.
        interp.appendLiteral(
            "WITH parent_root AS (\n"
                + "    SELECT COALESCE(root_task_id, task_id) AS root_task_id\n"
                + "    FROM strand.trace_spans WHERE id = "
        )
        interp.appendInterpolation(parentSpanID)
        interp.appendLiteral(
            " LIMIT 1\n"
                + ")\n"
                + "INSERT INTO strand.trace_spans\n"
                + "    (id, namespace_id, root_task_id, task_id, parent_id,\n"
                + "     kind, name, state, attempt, worker_id, max_attempts,\n"
                + "     queued_at, started_at, finished_at, error)\n"
                + "VALUES\n"
        )
        for (i, item) in items.enumerated() {
            if i > 0 { interp.appendLiteral(",\n") }
            interp.appendLiteral("    (")
            interp.appendInterpolation(item.spanID)
            interp.appendLiteral(", ")
            interp.appendInterpolation(namespaceID)
            interp.appendLiteral(", (SELECT root_task_id FROM parent_root), ")
            interp.appendInterpolation(item.taskID)
            interp.appendLiteral(", ")
            interp.appendInterpolation(parentSpanID)
            interp.appendLiteral(", ")
            try interp.appendInterpolation(item.kind)
            interp.appendLiteral(", ")
            interp.appendInterpolation(item.name)
            interp.appendLiteral(", ")
            try interp.appendInterpolation(state)
            interp.appendLiteral(", 0, NULL, ")
            interp.appendInterpolation(item.maxAttempts)
            interp.appendLiteral(", ")
            interp.appendInterpolation(item.queuedAt)
            interp.appendLiteral(", NULL, NULL, NULL)")
        }
        interp.appendLiteral(
            "\nON CONFLICT (id) DO UPDATE\n"
                + "    SET state       = EXCLUDED.state,\n"
                + "        attempt     = GREATEST(EXCLUDED.attempt, strand.trace_spans.attempt),\n"
                + "        worker_id   = COALESCE(EXCLUDED.worker_id,   strand.trace_spans.worker_id),\n"
                + "        started_at  = COALESCE(EXCLUDED.started_at,  strand.trace_spans.started_at),\n"
                + "        finished_at = COALESCE(EXCLUDED.finished_at, strand.trace_spans.finished_at),\n"
                + "        error       = COALESCE(EXCLUDED.error,       strand.trace_spans.error)"
        )
        try await conn.query(PostgresQuery(stringInterpolation: interp), logger: logger)
    }

    // MARK: - History-event span derivation

    /// Derive SLEEP, WAIT, CONDITION, SIGNAL, UPDATE, and EMIT spans from
    /// `workflow_history` rows.
    ///
    /// History-event spans are derived from `workflow_history` at read time rather
    /// than written to a separate OLAP table — giving the trace waterfall the same
    /// durability guarantee as the history itself.
    ///
    /// Duration spans (SLEEP, WAIT, CONDITION) are paired by matching start/end events:
    ///   - TIMER:     by `seqNum` in `TimerStartedData`/`TimerFiredData` when present,
    ///                sequential stack otherwise (covers old rows pre-seqNum addition)
    ///   - WAIT:      by `eventName` from `NamedEventData` (unique per pending wait)
    ///   - CONDITION: sequential stack (at most one active at a time in Strand)
    ///
    /// Unclosed spans (workflow still running) are returned with `finishedAt = nil`
    /// and `state = "RUNNING"`.
    package static func deriveHistorySpans(
        from historyRows: [WorkflowStateQueries.HistoryEventRow],
        taskID: UUID,
        namespaceID: String,
        rootTaskID: UUID
    ) -> [SpanRow] {
        var spans: [SpanRow] = []
        let parentID = taskID.uuidString

        // Open timer spans keyed by activation seqNum (when available) or sequential stack.
        var openTimersBySeq: [Int: (historySeq: Int, createdAt: Date)] = [:]
        var openTimerStack: [(historySeq: Int, createdAt: Date)] = []

        // Open event-wait spans keyed by eventName.
        var openEventWaits: [String: (historySeq: Int, createdAt: Date)] = [:]

        // Open condition spans — sequential stack (one active at a time).
        var openConditions: [(historySeq: Int, createdAt: Date)] = []

        func makeID(_ histSeq: Int) -> String { "\(taskID.uuidString):h\(histSeq)" }

        func spanRow(
            historySeq: Int,
            kind: WorkflowSpanKind,
            name: String,
            state: WorkflowSpanState,
            startedAt: Date,
            finishedAt: Date?
        ) -> SpanRow {
            SpanRow(
                virtual: makeID(historySeq),
                rootTaskID: rootTaskID,
                taskID: taskID,
                parentID: parentID,
                kind: kind.rawValue,
                name: name,
                state: state.rawValue,
                queuedAt: startedAt,
                startedAt: startedAt,
                finishedAt: finishedAt
            )
        }

        for row in historyRows {
            switch row.eventType {

            case .timerStarted:
                let td = row.eventData.flatMap { try? JSON.decode(WorkflowStateQueries.TimerStartedData.self, from: $0) }
                let entry = (historySeq: row.seq, createdAt: row.createdAt)
                if let k = td?.seqNum {
                    openTimersBySeq[k] = entry
                } else {
                    openTimerStack.append(entry)
                }

            case .timerFired:
                let fd = row.eventData.flatMap { try? JSON.decode(WorkflowStateQueries.TimerFiredData.self, from: $0) }
                let open: (historySeq: Int, createdAt: Date)?
                if let k = fd?.seqNum, let e = openTimersBySeq.removeValue(forKey: k) {
                    open = e
                } else if !openTimerStack.isEmpty {
                    open = openTimerStack.removeFirst()
                } else {
                    open = nil
                }
                if let e = open {
                    spans.append(
                        spanRow(
                            historySeq: e.historySeq,
                            kind: .sleep,
                            name: "sleep",
                            state: .completed,
                            startedAt: e.createdAt,
                            finishedAt: row.createdAt
                        )
                    )
                }

            case .eventWaitStarted:
                let nd = row.eventData.flatMap { try? JSON.decode(WorkflowStateQueries.EventWaitStartedData.self, from: $0) }
                let eventName = nd?.eventName ?? ""
                openEventWaits[eventName] = (historySeq: row.seq, createdAt: row.createdAt)

            case .eventReceived:
                let nd = row.eventData.flatMap { try? JSON.decode(WorkflowStateQueries.NamedEventData.self, from: $0) }
                let eventName = nd?.eventName ?? ""
                if let e = openEventWaits.removeValue(forKey: eventName) {
                    spans.append(
                        spanRow(
                            historySeq: e.historySeq,
                            kind: .wait,
                            name: eventName,
                            state: .completed,
                            startedAt: e.createdAt,
                            finishedAt: row.createdAt
                        )
                    )
                }

            case .eventWaitTimedOut:
                let nd = row.eventData.flatMap { try? JSON.decode(WorkflowStateQueries.NamedEventData.self, from: $0) }
                let eventName = nd?.eventName ?? ""
                if let e = openEventWaits.removeValue(forKey: eventName) {
                    spans.append(
                        spanRow(
                            historySeq: e.historySeq,
                            kind: .wait,
                            name: eventName,
                            state: .timedOut,
                            startedAt: e.createdAt,
                            finishedAt: row.createdAt
                        )
                    )
                }

            case .conditionWaiting:
                openConditions.append((historySeq: row.seq, createdAt: row.createdAt))

            case .conditionMet:
                if !openConditions.isEmpty {
                    let e = openConditions.removeFirst()
                    spans.append(
                        spanRow(
                            historySeq: e.historySeq,
                            kind: .condition,
                            name: "condition",
                            state: .completed,
                            startedAt: e.createdAt,
                            finishedAt: row.createdAt
                        )
                    )
                }

            case .conditionTimedOut:
                if !openConditions.isEmpty {
                    let e = openConditions.removeFirst()
                    spans.append(
                        spanRow(
                            historySeq: e.historySeq,
                            kind: .condition,
                            name: "condition",
                            state: .timedOut,
                            startedAt: e.createdAt,
                            finishedAt: row.createdAt
                        )
                    )
                }

            case .signalReceived:
                let nd = row.eventData.flatMap { try? JSON.decode(WorkflowStateQueries.SignalReceivedData.self, from: $0) }
                spans.append(
                    spanRow(
                        historySeq: row.seq,
                        kind: .signal,
                        name: nd?.name ?? "signal",
                        state: .completed,
                        startedAt: row.createdAt,
                        finishedAt: row.createdAt
                    )
                )

            case .updateApplied:
                let nd = row.eventData.flatMap { try? JSON.decode(WorkflowStateQueries.SignalReceivedData.self, from: $0) }
                spans.append(
                    spanRow(
                        historySeq: row.seq,
                        kind: .update,
                        name: nd?.name ?? "update",
                        state: .completed,
                        startedAt: row.createdAt,
                        finishedAt: row.createdAt
                    )
                )

            case .eventEmitted:
                let nd = row.eventData.flatMap { try? JSON.decode(WorkflowStateQueries.NamedEventData.self, from: $0) }
                spans.append(
                    spanRow(
                        historySeq: row.seq,
                        kind: .emit,
                        name: nd?.eventName ?? "emit",
                        state: .completed,
                        startedAt: row.createdAt,
                        finishedAt: row.createdAt
                    )
                )

            default:
                break  // workflowStarted/Completed/Failed, activityScheduled/Started/Completed/Failed,
            // childWorkflow* — handled by task-level spans in trace_spans, not derived here
            }
        }

        // Unclosed spans — workflow is still running, suspended in this state
        for e in openTimersBySeq.values {
            spans.append(
                spanRow(
                    historySeq: e.historySeq,
                    kind: .sleep,
                    name: "sleep",
                    state: .running,
                    startedAt: e.createdAt,
                    finishedAt: nil
                )
            )
        }
        for e in openTimerStack {
            spans.append(
                spanRow(
                    historySeq: e.historySeq,
                    kind: .sleep,
                    name: "sleep",
                    state: .running,
                    startedAt: e.createdAt,
                    finishedAt: nil
                )
            )
        }
        for (name, e) in openEventWaits {
            spans.append(
                spanRow(
                    historySeq: e.historySeq,
                    kind: .wait,
                    name: name,
                    state: .running,
                    startedAt: e.createdAt,
                    finishedAt: nil
                )
            )
        }
        for e in openConditions {
            spans.append(
                spanRow(
                    historySeq: e.historySeq,
                    kind: .condition,
                    name: "condition",
                    state: .running,
                    startedAt: e.createdAt,
                    finishedAt: nil
                )
            )
        }

        return spans
    }

    // MARK: - Read helpers (dashboard routes)

    /// Decoded span row from `strand.trace_spans`.
    package struct SpanRow: Sendable {
        package let id: String
        package let rootTaskID: UUID
        package let taskID: UUID
        package let parentID: String?
        package let kind: String
        package let name: String
        package let state: String
        package let attempt: Int
        package let workerID: String?
        package let maxAttempts: Int?
        package let queuedAt: Date
        package let startedAt: Date?
        package let finishedAt: Date?
        package let error: String?

        /// Full memberwise init used by `decodeRow` to populate from a `strand.trace_spans` DB row.
        package init(
            id: String,
            rootTaskID: UUID,
            taskID: UUID,
            parentID: String?,
            kind: String,
            name: String,
            state: String,
            attempt: Int,
            workerID: String?,
            maxAttempts: Int?,
            queuedAt: Date,
            startedAt: Date?,
            finishedAt: Date?,
            error: String?
        ) {
            self.id = id
            self.rootTaskID = rootTaskID
            self.taskID = taskID
            self.parentID = parentID
            self.kind = kind
            self.name = name
            self.state = state
            self.attempt = attempt
            self.workerID = workerID
            self.maxAttempts = maxAttempts
            self.queuedAt = queuedAt
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.error = error
        }

        /// Creates a span row for history-event spans reconstructed at read time.
        package init(
            virtual id: String,
            rootTaskID: UUID,
            taskID: UUID,
            parentID: String?,
            kind: String,
            name: String,
            state: String,
            queuedAt: Date,
            startedAt: Date?,
            finishedAt: Date?
        ) {
            self.id = id
            self.rootTaskID = rootTaskID
            self.taskID = taskID
            self.parentID = parentID
            self.kind = kind
            self.name = name
            self.state = state
            self.attempt = 0
            self.workerID = nil
            self.maxAttempts = nil
            self.queuedAt = queuedAt
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.error = nil
        }

    }

    private static func decodeRow(_ row: PostgresRow) throws -> SpanRow {
        var col = row.makeIterator()
        return SpanRow(
            id: try col.next()!.decode(String.self, context: .default),
            rootTaskID: try col.next()!.decode(UUID.self, context: .default),
            taskID: try col.next()!.decode(UUID.self, context: .default),
            parentID: try col.next()!.decode(String?.self, context: .default),
            kind: try col.next()!.decode(String.self, context: .default),
            name: try col.next()!.decode(String.self, context: .default),
            state: try col.next()!.decode(String.self, context: .default),
            attempt: try col.next()!.decode(Int.self, context: .default),
            workerID: try col.next()!.decode(String?.self, context: .default),
            maxAttempts: try col.next()!.decode(Int?.self, context: .default),
            queuedAt: try col.next()!.decode(Date.self, context: .default),
            startedAt: try col.next()!.decode(Date?.self, context: .default),
            finishedAt: try col.next()!.decode(Date?.self, context: .default),
            error: try col.next()!.decode(String?.self, context: .default)
        )
    }

    /// Returns all spans for a trace tree ordered by `queued_at`.
    /// Replaces `traceTask` + `executionHistorySpansForTrace` — one index scan.
    package static func getTraceSpans(
        on postgres: PostgresClient,
        namespaceID: String,
        rootTaskID: UUID,
        logger: Logger
    ) async throws -> [SpanRow] {
        let stream = try await postgres.query(
            """
            SELECT id, root_task_id, task_id, parent_id,
                   kind, name, state, attempt, worker_id, max_attempts,
                   queued_at, started_at, finished_at, error
            FROM   strand.trace_spans
            WHERE  namespace_id = \(namespaceID)
              AND  root_task_id = \(rootTaskID)
            ORDER  BY queued_at ASC
            """,
            logger: logger
        )
        var rows: [SpanRow] = []
        for try await row in stream { rows.append(try decodeRow(row)) }
        return rows
    }

}
