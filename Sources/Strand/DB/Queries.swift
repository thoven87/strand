import Logging
import NIOCore
import PostgresNIO

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// All SQL operations against Strand's own tables.
enum Queries {

    // MARK: - Schema

    /// Verifies the Strand schema by checking for `strand.tasks`.
    /// Throws ``StrandError/schemaMismatch`` if absent.
    static func verifySchema(on client: PostgresClient, logger: Logger) async throws {
        let stream = try await client.query(
            """
            SELECT EXISTS (
                SELECT FROM information_schema.tables
                WHERE table_schema = 'strand' AND table_name = 'tasks'
            )
            """,
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else {
            throw StrandError.schemaMismatch(installed: "unknown", required: "1")
        }
        var col = row.makeIterator()
        let exists = try col.next()!.decode(Bool.self, context: .default)
        guard exists else {
            throw StrandError.schemaMismatch(installed: "not installed", required: "1")
        }
    }

    // MARK: - Namespaces

    /// Ensures `namespaceID` exists in `strand.namespaces`.
    /// Idempotent — safe to call on every worker start.
    /// The `display_name` defaults to the namespace ID itself when auto-created.
    static func registerNamespace(
        on client: PostgresClient,
        namespaceID: String,
        logger: Logger
    ) async throws {
        try await client.query(
            """
            INSERT INTO strand.namespaces (id, display_name)
            VALUES (\(namespaceID), \(namespaceID))
            ON CONFLICT (id) DO NOTHING
            """,
            logger: logger
        )
    }

    // MARK: - Queues

    /// Connection-level implementation — the single source of truth for queue registration.
    static func createQueue(
        on conn: PostgresConnection,
        namespaceID: String,
        name: String,
        logger: Logger
    ) async throws {
        try await conn.query(
            "INSERT INTO strand.queues (namespace_id, name) VALUES (\(namespaceID), \(name)) ON CONFLICT (namespace_id, name) DO NOTHING",
            logger: logger
        )
    }

    /// Pool-level overload — acquires a connection then delegates to the connection overload.
    static func createQueue(
        on client: PostgresClient,
        namespaceID: String,
        name: String,
        logger: Logger
    ) async throws {
        try await client.withConnection { conn in
            try await createQueue(on: conn, namespaceID: namespaceID, name: name, logger: logger)
        }
    }

    static func dropQueue(
        on client: PostgresClient,
        namespaceID: String,
        name: String,
        logger: Logger
    ) async throws {
        try await client.query(
            "DELETE FROM strand.queues WHERE namespace_id = \(namespaceID) AND name = \(name)",
            logger: logger
        )
    }

    // NOTE: requires the is_paused / updated_at columns added to strand.queues
    static func pauseQueue(
        on client: PostgresClient,
        namespaceID: String,
        name: String,
        logger: Logger
    ) async throws {
        try await client.query(
            "UPDATE strand.queues SET is_paused = TRUE, updated_at = NOW() WHERE namespace_id = \(namespaceID) AND name = \(name)",
            logger: logger
        )
    }

    static func resumeQueue(
        on client: PostgresClient,
        namespaceID: String,
        name: String,
        logger: Logger
    ) async throws {
        try await client.query(
            "UPDATE strand.queues SET is_paused = FALSE, updated_at = NOW() WHERE namespace_id = \(namespaceID) AND name = \(name)",
            logger: logger
        )
    }

    static func listQueues(
        on client: PostgresClient,
        namespaceID: String,
        logger: Logger
    )
        async throws -> [String]
    {
        let stream = try await client.query(
            "SELECT name FROM strand.queues WHERE namespace_id = \(namespaceID) ORDER BY name",
            logger: logger
        )
        var names: [String] = []
        for try await row in stream {
            var col = row.makeIterator()
            names.append(try col.next()!.decode(String.self, context: .default))
        }
        return names
    }

    // MARK: - Enqueue

    /// Inserts a task and its first run atomically.
    /// When `idempotencyKey` is non-nil and a conflict occurs, returns the existing IDs.
    static func enqueueTask(
        on client: PostgresClient,
        namespaceID: String,
        queue: String,
        taskName: String,
        paramsBuffer: ByteBuffer,
        headersBuffer: ByteBuffer?,
        schedulingMetadata: SchedulingMetadata? = nil,
        retryStrategyBuffer: ByteBuffer?,
        maxAttempts: Int?,
        cancellationBuffer: ByteBuffer?,
        idempotencyKey: String?,
        priority: TaskPriority = .normal,
        scheduledAt: Date? = nil,
        timeoutSeconds: Int? = nil,
        heartbeatTimeoutSeconds: Int? = nil,
        scheduleToStartTimeoutSeconds: Int? = nil,
        deadlineAt: Date? = nil,
        fairnessKey: String? = nil,
        fairnessWeight: Double = 1.0,
        kind: TaskKind = .workflow,
        parentTaskID: UUID? = nil,
        firstTaskID: UUID? = nil,
        backfillID: UUID? = nil,
        parentClosePolicy: ParentClosePolicy? = nil,
        rateLimitKey: String? = nil,
        rateLimitIntervalMs: Int? = nil,
        logger: Logger
    ) async throws -> EnqueueRow {
        try await client.withTransaction(logger: logger) { conn in
            let taskID = UUID.v7()
            let runID = UUID.v7()
            // Auto-register the queue so strand.queues always reflects active queues.
            try await createQueue(on: conn, namespaceID: namespaceID, name: queue, logger: logger)
            try await conn.query(
                """
                INSERT INTO strand.tasks
                    (namespace_id, id, queue, name, params, headers, scheduling_metadata,
                     retry_strategy, max_attempts, timeout_seconds, heartbeat_timeout_seconds, schedule_to_start_timeout_seconds,
                     cancellation, idempotency_key, priority, fairness_key, fairness_weight,
                     state, kind, parent_task_id, first_task_id, deadline_at, backfill_id, parent_close_policy)
                VALUES (\(namespaceID), \(taskID), \(queue), \(taskName), \(paramsBuffer),
                        \(headersBuffer), \(schedulingMetadata),
                        \(retryStrategyBuffer), \(maxAttempts),
                        \(timeoutSeconds), \(heartbeatTimeoutSeconds), \(scheduleToStartTimeoutSeconds),
                        \(cancellationBuffer), \(idempotencyKey), \(priority),
                        \(fairnessKey), \(fairnessWeight), \(TaskState.pending),
                        \(kind), \(parentTaskID), \(firstTaskID), \(deadlineAt), \(backfillID), \(parentClosePolicy))
                ON CONFLICT (namespace_id, queue, idempotency_key) DO NOTHING
                """,
                logger: logger
            )
            let checkStream = try await conn.query(
                "SELECT id FROM strand.tasks WHERE namespace_id = \(namespaceID) AND queue = \(queue) AND id = \(taskID)",
                logger: logger
            )
            if try await checkStream.first(where: { _ in true }) != nil {
                try await conn.query(
                    """
                    INSERT INTO strand.runs (namespace_id, id, task_id, queue, attempt, state, available_at, priority,
                                           fairness_key, fairness_weight, kind)
                    VALUES (\(namespaceID), \(runID), \(taskID), \(queue), 1, \(TaskState.pending),
                            COALESCE(\(scheduledAt), NOW()), \(priority),
                            \(fairnessKey), \(fairnessWeight), \(kind))
                    """,
                    logger: logger
                )
                logger.debug(
                    "task enqueued",
                    metadata: [
                        "strand.task_id": .stringConvertible(taskID),
                        "strand.task_name": .string(taskName),
                        "strand.queue": .string(queue),
                        "strand.namespace": .string(namespaceID),
                        "strand.kind": .string(kind.rawValue),
                    ]
                )
                // Allocate a rate-limit slot when a RateLimit is set.
                if let intervalMs = rateLimitIntervalMs {
                    try await applyRateLimitSlots(
                        on: conn,
                        namespaceID: namespaceID,
                        queues: [queue],
                        slotKeys: [rateLimitKey ?? taskName],
                        runIDs: [runID],
                        intervalMses: [intervalMs],
                        logger: logger
                    )
                }
                // pg_notify is transactional — delivered only after this transaction commits.
                try await conn.notifyWorkers(namespace: namespaceID, queue: queue, logger: logger)
                // Write-through to trace_spans — atomic with the enqueue transaction.
                // If this fails the whole transaction rolls back and the caller retries.
                try await TraceSpanQueries.upsertTaskSpan(
                    on: conn,
                    id: taskID.uuidString,
                    namespaceID: namespaceID,
                    taskID: taskID,
                    parentID: parentTaskID?.uuidString,
                    kind: kind == .workflow ? .workflow : .activity,
                    name: taskName,
                    state: .waiting,
                    maxAttempts: maxAttempts,
                    queuedAt: scheduledAt ?? Date(),
                    logger: logger
                )
                return EnqueueRow(taskID: taskID, runID: runID, attempt: 1, created: true)
            } else {
                let existStream = try await conn.query(
                    """
                    SELECT t.id, r.id, r.attempt
                    FROM strand.tasks t
                    JOIN strand.runs r ON r.task_id = t.id
                    WHERE t.namespace_id = \(namespaceID) AND t.queue = \(queue) AND t.idempotency_key = \(idempotencyKey)
                    ORDER BY r.attempt DESC LIMIT 1
                    """,
                    logger: logger
                )
                guard let row = try await existStream.first(where: { _ in true }) else {
                    throw StrandError.database(
                        underlying: QueryError("idempotency lookup returned no rows")
                    )
                }
                var col = row.makeIterator()
                let eTaskID = try col.next()!.decode(UUID.self, context: .default)
                let eRunID = try col.next()!.decode(UUID.self, context: .default)
                let eAttempt = try col.next()!.decode(Int.self, context: .default)
                return EnqueueRow(taskID: eTaskID, runID: eRunID, attempt: eAttempt, created: false)
            }
        }
    }

    // MARK: - Rate-limit slot allocation

    /// Allocates rate-limit slots for one or more runs in a single round-trip.
    ///
    /// Used by both `enqueueTask` (N=1) and `enqueueChildTasksBatch` (N≥1);
    /// the same batch CTE handles both cases correctly.
    ///
    /// **Algorithm** (three CTE steps):
    ///
    /// 1. `ranked` — `UNNEST … WITH ORDINALITY` assigns each run its position
    ///    (`rank 0…cnt-1`) within its `(queue, slot_key)` group.
    ///
    /// 2. `advanced` — one upsert per distinct `(queue, slot_key)` advances the
    ///    cursor by `cnt × interval`.  The INSERT seeds new buckets at
    ///    `NOW() + cnt × I` (task 0 is immediately available).  The
    ///    `ON CONFLICT` arm applies `GREATEST(cursor, NOW())` before advancing,
    ///    resetting a stale cursor on an idle queue to `NOW()`.
    ///
    /// 3. Final `UPDATE` sets each run's `available_at` using closed-form offsets:
    ///    `cursor − (cnt − rank) × I = base + rank × I`
    ///    where `base = GREATEST(old_cursor, NOW())`.
    ///
    /// - Parameters:
    ///   - queues:       Queue name for each run (`text[]`).
    ///   - slotKeys:     Rate-limit bucket key for each run (`text[]`).
    ///   - runIDs:       `strand.runs.id` for each run (`uuid[]`).
    ///   - intervalMses: Slot interval in milliseconds for each run (`int8[]`).
    ///
    /// All four arrays must be the same length and non-empty; the caller is
    /// responsible for the guard (both call sites already check `!isEmpty`).
    static func applyRateLimitSlots(
        on conn: PostgresConnection,
        namespaceID: String,
        queues: [String],
        slotKeys: [String],
        runIDs: [UUID],
        intervalMses: [Int],
        logger: Logger
    ) async throws {
        try await conn.query(
            """
            WITH
            ranked AS (
                SELECT
                    queue, slot_key, run_id, interval_ms,
                    (ROW_NUMBER() OVER (PARTITION BY queue, slot_key ORDER BY ord)
                     - 1)::int AS rank,
                    COUNT(*) OVER (PARTITION BY queue, slot_key)::int AS cnt
                FROM UNNEST(\(queues), \(slotKeys), \(runIDs), \(intervalMses))
                     WITH ORDINALITY AS t(queue, slot_key, run_id, interval_ms, ord)
            ),
            advanced AS (
                INSERT INTO strand.rate_limit_slots
                    (namespace_id, queue, slot_key, next_slot_at)
                SELECT DISTINCT ON (queue, slot_key)
                    \(namespaceID), queue, slot_key,
                    NOW() + cnt * interval_ms * INTERVAL '1 millisecond'
                FROM ranked
                ORDER BY queue, slot_key
                ON CONFLICT (namespace_id, queue, slot_key) DO UPDATE
                    SET next_slot_at = GREATEST(
                            strand.rate_limit_slots.next_slot_at, NOW()
                        ) + (
                            SELECT r2.cnt * r2.interval_ms FROM ranked r2
                            WHERE  r2.queue    = excluded.queue
                              AND  r2.slot_key = excluded.slot_key
                            LIMIT  1
                        ) * INTERVAL '1 millisecond'
                RETURNING queue, slot_key, next_slot_at AS cursor
            )
            UPDATE strand.runs
            SET    available_at = GREATEST(
                       available_at,
                       a.cursor
                           - (r.cnt - r.rank) * r.interval_ms
                           * INTERVAL '1 millisecond'
                   )
            FROM   ranked r
            JOIN   advanced a
                   ON  a.queue    = r.queue
                   AND a.slot_key = r.slot_key
            WHERE  strand.runs.id = r.run_id
            """,
            logger: logger
        )
    }

    // MARK: - ChildEnqueueSpec

    /// One child task to enqueue as part of a batch spawned by a single workflow activation.
    ///
    /// Pre-generate `taskID` and `runID` (both UUIDv7) at the call site; they are used as
    /// the "new row" probe and discarded on an idempotency-key conflict.
    struct ChildEnqueueSpec: Sendable {
        let seqNum: Int
        let taskID: UUID  // pre-generated UUIDv7; used as new-row probe
        let runID: UUID  // pre-generated UUIDv7 for the first run row
        let queue: String
        let taskName: String
        let paramsBuffer: ByteBuffer
        let headersBuffer: ByteBuffer?
        let retryStrategyBuffer: ByteBuffer?
        let maxAttempts: Int?
        let idempotencyKey: String  // always set for workflow-spawned children
        let priority: TaskPriority
        let scheduledAt: Date?
        let timeoutSeconds: Int?
        let heartbeatTimeoutSeconds: Int?
        let scheduleToStartTimeoutSeconds: Int?
        let parentClosePolicy: ParentClosePolicy?
        let deadlineAt: Date?
        let fairnessKey: String?
        let fairnessWeight: Double
        let kind: TaskKind  // .activity or .workflow
        /// Slot interval in milliseconds for the rate-limit bucket.
        /// `nil` = no rate limiting; the run's `available_at` is unchanged.
        let rateLimitIntervalMs: Int?
        /// Rate-limit slot key.  `nil` falls back to `taskName` in the SQL.
        /// Set to `"ActivityName:entityKey"` for per-entity buckets.
        let rateLimitKey: String?
    }

    // MARK: - enqueueChildTasksBatch

    /// Batch-enqueue every child task (activity or child workflow) spawned by one workflow
    /// activation in a **single Postgres transaction** using true batch SQL — O(1)
    /// round-trips regardless of how many children are scheduled.
    ///
    /// The following all happen atomically inside one transaction:
    ///   1. Queue auto-registration (one per distinct child queue, idempotent)
    ///   2. One multi-row `VALUES` INSERT for all tasks (idempotent via `ON CONFLICT DO NOTHING`)
    ///   3. One multi-row `VALUES` INSERT for genuinely new runs
    ///   4. `pg_notify` per distinct new child queue (via `notifyWorkers`)
    ///   5. One `unnest`-based INSERT for all `event_waits` (idempotent)
    ///   6. `task_completions` count — if any child already done: delete its `event_wait`,
    ///      set parent to PENDING + notify; otherwise set parent to WAITING.
    ///
    /// - Returns: `(seqNum, taskID)` pairs in the same order as `children`.
    @discardableResult
    static func enqueueChildTasksBatch(
        on client: PostgresClient,
        namespaceID: String,
        parentTaskID: UUID,
        parentRunID: UUID,
        parentQueue: String,
        children: [ChildEnqueueSpec],
        logger: Logger
    ) async throws -> [(seqNum: Int, taskID: UUID)] {
        guard !children.isEmpty else { return [] }

        return try await client.withTransaction(logger: logger) { conn in
            // ── 1. Register all distinct child queues ────────────────────────────────
            var seenQueues: Set<String> = []
            for child in children {
                guard seenQueues.insert(child.queue).inserted else { continue }
                try await createQueue(on: conn, namespaceID: namespaceID, name: child.queue, logger: logger)
            }

            // ── 2. Insert all task rows — one multi-row VALUES statement ──────────────
            // Built via PostgresQuery.StringInterpolation so every field, including
            // nullable BYTEAs (headers, retry_strategy), is bound as an individual
            // typed parameter — one round-trip for all N tasks.
            var taskInterp = PostgresQuery.StringInterpolation(
                literalCapacity: 300 + children.count * 256,
                interpolationCount: children.count * 20
            )
            taskInterp.appendLiteral(
                "INSERT INTO strand.tasks "
                    + "(namespace_id, id, queue, name, params, headers, "
                    + "retry_strategy, max_attempts, timeout_seconds, heartbeat_timeout_seconds, "
                    + "schedule_to_start_timeout_seconds, parent_close_policy, idempotency_key, priority, "
                    + "fairness_key, fairness_weight, state, kind, parent_task_id, deadline_at) VALUES "
            )
            for (i, child) in children.enumerated() {
                if i > 0 { taskInterp.appendLiteral(", ") }
                taskInterp.appendLiteral("(")
                taskInterp.appendInterpolation(namespaceID)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(child.taskID)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(child.queue)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(child.taskName)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(child.paramsBuffer)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(child.headersBuffer)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(child.retryStrategyBuffer)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(child.maxAttempts)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(child.timeoutSeconds)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(child.heartbeatTimeoutSeconds)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(child.scheduleToStartTimeoutSeconds)
                taskInterp.appendLiteral(", ")
                try taskInterp.appendInterpolation(child.parentClosePolicy)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(child.idempotencyKey)
                taskInterp.appendLiteral(", ")
                try taskInterp.appendInterpolation(child.priority)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(child.fairnessKey)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(child.fairnessWeight)
                taskInterp.appendLiteral(", ")
                try taskInterp.appendInterpolation(TaskState.pending)
                taskInterp.appendLiteral(", ")
                try taskInterp.appendInterpolation(child.kind)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(parentTaskID)
                taskInterp.appendLiteral(", ")
                taskInterp.appendInterpolation(child.deadlineAt)
                taskInterp.appendLiteral(")")
            }
            taskInterp.appendLiteral(" ON CONFLICT (namespace_id, queue, idempotency_key) DO NOTHING")
            try await conn.query(PostgresQuery(stringInterpolation: taskInterp), logger: logger)

            // ── 3. Identify which tasks were genuinely inserted ──────────────────────
            // A generated taskID present in the DB means the INSERT succeeded (new row).
            // An absent generated taskID means the conflict clause fired (idempotency hit).
            let generatedIDs = children.map { $0.taskID }
            let newIDsStream = try await conn.query(
                "SELECT id FROM strand.tasks WHERE namespace_id = \(namespaceID) AND id = ANY(\(generatedIDs))",
                logger: logger
            )
            var newIDSet: Set<UUID> = []
            for try await row in newIDsStream {
                var col = row.makeIterator()
                newIDSet.insert(try col.next()!.decode(UUID.self, context: .default))
            }

            // ── 4. Insert runs for genuinely new tasks — one multi-row VALUES statement ──
            let newChildren = children.filter { newIDSet.contains($0.taskID) }
            if !newChildren.isEmpty {
                var runInterp = PostgresQuery.StringInterpolation(
                    literalCapacity: 220 + newChildren.count * 160,
                    interpolationCount: newChildren.count * 11
                )
                runInterp.appendLiteral(
                    "INSERT INTO strand.runs "
                        + "(namespace_id, id, task_id, queue, attempt, state, "
                        + "available_at, priority, fairness_key, fairness_weight, kind) VALUES "
                )
                for (i, child) in newChildren.enumerated() {
                    if i > 0 { runInterp.appendLiteral(", ") }
                    runInterp.appendLiteral("(")
                    runInterp.appendInterpolation(namespaceID)
                    runInterp.appendLiteral(", ")
                    runInterp.appendInterpolation(child.runID)
                    runInterp.appendLiteral(", ")
                    runInterp.appendInterpolation(child.taskID)
                    runInterp.appendLiteral(", ")
                    runInterp.appendInterpolation(child.queue)
                    runInterp.appendLiteral(", 1, ")
                    try runInterp.appendInterpolation(TaskState.pending)
                    runInterp.appendLiteral(", COALESCE(")
                    runInterp.appendInterpolation(child.scheduledAt)
                    runInterp.appendLiteral(", NOW()), ")
                    try runInterp.appendInterpolation(child.priority)
                    runInterp.appendLiteral(", ")
                    runInterp.appendInterpolation(child.fairnessKey)
                    runInterp.appendLiteral(", ")
                    runInterp.appendInterpolation(child.fairnessWeight)
                    runInterp.appendLiteral(", ")
                    try runInterp.appendInterpolation(child.kind)
                    runInterp.appendLiteral(")")
                }
                try await conn.query(PostgresQuery(stringInterpolation: runInterp), logger: logger)
                // Write-through to trace_spans — atomic with the batch enqueue transaction.
                // If any write fails the whole transaction rolls back and the caller retries.
                for child in newChildren {
                    try await TraceSpanQueries.upsertTaskSpan(
                        on: conn,
                        id: child.taskID.uuidString,
                        namespaceID: namespaceID,
                        taskID: child.taskID,
                        parentID: parentTaskID.uuidString,
                        kind: child.kind == .workflow ? .workflow : .activity,
                        name: child.taskName,
                        state: .waiting,
                        maxAttempts: child.maxAttempts,
                        queuedAt: child.scheduledAt ?? Date(),
                        logger: logger
                    )
                }
            }

            // ── 4b. Rate-limit slot allocation ──────────────────────────────────────────
            // Collect rate-limited new children and forward to applyRateLimitSlots.
            // Idempotency-hit tasks are excluded — their run already has the correct
            // available_at from the original enqueue.  See applyRateLimitSlots for
            // the full algorithm.
            var rlQueues: [String] = []
            var rlSlotKeys: [String] = []
            var rlRunIDs: [UUID] = []
            var rlIntervalMses: [Int] = []
            for child in newChildren where child.rateLimitIntervalMs != nil {
                rlQueues.append(child.queue)
                rlSlotKeys.append(child.rateLimitKey ?? child.taskName)
                rlRunIDs.append(child.runID)
                rlIntervalMses.append(child.rateLimitIntervalMs!)
            }
            if !rlRunIDs.isEmpty {
                try await applyRateLimitSlots(
                    on: conn,
                    namespaceID: namespaceID,
                    queues: rlQueues,
                    slotKeys: rlSlotKeys,
                    runIDs: rlRunIDs,
                    intervalMses: rlIntervalMses,
                    logger: logger
                )
            }

            // ── 5. Notify workers — one pg_notify per distinct new child queue ────────
            var notifiedQueues: Set<String> = []
            for child in newChildren {
                guard notifiedQueues.insert(child.queue).inserted else { continue }
                try await conn.notifyWorkers(namespace: namespaceID, queue: child.queue, logger: logger)
            }

            // ── 6. Resolve final taskID for every child ───────────────────────────────
            // New tasks: keep the pre-generated taskID.
            // Idempotency hits: query the DB by idempotency_key to find the original taskID.
            var idKeyToTaskID: [String: UUID] = [:]
            for child in children where newIDSet.contains(child.taskID) {
                idKeyToTaskID[child.idempotencyKey] = child.taskID
            }
            let hitSpecs = children.filter { !newIDSet.contains($0.taskID) }
            if !hitSpecs.isEmpty {
                let hitKeys = hitSpecs.map { $0.idempotencyKey }
                let hitStream = try await conn.query(
                    """
                    SELECT id, idempotency_key FROM strand.tasks
                    WHERE namespace_id    = \(namespaceID)
                      AND idempotency_key = ANY(\(hitKeys))
                    """,
                    logger: logger
                )
                for try await row in hitStream {
                    var col = row.makeIterator()
                    let existID = try col.next()!.decode(UUID.self, context: .default)
                    let existKey = try col.next()!.decode(String.self, context: .default)
                    idKeyToTaskID[existKey] = existID
                }
            }
            let result: [(seqNum: Int, taskID: UUID)] = try children.map { child in
                guard let taskID = idKeyToTaskID[child.idempotencyKey] else {
                    throw StrandError.database(
                        underlying: QueryError(
                            "enqueueChildTasksBatch: no taskID for idempotency_key \(child.idempotencyKey)"
                        )
                    )
                }
                return (seqNum: child.seqNum, taskID: taskID)
            }

            // ── 7. Register event_waits for all children — one unnest statement ─────────
            // unnest zips the two arrays row-by-row: one INSERT for all N children.
            // [Int] encodes as int8[]; Postgres silently casts to the int4 column.
            //
            // namespace_id MUST be included: omitting it gives DEFAULT='default',
            // which breaks cross-namespace isolation and causes emitTaskCompletionSignal
            // to mis-match or leave orphaned rows when the parent namespace differs.
            let ewSeqNums = result.map { $0.seqNum }
            let ewChildIDs = result.map { $0.taskID }
            try await conn.query(
                """
                INSERT INTO strand.event_waits
                    (namespace_id, task_id, run_id, queue, seq_num, child_task_id, timeout_at)
                SELECT \(namespaceID), \(parentTaskID), \(parentRunID), \(parentQueue),
                       u.seq_num, u.child_task_id, NULL
                FROM unnest(\(ewSeqNums), \(ewChildIDs)) AS u(seq_num, child_task_id)
                ON CONFLICT (run_id, seq_num) DO UPDATE
                    SET child_task_id  = EXCLUDED.child_task_id,
                        namespace_id   = EXCLUDED.namespace_id,
                        timeout_at     = NULL
                """,
                logger: logger
            )

            // ── 8. Atomic completion-check + parent-run state transition ─────────────
            //
            // State decision:
            //   • ALL batch children completed (completedCount == result.count)
            //     → PENDING: delete orphaned event_waits, wake immediately.
            //   • SOME children still running (completedCount < result.count)
            //     → WAITING: park until emitTaskCompletionSignal fires for each one.
            //
            // The condition is completedCount == result.count (not > 0) because
            // a partial completion must keep the run WAITING. Transitioning to
            // PENDING while sibling children are still running would cause
            // RUNNING → PENDING → RUNNING loops on every subsequent completion.
            //
            // Guard: AND state != SLEEPING
            //   Prevents overwriting a SLEEPING state that .awaitEvent (waitForEvent /
            //   sleep) already set in the same applyScheduleCommands loop. Without this
            //   guard, replay activations that emit both .scheduleActivity (fast-pathed
            //   completed activities) AND .awaitEvent would have the named-event sleep
            //   immediately overwritten by PENDING.
            let childTaskIDs = result.map { $0.taskID }
            let completedStream = try await conn.query(
                "SELECT COUNT(*) FROM strand.task_completions WHERE task_id = ANY(\(childTaskIDs))",
                logger: logger
            )
            var completedCount = 0
            for try await row in completedStream {
                var col = row.makeIterator()
                completedCount = try col.next()!.decode(Int.self, context: .default)
            }

            let allDone = completedCount == result.count
            let newState = allDone ? TaskState.pending : TaskState.waiting
            try await conn.query(
                """
                WITH
                del_orphans AS (
                    -- Remove event_waits for children that already have completions.
                    -- Runs in same snapshot as the state UPDATE, so no lost-delete race.
                    DELETE FROM strand.event_waits ew
                    USING strand.task_completions tc
                    WHERE ew.run_id        = \(parentRunID)
                      AND ew.child_task_id = tc.task_id
                      AND tc.task_id       = ANY(\(childTaskIDs))
                ),
                r AS (
                    UPDATE strand.runs
                    SET state        = \(newState),
                        available_at = CASE WHEN \(allDone) THEN NOW() ELSE available_at END,
                        lease_expires_at = NULL
                    WHERE id    = \(parentRunID)
                      AND state != \(TaskState.sleeping)  -- do not overwrite named-event / timer sleep
                    RETURNING id
                )
                UPDATE strand.tasks SET state = \(newState)
                FROM r WHERE strand.tasks.id = \(parentTaskID)
                """,
                logger: logger
            )
            if allDone {
                try await conn.notifyWorkers(namespace: namespaceID, queue: parentQueue, logger: logger)
            }

            return result
        }
    }

    // MARK: - Worker

    /// Claims up to `qty` runs from `queue` atomically using `FOR UPDATE SKIP LOCKED`.
    static func claimTasks(
        on client: PostgresClient,
        namespaceID: String,
        queue: String,
        workerID: String,
        claimTimeoutSeconds: Int,
        qty: Int,
        logger: Logger
    ) async throws -> [ClaimedTask] {
        let stream = try await client.query(
            """
            WITH candidate AS (
                -- Fairness-key dispatch:
                --   • Tasks WITH a fairness_key: only the highest-priority/oldest run per key
                --     is eligible (FIFO within each group).
                --   • Tasks WITHOUT a fairness_key: always eligible.
                -- Both sets then compete via weighted-random ordering so no key starves others.
                --
                -- The correlated NOT EXISTS is an index seek via strand_runs_fairness_idx
                -- on (namespace_id, queue, fairness_key, available_at, priority, id)
                -- WHERE state IN ('PENDING','SLEEPING') AND fairness_key IS NOT NULL.
                -- Cost is O(1) per candidate row regardless of queue depth.
                SELECT r.id, t.timeout_seconds FROM strand.runs r
                JOIN strand.tasks t ON t.id = r.task_id
                WHERE r.queue = \(queue)
                  AND r.namespace_id = \(namespaceID)
                  AND r.state IN (\(TaskState.pending), \(TaskState.sleeping))
                  AND r.available_at <= NOW()
                  AND (t.deadline_at IS NULL OR t.deadline_at > NOW())
                  AND  t.state NOT IN (\(TaskState.cancelled), \(TaskState.failed), \(TaskState.completed))
                  AND (
                      r.fairness_key IS NULL
                      OR NOT EXISTS (
                          SELECT 1 FROM strand.runs r2
                          WHERE r2.queue        = r.queue
                            AND r2.namespace_id = r.namespace_id
                            AND r2.fairness_key = r.fairness_key
                            AND r2.state IN (\(TaskState.pending), \(TaskState.sleeping))
                            AND r2.available_at <= NOW()
                            AND (
                                r2.priority < r.priority
                                OR (r2.priority = r.priority AND r2.available_at < r.available_at)
                                OR (r2.priority = r.priority AND r2.available_at = r.available_at
                                    AND r2.id < r.id)
                            )
                      )
                  )
                -- Sticky affinity: within the same priority band, prefer runs this
                -- worker last processed. The cached handler Task is more likely to
                -- be in memory on that worker, avoiding a fresh-path replay.
                -- Fairness-weighted random is the primary ordering within a priority
                -- band: dividing by fairness_weight means higher-weight keys are
                -- statistically first, providing the starve-free frontier guarantee.
                -- Sticky affinity (prefer runs last processed by this worker) is a
                -- secondary tiebreaker that must come AFTER fairness-weighted random
                -- so it cannot override the fairness guarantee. In practice random()
                -- produces unique values so sticky rarely fires here; its main benefit
                -- is reducing cache misses when the candidate pool has no fairness keys.
                ORDER BY r.priority ASC,
                         (random() / GREATEST(r.fairness_weight, 0.001)) ASC,
                         CASE WHEN r.worker_id = \(workerID) THEN 0 ELSE 1 END ASC,
                         r.available_at,
                         r.id
                LIMIT \(qty)
                FOR UPDATE SKIP LOCKED
            ),
            claimed AS (
                UPDATE strand.runs r
                SET state            = \(TaskState.running),
                    worker_id        = \(workerID),
                    sdk_version      = \(StrandVersion.current),
                    lease_expires_at = NOW() + COALESCE(NULLIF(c.timeout_seconds, 0), \(claimTimeoutSeconds)) * INTERVAL '1 second',
                    started_at       = COALESCE(r.started_at, NOW())
                FROM candidate c WHERE r.id = c.id
                RETURNING r.id, r.task_id, r.attempt, r.version, r.wake_event, r.event_payload, r.available_at, r.heartbeat_details
            ),
            task_upd AS (
                UPDATE strand.tasks t
                SET state        = \(TaskState.running),
                    attempt      = GREATEST(t.attempt, c.attempt),
                    first_run_at = COALESCE(t.first_run_at, NOW())
                FROM claimed c WHERE t.id = c.task_id
            ),
            trace_upd AS (
                -- Inline RUNNING state into the claim CTE so trace_spans stays
                -- consistent with strand.runs atomically — eliminates the old
                -- post-claim try? loop that could leave span state stale when
                -- the worker processed multiple tasks concurrently.
                -- trace_spans.id is TEXT; c.task_id is UUID — ::text cast required.
                UPDATE strand.trace_spans
                SET state      = \(WorkflowSpanState.running),
                    started_at = COALESCE(started_at, NOW()),
                    worker_id  = \(workerID),
                    attempt    = c.attempt
                FROM claimed c
                WHERE strand.trace_spans.id = c.task_id::text
            )
            SELECT c.id, c.task_id, c.attempt, c.version,
                   t.name, t.params, t.retry_strategy, t.max_attempts, t.headers,
                   c.wake_event, c.event_payload,
                   t.parent_task_id, t.kind, t.timeout_seconds, t.heartbeat_timeout_seconds,
                   t.scheduling_metadata, c.available_at, c.heartbeat_details, t.deadline_at,
                   t.first_task_id, t.cancel_requested
            FROM claimed c JOIN strand.tasks t ON t.id = c.task_id
            ORDER BY c.id
            """,
            logger: logger
        )
        var tasks: [ClaimedTask] = []
        for try await row in stream { tasks.append(try ClaimedTask(row: row)) }
        return tasks
    }

    /// Marks a run as completed with optimistic concurrency (version CAS).
    ///
    /// The `version` parameter must match the value read at claim time
    /// (`ClaimedTask.version`). If it doesn't — another worker already
    /// completed this run — the function returns silently (idempotent).
    static func completeRun(
        on client: PostgresClient,
        namespaceID: String,
        runID: UUID,
        version: Int,
        resultBuffer: ByteBuffer?,
        logger: Logger
    ) async throws {
        // Flag written inside the closure to signal the cancelled case to the
        // caller.  We must NOT throw InternalError.cancelled from within the
        // withTransaction closure because PostgresNIO wraps every closure throw
        // in PostgresTransactionError — masking the original error so the
        // `catch InternalError.cancelled` in runTask never matches, causing a
        // spurious failRun.  Returning normally from the closure (empty commit)
        // and throwing after the transaction avoids the wrapping entirely.
        var taskWasCancelled = false
        try await client.withTransaction(logger: logger) { conn in
            // Fetch task state and ID — FOR UPDATE prevents concurrent completions.
            // Partition pruning: strand.runs is partitioned monthly by created_at.
            // Adding a 2-month window lets Postgres skip all older partitions while
            // still safely covering runs that started just before a month boundary.
            let stateStream = try await conn.query(
                """
                SELECT t.state, t.id
                FROM   strand.runs r
                JOIN   strand.tasks t ON t.id = r.task_id
                WHERE  r.id            = \(runID)
                  AND  r.namespace_id  = \(namespaceID)
                  AND  r.created_at   >= DATE_TRUNC('month', NOW()) - INTERVAL '1 month'
                FOR UPDATE
                """,
                logger: logger
            )
            guard let row = try await stateStream.first(where: { _ in true }) else { return }
            var col = row.makeIterator()
            let taskState = try col.next()!.decode(TaskState.self, context: .default)
            let taskID = try col.next()!.decode(UUID.self, context: .default)
            // Task was externally cancelled while this run was still executing.
            // Set the flag and return — the transaction commits as a no-op (only a
            // SELECT FOR UPDATE was issued), releasing the lock cleanly.
            if taskState == .cancelled {
                taskWasCancelled = true
                return
            }

            // CAS on version — if another worker already wrote a completion, bail out.
            // The tasks update is gated on the runs CAS via the CTE: if r is empty
            // (CAS failed), the WHERE subquery returns NULL and no task row is touched.
            let casStream = try await conn.query(
                """
                WITH r AS (
                    UPDATE strand.runs
                    SET state = \(TaskState.completed), finished_at = NOW(), version = version + 1
                    WHERE id = \(runID) AND state = \(TaskState.running) AND version = \(version)
                      AND namespace_id = \(namespaceID)
                    RETURNING task_id
                )
                UPDATE strand.tasks
                SET state = \(TaskState.completed), completed_at = NOW(), result = \(resultBuffer)
                WHERE id = (SELECT task_id FROM r)
                RETURNING id
                """,
                logger: logger
            )
            guard try await casStream.first(where: { _ in true }) != nil else { return }
            try await conn.query(
                "DELETE FROM strand.event_waits WHERE run_id = \(runID)",
                logger: logger
            )
            // Write-through to trace_spans — atomic with the completion transaction.
            // If this fails the whole transaction rolls back; the run stays RUNNING,
            // lease expires, sweep re-queues, activation retries with consistent data.
            try await conn.query(
                """
                UPDATE strand.trace_spans
                SET state       = \(WorkflowSpanState.completed),
                    finished_at = NOW()
                WHERE id = \(taskID.uuidString)
                """,
                logger: logger
            )
            try await emitTaskCompletionSignal(
                conn: conn,
                namespaceID: namespaceID,
                taskID: taskID,
                state: .completed,
                resultBuffer: resultBuffer,
                logger: logger
            )
        }
        // Throw outside the transaction so InternalError.cancelled reaches
        // runTask's `catch InternalError.cancelled` directly — unwrapped.
        if taskWasCancelled { throw InternalError.cancelled }
    }

    private struct _NRFlag: Decodable { let non_retryable: Bool? }
    private struct _ErrorType: Decodable { let name: String? }
    private struct _FailureMessage: Decodable { let message: String? }

    /// Recursively processes all non-terminal descendants of `parentTaskID` when the parent
    /// workflow permanently fails.
    ///
    /// Three policies are enforced:
    /// - **TERMINATE / nil**: full cancel — task CANCELLED, all non-RUNNING runs CANCELLED.
    ///   RUNNING runs are left to expire via `sweepExpiredLeases` (transparent infrastructure event).
    /// - **REQUEST_CANCEL (WORKFLOW kind)**: cooperative cancel — insert a
    ///   `Signals.cancelRequested` signal and wake SLEEPING/WAITING runs to PENDING so the
    ///   handler receives the signal at the next activation. The task is NOT marked CANCELLED;
    ///   it completes naturally when the handler exits.
    /// - **REQUEST_CANCEL (ACTIVITY kind)**: treated as ABANDON — activities have no signal
    ///   handler so there is nothing to deliver.
    /// - **ABANDON**: left entirely alone.
    ///
    /// Recursion stops at ABANDON and REQUEST_CANCEL nodes — their subtrees are unaffected.
    ///
    /// - Returns: Queue names of runs woken by REQUEST_CANCEL processing; callers should
    ///   call `notifyWorkers` for each distinct queue so workers pick up the PENDING runs promptly.
    @discardableResult
    private static func cancelDescendants(
        on conn: PostgresConnection,
        namespaceID: String,
        parentTaskID: UUID,
        logger: Logger
    ) async throws -> [String] {
        let stream = try await conn.query(
            """
            WITH RECURSIVE descendants AS (
                SELECT id, parent_close_policy, kind FROM strand.tasks
                WHERE parent_task_id = \(parentTaskID)
                  AND namespace_id   = \(namespaceID)
                UNION ALL
                SELECT t.id, t.parent_close_policy, t.kind FROM strand.tasks t
                JOIN descendants d ON t.parent_task_id = d.id
                WHERE t.namespace_id = \(namespaceID)
                  AND (d.parent_close_policy IS NULL OR d.parent_close_policy = \(ParentClosePolicy.terminate))
            ),
            to_terminate AS (
                SELECT id FROM descendants
                WHERE parent_close_policy IS NULL OR parent_close_policy = \(ParentClosePolicy.terminate)
            ),
            to_request_cancel AS (
                SELECT id, kind FROM descendants WHERE parent_close_policy = \(ParentClosePolicy.requestCancel)
            ),
            -- TERMINATE: cancel tasks + all non-RUNNING runs. RUNNING runs expire via leaseExpiryLoop.
            task_cancel AS (
                UPDATE strand.tasks
                SET state = \(TaskState.cancelled), cancelled_at = NOW()
                WHERE id IN (SELECT id FROM to_terminate)
                  AND state NOT IN (
                      \(TaskState.completed), \(TaskState.failed), \(TaskState.cancelled)
                  )
            ),
            run_terminate AS (
                UPDATE strand.runs
                SET state = \(TaskState.cancelled), finished_at = NOW()
                WHERE task_id IN (SELECT id FROM to_terminate)
                  AND namespace_id = \(namespaceID)
                  AND state NOT IN (
                      \(TaskState.running),
                      \(TaskState.completed), \(TaskState.failed), \(TaskState.cancelled)
                  )
            ),
            -- REQUEST_CANCEL (WORKFLOW only): wake suspended runs so the handler can see the signal.
            -- Activities have no signal handler; treating REQUEST_CANCEL on activities as ABANDON.
            request_cancel_wake AS (
                UPDATE strand.runs
                SET state            = \(TaskState.pending),
                    available_at     = NOW(),
                    lease_expires_at = NULL,
                    wake_event       = NULL,
                    event_payload    = NULL,
                    worker_id        = NULL
                WHERE task_id IN (SELECT id FROM to_request_cancel WHERE kind = \(TaskKind.workflow))
                  AND namespace_id = \(namespaceID)
                  AND state IN (\(TaskState.sleeping), \(TaskState.waiting))
                RETURNING queue
            ),
            request_cancel_task_wake AS (
                UPDATE strand.tasks
                SET state = \(TaskState.pending)
                WHERE id IN (SELECT id FROM to_request_cancel WHERE kind = \(TaskKind.workflow))
                  AND namespace_id = \(namespaceID)
                  AND state IN (\(TaskState.sleeping), \(TaskState.waiting))
            ),
            -- REQUEST_CANCEL: set cancel_requested = TRUE so the next activation delivers
            -- Swift CancellationError natively to the handler via handlerTask.cancel().
            cancel_requested_set AS (
                UPDATE strand.tasks
                SET cancel_requested = TRUE
                WHERE id IN (SELECT id FROM to_request_cancel WHERE kind = \(TaskKind.workflow))
            )
            SELECT queue FROM request_cancel_wake
            """,
            logger: logger
        )
        var queues: [String] = []
        for try await row in stream {
            var col = row.makeIterator()
            queues.append(try col.next()!.decode(String.self, context: .default))
        }
        return queues
    }

    /// Transitions a RUNNING run to FAILED, then either schedules the next
    /// retry attempt (if `maxAttempts` and `deadline_at` allow) or permanently
    /// marks the task FAILED and signals the parent workflow.
    ///
    /// Steps executed inside a single transaction:
    /// 1. Read the task’s retry policy, attempt counter, and hard deadline.
    /// 2. CAS the run to FAILED — `AND version = $version` ensures only the
    ///    worker that claimed this exact execution can fail it. A stale
    ///    `runTask` whose run was swept back to PENDING and re-claimed by
    ///    another worker finds 0 rows here and returns silently.
    /// 3. Delete any dangling `event_waits` rows for this run.
    /// 4. Update the OTel trace span to FAILED.
    /// 5. If retries remain and no hard deadline has passed: compute the
    ///    back-off delay, create a new PENDING run for attempt N+1, and
    ///    transition the task row to PENDING so it becomes claimable.
    /// 6. Otherwise: mark the task permanently FAILED and call
    ///    `emitTaskCompletionSignal` to wake the parent workflow.
    static func failRun(
        on client: PostgresClient,
        namespaceID: String,
        runID: UUID,
        version: Int,
        reasonBuffer: ByteBuffer,
        logger: Logger
    ) async throws {
        try await client.withTransaction(logger: logger) { conn in
            let infoStream = try await conn.query(
                """
                SELECT t.id, t.attempt, t.max_attempts, t.retry_strategy, t.deadline_at, t.kind
                FROM   strand.runs r
                JOIN   strand.tasks t ON t.id = r.task_id
                WHERE  r.id           = \(runID)
                  AND  r.created_at  >= DATE_TRUNC('month', NOW()) - INTERVAL '1 month'
                FOR UPDATE OF t
                """,
                logger: logger
            )
            guard let row = try await infoStream.first(where: { _ in true }) else { return }
            var col = row.makeIterator()
            let taskID = try col.next()!.decode(UUID.self, context: .default)
            let attempt = try col.next()!.decode(Int.self, context: .default)
            let maxAttempts = try col.next()!.decode(Int?.self, context: .default)
            let retryStrategyBuf = try col.next()!.decode(ByteBuffer?.self, context: .default)
            let deadlineAt = try col.next()!.decode(Date?.self, context: .default)
            let taskKind = try col.next()!.decode(TaskKind.self, context: .default)
            // Step 2 — CAS: only transitions the run that this worker claimed.
            let failStream = try await conn.query(
                "UPDATE strand.runs SET state = \(TaskState.failed), failure_reason = \(reasonBuffer), finished_at = NOW() WHERE id = \(runID) AND state = \(TaskState.running) AND version = \(version) RETURNING id",
                logger: logger
            )
            guard try await failStream.first(where: { _ in true }) != nil else { return }
            try await conn.query(
                "DELETE FROM strand.event_waits WHERE run_id = \(runID)",
                logger: logger
            )
            // Write-through to trace_spans — atomic with the failure transaction.
            // If a retry is scheduled, claimTasks will later overwrite this with state='RUNNING'.
            let _spanError: String? = (try? JSON.decode(_FailureMessage.self, from: reasonBuffer))?.message
            try await conn.query(
                """
                UPDATE strand.trace_spans
                SET state       = \(WorkflowSpanState.failed),
                    finished_at = NOW(),
                    error       = \(_spanError)
                WHERE id        = \(taskID.uuidString)
                """,
                logger: logger
            )

            // ── Check 0: non_retryable flag (from NonRetryableError protocol) ──────────
            // Activities whose Failure type conforms to NonRetryableError encode
            // `non_retryable: true` in the failure payload. Skip retry immediately.
            if (try? JSON.decode(_NRFlag.self, from: reasonBuffer))?.non_retryable == true {
                try await conn.query(
                    "UPDATE strand.tasks SET state = \(TaskState.failed), attempt = \(attempt) WHERE id = \(taskID) AND namespace_id = \(namespaceID)",
                    logger: logger
                )
                try await emitTaskCompletionSignal(
                    conn: conn,
                    namespaceID: namespaceID,
                    taskID: taskID,
                    state: .failed,
                    resultBuffer: nil,
                    logger: logger
                )
                if taskKind == .workflow {
                    try await cancelDescendants(on: conn, namespaceID: namespaceID, parentTaskID: taskID, logger: logger)
                }
                return
            }

            // ── Check 1: nonRetryableErrorTypes ──────────────────────────────────────
            // Decode just the error type name from the failure payload.
            let errorTypeName = (try? JSON.decode(_ErrorType.self, from: reasonBuffer)).flatMap(
                \.name
            )

            if let strategy = retryStrategyBuf.flatMap({
                try? JSON.decode(RetryStrategy.self, from: $0)
            }),
                let errorType = errorTypeName
            {
                let nret = strategy.nonRetryableErrorTypes
                if !nret.isEmpty && nret.contains(errorType) {
                    // Non-retryable error type — fail permanently, no retry
                    try await conn.query(
                        "UPDATE strand.tasks SET state = \(TaskState.failed), attempt = \(attempt) WHERE id = \(taskID) AND namespace_id = \(namespaceID)",
                        logger: logger
                    )
                    try await emitTaskCompletionSignal(
                        conn: conn,
                        namespaceID: namespaceID,
                        taskID: taskID,
                        state: .failed,
                        resultBuffer: nil,
                        logger: logger
                    )
                    if taskKind == .workflow {
                        try await cancelDescendants(on: conn, namespaceID: namespaceID, parentTaskID: taskID, logger: logger)
                    }
                    return
                }
            }

            // ── Check 2: maxDuration deadline ────────────────────────────────────────
            if let deadline = deadlineAt, Date.now >= deadline {
                // Total wall-clock budget exhausted — fail permanently
                try await conn.query(
                    "UPDATE strand.tasks SET state = \(TaskState.failed), attempt = \(attempt) WHERE id = \(taskID) AND namespace_id = \(namespaceID)",
                    logger: logger
                )
                try await emitTaskCompletionSignal(
                    conn: conn,
                    namespaceID: namespaceID,
                    taskID: taskID,
                    state: .failed,
                    resultBuffer: nil,
                    logger: logger
                )
                if taskKind == .workflow {
                    try await cancelDescendants(on: conn, namespaceID: namespaceID, parentTaskID: taskID, logger: logger)
                }
                return
            }

            let nextAttempt = attempt + 1
            guard maxAttempts == nil || nextAttempt <= maxAttempts! else {
                try await conn.query(
                    "UPDATE strand.tasks SET state = \(TaskState.failed), attempt = \(attempt) WHERE id = \(taskID)",
                    logger: logger
                )
                // Wake any awaitTaskResult callers.
                try await emitTaskCompletionSignal(
                    conn: conn,
                    namespaceID: namespaceID,
                    taskID: taskID,
                    state: .failed,
                    resultBuffer: nil,
                    logger: logger
                )
                if taskKind == .workflow {
                    try await cancelDescendants(on: conn, namespaceID: namespaceID, parentTaskID: taskID, logger: logger)
                }
                return
            }
            let delay = retryDelay(strategy: retryStrategyBuf, attempt: attempt)
            let wakeAt = Date.now.addingTimeInterval(delay)
            let newState: TaskState = delay > 0 ? .sleeping : .pending
            let newRunID = UUID.v7()
            try await conn.query(
                """
                INSERT INTO strand.runs (namespace_id, id, task_id, queue, attempt, state, available_at, priority,
                                       fairness_key, fairness_weight, heartbeat_details)
                SELECT namespace_id, \(newRunID), task_id, queue, \(nextAttempt), \(newState), \(wakeAt),
                       priority, fairness_key, fairness_weight, heartbeat_details
                FROM strand.runs WHERE id = \(runID)
                """,
                logger: logger
            )
            try await conn.query(
                """
                UPDATE strand.tasks
                SET state            = \(newState),
                    attempt          = \(nextAttempt),
                    cancel_requested = FALSE
                WHERE id = \(taskID)
                """,
                logger: logger
            )
            // Only notify when the retry is immediately runnable (no sleep delay).
            if newState == .pending {
                let qStream = try await conn.query(
                    "SELECT queue FROM strand.runs WHERE id = \(runID)",
                    logger: logger
                )
                if let qRow = try await qStream.first(where: { _ in true }) {
                    var qCol = qRow.makeIterator()
                    let q = try qCol.next()!.decode(String.self, context: .default)
                    try await conn.notifyWorkers(namespace: namespaceID, queue: q, logger: logger)
                }
            }
        }
    }

    /// Suspends a run until `wakeAt` (used by `sleepFor` / `sleepUntil`).
    static func scheduleRun(
        on client: PostgresClient,
        namespaceID: String,
        runID: UUID,
        version: Int,
        taskID: UUID,
        wakeAt: Date,
        logger: Logger
    ) async throws {
        try await client.query(
            """
            WITH r AS (
                UPDATE strand.runs
                SET state = \(TaskState.sleeping), available_at = \(wakeAt),
                    lease_expires_at = NULL
                WHERE id        = \(runID)
                  AND state     = \(TaskState.running)
                  AND version   = \(version)
                  AND namespace_id = \(namespaceID)
                  AND created_at >= DATE_TRUNC('month', NOW()) - INTERVAL '1 month'
                RETURNING id
            )
            UPDATE strand.tasks SET state = \(TaskState.sleeping)
            WHERE id = \(taskID) AND namespace_id = \(namespaceID)
              AND EXISTS (SELECT 1 FROM r)
            """,
            logger: logger
        )
    }

    /// Extends the claim lease. Throws ``InternalError/cancelled`` if the run
    /// is no longer in 'running' state (task was cancelled or failed externally).
    /// Connection-level implementation — the single source of truth for claim extension.
    /// `heartbeatDetails` is stored when non-nil; when nil the existing value is preserved
    /// (`COALESCE(NULL, heartbeat_details) = heartbeat_details`).
    @discardableResult
    static func extendClaim(
        on conn: PostgresConnection,
        namespaceID: String,
        runID: UUID,
        extendBySeconds: Int,
        heartbeatDetails: ByteBuffer? = nil,
        logger: Logger
    ) async throws -> Bool {
        let stream = try await conn.query(
            """
            UPDATE strand.runs r
            SET lease_expires_at  = NOW() + \(extendBySeconds) * INTERVAL '1 second',
                heartbeat_details = COALESCE(\(heartbeatDetails), heartbeat_details)
            FROM strand.tasks t
            WHERE r.id           = \(runID)
              AND r.state        = \(TaskState.running)
              AND r.namespace_id = \(namespaceID)
              AND t.id           = r.task_id
            RETURNING r.id,
                CASE WHEN t.state = \(TaskState.cancelled) THEN TRUE ELSE FALSE END AS task_cancelled
            """,
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else {
            throw InternalError.cancelled
        }
        var col = row.makeIterator()
        _ = try col.next()!.decode(UUID.self, context: .default)  // r.id
        let taskCancelled = try col.next()!.decode(Bool.self, context: .default)
        return taskCancelled
    }

    /// Pool-level overload — acquires a connection then delegates to the connection overload.
    @discardableResult
    static func extendClaim(
        on client: PostgresClient,
        namespaceID: String,
        runID: UUID,
        extendBySeconds: Int,
        heartbeatDetails: ByteBuffer? = nil,
        logger: Logger
    ) async throws -> Bool {
        try await client.withConnection { conn in
            try await extendClaim(
                on: conn,
                namespaceID: namespaceID,
                runID: runID,
                extendBySeconds: extendBySeconds,
                heartbeatDetails: heartbeatDetails,
                logger: logger
            )
        }
    }

    /// Cancels a task and all its pending/sleeping runs.
    ///
    /// ## `waitCancellationCompleted` deferred-cancel path
    ///
    /// When the task has child activities with `parent_close_policy = .waitCancellationCompleted`
    /// that are still RUNNING, the cancellation is deferred so those activities can finish
    /// naturally before the parent closes.
    ///
    /// Instead of immediately marking the task CANCELLED the engine:
    ///   1. Sets `cancel_requested = TRUE` (the same cooperative-cancel flag used by
    ///      `requestCancel` parent policies for child workflows).
    ///   2. Cancels only PENDING runs (prevents new activations).
    ///   3. Preserves RUNNING / WAITING / SLEEPING runs so the parent can complete
    ///      any in-flight work and be re-activated when activity completions arrive.
    ///
    /// On the next activation the worker sees `claimed.cancelRequested = true`,
    /// sets `activation.isCancelRequested = true`, and calls `handlerTask.cancel()`.
    /// The handler processes any completed activity results (existing continuations are
    /// NOT automatically cancelled), then `CancellationError` fires at the next slow-path
    /// suspension point.  `applyScheduleCommands` catches it and transitions the task to
    /// CANCELLED exactly as if the cancellation had been immediate.
    static func cancelTask(
        on client: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        logger: Logger
    ) async throws {
        try await client.withTransaction(logger: logger) { conn in

            // ── Step 0: Detect in-flight waitCancellationCompleted activities ───────
            // If any child activity has a RUNNING run and
            // parent_close_policy = .waitCancellationCompleted, defer the cancellation
            // so the parent can wait for those activities to finish cooperatively.
            let deferredStream = try await conn.query(
                """
                SELECT EXISTS (
                    SELECT 1
                    FROM   strand.tasks c
                    JOIN   strand.runs  r ON r.task_id = c.id
                                        AND r.state   = \(TaskState.running)
                    WHERE  c.parent_task_id    = \(taskID)
                      AND  c.namespace_id      = \(namespaceID)
                      AND  c.parent_close_policy = \(ParentClosePolicy.waitCancellationCompleted)
                      AND  c.state NOT IN (
                               \(TaskState.completed), \(TaskState.failed), \(TaskState.cancelled)
                           )
                ) AS deferred
                """,
                logger: logger
            )
            let deferred: Bool
            if let row = try await deferredStream.first(where: { _ in true }) {
                var col = row.makeIterator()
                deferred = try col.next()!.decode(Bool.self, context: .default)
            } else {
                deferred = false
            }

            if deferred {
                // ── Deferred-cancel path ──────────────────────────────────────────────
                // Signal cooperative cancellation without immediately terminating the task.
                // The handler will see isCancelRequested = true on the next activation and
                // throw CancellationError after processing any in-flight activity results.
                try await conn.query(
                    """
                    UPDATE strand.tasks
                    SET cancel_requested = TRUE
                    WHERE id = \(taskID)
                      AND namespace_id = \(namespaceID)
                      AND state NOT IN (
                              \(TaskState.completed), \(TaskState.failed), \(TaskState.cancelled)
                          )
                    """,
                    logger: logger
                )
                // Cancel PENDING runs (no new activations), but preserve RUNNING /
                // WAITING / SLEEPING runs so the parent can be re-activated when
                // the waitCancellationCompleted activities finish.
                try await conn.query(
                    """
                    UPDATE strand.runs
                    SET state = \(TaskState.cancelled)
                    WHERE task_id      = \(taskID)
                      AND namespace_id = \(namespaceID)
                      AND state        = \(TaskState.pending)
                    """,
                    logger: logger
                )
                // Cascade to descendants as normal (waitCancellationCompleted activities
                // are in `to_terminate` which already preserves their RUNNING runs).
                let cancelQueues = try await cancelDescendants(
                    on: conn,
                    namespaceID: namespaceID,
                    parentTaskID: taskID,
                    logger: logger
                )
                for queue in Set(cancelQueues) {
                    try await conn.notifyWorkers(namespace: namespaceID, queue: queue, logger: logger)
                }
                // No emitTaskCompletionSignal here — the parent is still alive.
                // applyScheduleCommands will emit it when the workflow finally cancels.
            } else {
                // ── Immediate-cancel path (standard) ─────────────────────────────

                // ── Step 1: Cancel the task row itself ────────────────────────────────────
                try await conn.query(
                    """
                    UPDATE strand.tasks
                    SET state = \(TaskState.cancelled), cancelled_at = NOW()
                    WHERE id = \(taskID)
                      AND namespace_id = \(namespaceID)
                      AND state NOT IN (\(TaskState.completed), \(TaskState.failed), \(TaskState.cancelled))
                    """,
                    logger: logger
                )

                // ── Step 2: Cancel/interrupt this task's runs ────────────────────────
                try await conn.query(
                    """
                    UPDATE strand.runs
                    SET state = \(TaskState.cancelled)
                    WHERE task_id = \(taskID)
                      AND namespace_id = \(namespaceID)
                      AND state IN (
                              \(TaskState.pending), \(TaskState.sleeping),
                              \(TaskState.waiting), \(TaskState.running)
                          )
                    """,
                    logger: logger
                )

                // ── Step 3 + 4: Policy-aware cascade to descendants ─────────────────
                let cancelQueues = try await cancelDescendants(
                    on: conn,
                    namespaceID: namespaceID,
                    parentTaskID: taskID,
                    logger: logger
                )
                for queue in Set(cancelQueues) {
                    try await conn.notifyWorkers(namespace: namespaceID, queue: queue, logger: logger)
                }

                // ── Step 5: Wake any awaitTaskResult callers ────────────────────────
                try await emitTaskCompletionSignal(
                    conn: conn,
                    namespaceID: namespaceID,
                    taskID: taskID,
                    state: .cancelled,
                    resultBuffer: nil,
                    logger: logger
                )
            }
        }

        logger.debug(
            "task cancelled",
            metadata: ["strand.task_id": .stringConvertible(taskID)]
        )
    }

    // MARK: - Batch cancel

    /// Cancels a batch of tasks in one transaction.
    ///
    /// Compared to calling `cancelTask` N times (N×5 queries), this runs:
    ///   - 1 task UPDATE (bulk)
    ///   - 1 descendant task UPDATE (recursive CTE, bulk)
    ///   - 1 run UPDATE (bulk)
    ///   - 1 descendant run UPDATE (bulk)
    ///   - N calls to emitTaskCompletionSignal (one per task — needed so any
    ///     `awaitTaskResult` callers are unblocked)
    ///
    /// Returns the number of tasks that were actually cancelled (i.e. were not
    /// already terminal before this call).
    @discardableResult
    static func cancelTasksBatch(
        on client: PostgresClient,
        namespaceID: String,
        taskIDs: [UUID],
        logger: Logger
    ) async throws -> Int {
        guard !taskIDs.isEmpty else { return 0 }

        let count: Int = try await client.withTransaction(logger: logger) { conn in
            // ── Step 1: Cancel root task rows, collect IDs actually updated ────────────────
            var cancelledIDs: [UUID] = []
            let cancelStream = try await conn.query(
                """
                UPDATE strand.tasks
                SET state = \(TaskState.cancelled), cancelled_at = NOW()
                WHERE id = ANY(\(taskIDs))
                  AND namespace_id = \(namespaceID)
                  AND state NOT IN (\(TaskState.completed), \(TaskState.failed), \(TaskState.cancelled))
                RETURNING id
                """,
                logger: logger
            )
            for try await row in cancelStream {
                var col = row.makeIterator()
                cancelledIDs.append(try col.next()!.decode(UUID.self, context: .default))
            }

            guard !cancelledIDs.isEmpty else { return 0 }

            // ── Step 2: Cancel/interrupt run rows for root tasks ────────────────────────
            try await conn.query(
                """
                UPDATE strand.runs
                SET state = \(TaskState.cancelled)
                WHERE task_id = ANY(\(cancelledIDs))
                  AND namespace_id = \(namespaceID)
                  AND state IN (\(TaskState.pending), \(TaskState.sleeping),
                                \(TaskState.waiting), \(TaskState.running))
                """,
                logger: logger
            )

            // ── Steps 3 + 4: Policy-aware cascade to descendants (bulk) ──────────────
            // Mirror the single-task logic from cancelDescendants but for N parent IDs
            // at once. REQUEST_CANCEL workflow descendants get a cooperative cancel signal;
            // TERMINATE descendants are hard-cancelled; ABANDON descendants are untouched.
            let wakeStream = try await conn.query(
                """
                WITH RECURSIVE descendants AS (
                    SELECT id, parent_close_policy, kind FROM strand.tasks
                        WHERE parent_task_id = ANY(\(cancelledIDs))
                          AND namespace_id   = \(namespaceID)
                        UNION ALL
                        SELECT t.id, t.parent_close_policy, t.kind FROM strand.tasks t
                        JOIN descendants d ON t.parent_task_id = d.id
                        WHERE t.namespace_id = \(namespaceID)
                          AND (d.parent_close_policy IS NULL OR d.parent_close_policy = \(ParentClosePolicy.terminate))
                    ),
                    to_terminate AS (
                        SELECT id FROM descendants
                        WHERE parent_close_policy IS NULL OR parent_close_policy = \(ParentClosePolicy.terminate)
                    ),
                    to_request_cancel AS (
                        SELECT id, kind FROM descendants WHERE parent_close_policy = \(ParentClosePolicy.requestCancel)
                    ),
                task_cancel AS (
                    UPDATE strand.tasks
                    SET state = \(TaskState.cancelled), cancelled_at = NOW()
                    WHERE id IN (SELECT id FROM to_terminate)
                      AND state NOT IN (
                          \(TaskState.completed), \(TaskState.failed), \(TaskState.cancelled)
                      )
                ),
                run_terminate AS (
                    UPDATE strand.runs
                    SET state = \(TaskState.cancelled)
                    WHERE task_id IN (SELECT id FROM to_terminate)
                      AND namespace_id = \(namespaceID)
                      AND state IN (
                          \(TaskState.pending), \(TaskState.sleeping),
                          \(TaskState.waiting), \(TaskState.running)
                      )
                ),
                request_cancel_wake AS (
                    UPDATE strand.runs
                    SET state            = \(TaskState.pending),
                        available_at     = NOW(),
                        lease_expires_at = NULL,
                        wake_event       = NULL,
                        event_payload    = NULL,
                        worker_id        = NULL
                    WHERE task_id IN (SELECT id FROM to_request_cancel WHERE kind = \(TaskKind.workflow))
                      AND namespace_id = \(namespaceID)
                      AND state IN (\(TaskState.sleeping), \(TaskState.waiting))
                    RETURNING queue
                ),
                request_cancel_task_wake AS (
                    UPDATE strand.tasks
                    SET state = \(TaskState.pending)
                    WHERE id IN (SELECT id FROM to_request_cancel WHERE kind = \(TaskKind.workflow))
                      AND namespace_id = \(namespaceID)
                      AND state IN (\(TaskState.sleeping), \(TaskState.waiting))
                ),
                cancel_requested_set AS (
                    UPDATE strand.tasks
                    SET cancel_requested = TRUE
                    WHERE id IN (SELECT id FROM to_request_cancel WHERE kind = \(TaskKind.workflow))
                )
                SELECT queue FROM request_cancel_wake
                """,
                logger: logger
            )
            var cancelQueues: [String] = []
            for try await row in wakeStream {
                var col = row.makeIterator()
                cancelQueues.append(try col.next()!.decode(String.self, context: .default))
            }
            for queue in Set(cancelQueues) {
                try await conn.notifyWorkers(namespace: namespaceID, queue: queue, logger: logger)
            }

            // ── Step 5: Wake any awaitTaskResult callers (one signal per root task) ─
            for taskID in cancelledIDs {
                try await emitTaskCompletionSignal(
                    conn: conn,
                    namespaceID: namespaceID,
                    taskID: taskID,
                    state: .cancelled,
                    resultBuffer: nil,
                    logger: logger
                )
            }

            return cancelledIDs.count
        }

        logger.debug(
            "tasks cancelled (batch)",
            metadata: ["strand.cancelled_count": .stringConvertible(count)]
        )
        return count
    }

    /// Returns the current state and result of a task.
    static func fetchTaskResult(
        on client: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        logger: Logger
    ) async throws -> TaskResultRow? {
        let stream = try await client.query(
            """
            SELECT t.id, t.state, t.result, r.failure_reason
            FROM strand.tasks t
            LEFT JOIN strand.runs r ON r.id = (
                SELECT id FROM strand.runs WHERE task_id = t.id ORDER BY attempt DESC LIMIT 1
            )
            WHERE t.id = \(taskID) AND t.namespace_id = \(namespaceID)
            """,
            logger: logger
        )
        guard let row = try await stream.first(where: { _ in true }) else { return nil }
        return try TaskResultRow(row: row)
    }

    // MARK: - Checkpoints

    /// Loads all checkpoint rows for a workflow task regardless of which run wrote them.
    ///
    /// The `run_id` filter was removed: `strand.checkpoints` has PRIMARY KEY
    /// `(task_id, seq_num)`, so there is at most one row per seq_num per task.
    /// The `setCheckpointState` upsert already uses an attempt-number guard so
    /// only the highest-attempt run's value survives for each seq_num. Loading
    /// all checkpoints for the task (not just the current run) means crash recovery
    /// correctly reconstructs deterministic values (uuid(), random()) even when
    /// `failRun` has created a new run_id for a workflow retry.
    static func getCheckpointStates(
        on client: PostgresClient,
        taskID: UUID,
        logger: Logger
    ) async throws -> [CheckpointRow] {
        let stream = try await client.query(
            """
            SELECT seq_num, name, state
            FROM strand.checkpoints
            WHERE task_id = \(taskID)
            ORDER BY seq_num
            """,
            logger: logger
        )
        var rows: [CheckpointRow] = []
        for try await row in stream { rows.append(try CheckpointRow(row: row)) }
        return rows
    }

    /// Upserts a step checkpoint keyed by `(task_id, seq_num)`; optionally extends the claim lease.
    ///
    /// `name` is an optional debug label stored as metadata — it is never used as a key.
    /// On conflict, the attempt guard prevents a stale retry from overwriting a newer run's data.
    /// Connection overload — SQL lives here.
    static func setCheckpointState(
        on conn: PostgresConnection,
        namespaceID: String,
        taskID: UUID,
        seqNum: Int,
        name: String?,
        stateBuffer: ByteBuffer,
        runID: UUID,
        logger: Logger
    ) async throws {
        try await conn.query(
            """
            INSERT INTO strand.checkpoints (namespace_id, task_id, seq_num, name, state, run_id)
            VALUES (\(namespaceID), \(taskID), \(seqNum), \(name), \(stateBuffer), \(runID))
            ON CONFLICT (task_id, seq_num) DO UPDATE
                SET state      = EXCLUDED.state,
                    run_id     = EXCLUDED.run_id,
                    name       = COALESCE(EXCLUDED.name, strand.checkpoints.name),
                    created_at = NOW()
                WHERE (SELECT attempt FROM strand.runs WHERE id = strand.checkpoints.run_id)
                   <= (SELECT attempt FROM strand.runs WHERE id = EXCLUDED.run_id)
            """,
            logger: logger
        )
    }

    /// Client overload — delegates to the connection overload; also extends the claim lease when requested.
    static func setCheckpointState(
        on client: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        seqNum: Int,
        name: String?,
        stateBuffer: ByteBuffer,
        runID: UUID,
        extendClaimBySeconds: Int?,
        logger: Logger
    ) async throws {
        try await client.withConnection { conn in
            try await setCheckpointState(
                on: conn,
                namespaceID: namespaceID,
                taskID: taskID,
                seqNum: seqNum,
                name: name,
                stateBuffer: stateBuffer,
                runID: runID,
                logger: logger
            )
        }
        if let secs = extendClaimBySeconds {
            try await extendClaim(
                on: client,
                namespaceID: namespaceID,
                runID: runID,
                extendBySeconds: secs,
                logger: logger
            )
        }
    }

    /// Writes multiple checkpoints in one SQL statement on an existing connection.
    /// Does not extend the claim lease — callers do that separately.
    /// Used by `WorkflowScheduling.flushWrites()` to commit checkpoints and history atomically.
    static func batchSetCheckpointsOnConn(
        on conn: PostgresConnection,
        namespaceID: String,
        taskID: UUID,
        runID: UUID,
        checkpoints: [(seqNum: Int, name: String?, state: ByteBuffer)],
        logger: Logger
    ) async throws {
        guard !checkpoints.isEmpty else { return }
        if checkpoints.count == 1 {
            let c = checkpoints[0]
            try await setCheckpointState(
                on: conn,
                namespaceID: namespaceID,
                taskID: taskID,
                seqNum: c.seqNum,
                name: c.name,
                stateBuffer: c.state,
                runID: runID,
                logger: logger
            )
            return
        }
        var interp = PostgresQuery.StringInterpolation(
            literalCapacity: 200 + checkpoints.count * 100,
            interpolationCount: checkpoints.count * 6
        )
        interp.appendLiteral(
            "INSERT INTO strand.checkpoints "
                + "(namespace_id, task_id, seq_num, name, state, run_id) VALUES "
        )
        for (i, c) in checkpoints.enumerated() {
            if i > 0 { interp.appendLiteral(", ") }
            interp.appendLiteral("(")
            interp.appendInterpolation(namespaceID)
            interp.appendLiteral(", ")
            interp.appendInterpolation(taskID)
            interp.appendLiteral(", ")
            interp.appendInterpolation(c.seqNum)
            interp.appendLiteral(", ")
            interp.appendInterpolation(c.name)
            interp.appendLiteral(", ")
            interp.appendInterpolation(c.state)
            interp.appendLiteral(", ")
            interp.appendInterpolation(runID)
            interp.appendLiteral(")")
        }
        interp.appendLiteral(
            " ON CONFLICT (task_id, seq_num) DO UPDATE"
                + " SET state = EXCLUDED.state,"
                + "     run_id = EXCLUDED.run_id,"
                + "     created_at = NOW()"
                + " WHERE (SELECT attempt FROM strand.runs WHERE id = strand.checkpoints.run_id)"
                + "    <= (SELECT attempt FROM strand.runs WHERE id = EXCLUDED.run_id)"
        )
        try await conn.query(PostgresQuery(stringInterpolation: interp), logger: logger)
    }

    /// Writes checkpoints and optionally extends the claim lease.
    /// Delegates to ``batchSetCheckpointsOnConn`` so the SQL lives in one place.
    /// For N=1 uses ``setCheckpointState`` (single-row path with inline lease extension).
    static func batchSetCheckpoints(
        on client: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        runID: UUID,
        checkpoints: [(seqNum: Int, name: String?, state: ByteBuffer)],
        extendClaimBySeconds: Int?,
        logger: Logger
    ) async throws {
        guard !checkpoints.isEmpty else { return }
        if checkpoints.count == 1 {
            let c = checkpoints[0]
            try await setCheckpointState(
                on: client,
                namespaceID: namespaceID,
                taskID: taskID,
                seqNum: c.seqNum,
                name: c.name,
                stateBuffer: c.state,
                runID: runID,
                extendClaimBySeconds: extendClaimBySeconds,
                logger: logger
            )
            return
        }
        try await client.withTransaction(logger: logger) { conn in
            try await batchSetCheckpointsOnConn(
                on: conn,
                namespaceID: namespaceID,
                taskID: taskID,
                runID: runID,
                checkpoints: checkpoints,
                logger: logger
            )
            if let secs = extendClaimBySeconds {
                do {
                    try await extendClaim(
                        on: conn,
                        namespaceID: namespaceID,
                        runID: runID,
                        extendBySeconds: secs,
                        logger: logger
                    )
                } catch InternalError.cancelled {
                    // Run is no longer RUNNING — checkpoint still commits, lease
                    // extension skipped. sweepExpiredLeases handles the stale claim.
                }
            }
        }
    }

    // MARK: - Events

    /// Checks for an existing event; if absent, registers a wait and suspends the run.
    static func awaitEvent(
        on client: PostgresClient,
        namespaceID: String,
        queue: String,
        taskID: UUID,
        runID: UUID,
        version: Int,
        seqNum: Int,
        eventName: String,
        timeoutSeconds: Int?,
        currentWakeEvent: String?,
        currentEventPayload: ByteBuffer?,
        logger: Logger
    ) async throws -> AwaitEventResult {
        if currentWakeEvent == eventName {
            return currentEventPayload.map { .payload($0) } ?? .timedOut
        }
        return try await client.withTransaction(logger: logger) { conn in
            let evtStream = try await conn.query(
                "SELECT payload FROM strand.events WHERE namespace_id = \(namespaceID) AND queue = \(queue) AND name = \(eventName) ORDER BY created_at DESC LIMIT 1",
                logger: logger
            )
            if let row = try await evtStream.first(where: { _ in true }) {
                var col = row.makeIterator()
                // RawJSONB decodes JSONB in text wire format — no 0x01 binary prefix.
                if let raw = try col.next()!.decode(RawJSONB?.self, context: .default) {
                    return .payload(raw.buffer)
                }
            }
            let timeoutAt: Date? = timeoutSeconds.map { Date.now.addingTimeInterval(Double($0)) }
            try await conn.query(
                """
                INSERT INTO strand.event_waits (task_id, run_id, queue, seq_num, event_name, timeout_at)
                VALUES (\(taskID), \(runID), \(queue), \(seqNum), \(eventName), \(timeoutAt))
                ON CONFLICT (run_id, seq_num)
                DO UPDATE SET event_name = EXCLUDED.event_name, timeout_at = EXCLUDED.timeout_at
                """,
                logger: logger
            )
            // Timed waits use SLEEPING so the claim poll loop auto-wakes the run when
            // available_at (= timeoutAt) is reached. Untimed waits use WAITING — the
            // run is only woken by an explicit event emission or signal delivery.
            if let timeoutAt {
                try await conn.query(
                    """
                    WITH r AS (
                        UPDATE strand.runs
                        SET state = \(TaskState.sleeping), available_at = \(timeoutAt),
                            wake_event = \(eventName), event_payload = NULL,
                            lease_expires_at = NULL
                        WHERE id      = \(runID)
                          AND state   = \(TaskState.running)
                          AND version = \(version)
                        RETURNING id
                    )
                    UPDATE strand.tasks SET state = \(TaskState.sleeping) WHERE id = \(taskID)
                      AND EXISTS (SELECT 1 FROM r)
                    """,
                    logger: logger
                )
            } else {
                try await conn.query(
                    """
                    WITH r AS (
                        UPDATE strand.runs
                        SET state = \(TaskState.waiting),
                            wake_event = \(eventName), event_payload = NULL,
                            lease_expires_at = NULL
                        WHERE id      = \(runID)
                          AND state   = \(TaskState.running)
                          AND version = \(version)
                        RETURNING id
                    )
                    UPDATE strand.tasks SET state = \(TaskState.waiting) WHERE id = \(taskID)
                      AND EXISTS (SELECT 1 FROM r)
                    """,
                    logger: logger
                )
            }
            return .suspended
        }
    }

    /// Writes the TimeoutSentinel checkpoint and the `EVENT_WAIT_TIMED_OUT` history row
    /// in a single transaction so they are always present or absent together.
    ///
    /// Called from `applyScheduleCommands` when processing `.eventWaitTimedOut`.
    static func writeEventWaitTimedOut(
        on client: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        runID: UUID,
        seqNum: Int,
        historySeq: Int,
        eventName: String,
        logger: Logger
    ) async throws {
        let sentinel = try JSON.encode(TimeoutSentinel())
        let eventData = try? JSON.encode(WorkflowStateQueries.NamedEventData(eventName: eventName))
        let cpName: String = "waitForEvent:\(eventName)"
        let rawType = WorkflowStateQueries.HistoryEventType.eventWaitTimedOut.rawValue
        try await client.withTransaction(logger: logger) { conn in
            try await Queries.setCheckpointState(
                on: conn,
                namespaceID: namespaceID,
                taskID: taskID,
                seqNum: seqNum,
                name: cpName,
                stateBuffer: sentinel,
                runID: runID,
                logger: logger
            )
            try await conn.query(
                """
                INSERT INTO strand.workflow_history (namespace_id, task_id, seq, event_type, event_data)
                VALUES (\(namespaceID), \(taskID), \(historySeq), \(rawType), \(eventData))
                ON CONFLICT (task_id, seq) DO NOTHING
                """,
                logger: logger
            )
        }
    }

    /// Atomically writes the `ConditionResultSentinel` checkpoint and the
    /// `CONDITION_MET` or `CONDITION_TIMED_OUT` history row for a `condition(timeout:)` call.
    /// Uses the same `seqNum` slot as the deadline checkpoint (overwrites it).
    static func writeConditionResult(
        on client: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        runID: UUID,
        seqNum: Int,
        historySeq: Int,
        met: Bool,
        logger: Logger
    ) async throws {
        let sentinel = try JSON.encode(ConditionResultSentinel(met: met))
        let rawType =
            (met
            ? WorkflowStateQueries.HistoryEventType.conditionMet
            : WorkflowStateQueries.HistoryEventType.conditionTimedOut).rawValue
        try await client.withTransaction(logger: logger) { conn in
            try await Queries.setCheckpointState(
                on: conn,
                namespaceID: namespaceID,
                taskID: taskID,
                seqNum: seqNum,
                name: "conditionResult",
                stateBuffer: sentinel,
                runID: runID,
                logger: logger
            )
            try await conn.query(
                """
                INSERT INTO strand.workflow_history (namespace_id, task_id, seq, event_type, event_data)
                VALUES (\(namespaceID), \(taskID), \(historySeq), \(rawType), NULL)
                ON CONFLICT (task_id, seq) DO NOTHING
                """,
                logger: logger
            )
        }
    }

    static func emitEvent(
        on client: PostgresClient,
        namespaceID: String,
        queue: String,
        eventName: String,
        payloadBuffer: ByteBuffer,
        logger: Logger
    ) async throws {
        try await client.withTransaction(logger: logger) { conn in
            // Always insert a new row — append-only log.
            let emissionID = UUID.v7()
            try await conn.query(
                """
                INSERT INTO strand.events (id, namespace_id, queue, name, payload)
                VALUES (\(emissionID), \(namespaceID), \(queue), \(eventName), \(RawJSONB(payloadBuffer)))
                """,
                logger: logger
            )

            // payload is JSONB; RawJSONB sends payloadBuffer with JSONB OID directly.
            let waitsStream = try await conn.query(
                """
                SELECT task_id, run_id FROM strand.event_waits
                WHERE namespace_id = \(namespaceID)
                  AND queue        = \(queue)
                  AND event_name   = \(eventName)
                  AND \(RawJSONB(payloadBuffer)) @> predicate
                """,
                logger: logger
            )
            var waits: [(taskID: UUID, runID: UUID)] = []
            for try await row in waitsStream {
                var col = row.makeIterator()
                waits.append(
                    (
                        try col.next()!.decode(UUID.self, context: .default),
                        try col.next()!.decode(UUID.self, context: .default)
                    )
                )
            }
            for wait in waits {
                try await conn.query(
                    "UPDATE strand.runs SET state = \(TaskState.pending), available_at = NOW(), event_payload = \(payloadBuffer), wake_event = \(eventName), lease_expires_at = NULL WHERE id = \(wait.runID) AND state IN (\(TaskState.sleeping), \(TaskState.waiting)) AND namespace_id = \(namespaceID)",
                    logger: logger
                )
                try await conn.query(
                    "UPDATE strand.tasks SET state = \(TaskState.pending) WHERE id = \(wait.taskID) AND namespace_id = \(namespaceID)",
                    logger: logger
                )
            }
            // Record each triggered task in strand.event_triggers with emission_id linkage.
            // These rows power the "workflows triggered by this event" display in
            // the dashboard and are cleaned up automatically via ON DELETE CASCADE
            // when StrandPruner deletes the parent task.
            for wait in waits {
                try await conn.query(
                    """
                    INSERT INTO strand.event_triggers
                        (id, namespace_id, queue, event_name, emission_id, task_id, run_id)
                    VALUES (\(UUID.v7()), \(namespaceID), \(queue), \(eventName), \(emissionID), \(wait.taskID), \(wait.runID))
                    ON CONFLICT (emission_id, task_id) WHERE emission_id IS NOT NULL DO NOTHING
                    """,
                    logger: logger
                )
            }
            // Delete only the waiters that were actually woken (predicate matched).
            // Non-matching waiters remain registered for a future event that satisfies them.
            try await conn.query(
                """
                DELETE FROM strand.event_waits
                WHERE namespace_id = \(namespaceID)
                  AND queue        = \(queue)
                  AND event_name   = \(eventName)
                  AND \(RawJSONB(payloadBuffer)) @> predicate
                """,
                logger: logger
            )
            if !waits.isEmpty {
                try await conn.notifyWorkers(namespace: namespaceID, queue: queue, logger: logger)
            }
        }
    }

    // MARK: - Update result polling

    /// Returns the payload of the most-recent `strand.events` row with the given
    /// `name` in `namespaceID`, or `nil` if no such row exists yet.
    ///
    /// Used by `WorkflowHandle.executeUpdate` to poll for update results stored
    /// as named events in `strand.events`.  Correlation IDs are UUIDs, making the
    /// event name globally unique, so no queue filter is required.
    static func findLatestEventPayload(
        on client: PostgresClient,
        namespaceID: String,
        name: String,
        logger: Logger
    ) async throws -> ByteBuffer? {
        let stream = try await client.query(
            """
            SELECT payload
            FROM   strand.events
            WHERE  namespace_id = \(namespaceID)
              AND  name         = \(name)
            ORDER  BY created_at DESC
            LIMIT  1
            """,
            logger: logger
        )
        for try await row in stream {
            var col = row.makeIterator()
            if let raw = try col.next()!.decode(RawJSONB?.self, context: .default) {
                return raw.buffer
            }
        }
        return nil
    }

    // MARK: - Lease expiry sweep

    /// Finds runs whose claim lease has expired and fails them so they are
    /// retried.
    /// `FOR UPDATE SKIP LOCKED` ensures each expired run is processed by
    /// exactly one worker even when multiple workers share a queue.
    ///
    /// Re-queues every run that has been in RUNNING state past its
    /// `lease_expires_at` deadline. Transitions `RUNNING → PENDING` for
    /// the **same attempt** so the next worker picks it up transparently.
    ///
    /// A ClaimTimeout is a pure infrastructure event (worker crash, restart,
    /// or OOM). It must **not** count against a task’s retry budget and must
    /// **not** surface as an error in the dashboard. The task’s `attempt`
    /// counter stays unchanged; the next worker replays from checkpoints.
    ///
    /// Contrast with the 2×-claimTimeout in-process deadline (``ClaimTimeoutError``
    /// thrown from ``StrandWorker/runTask(_:)``): that fires when the
    /// *same worker* is still running the task and is genuinely stuck —
    /// it goes through ``failRun`` and does increment the attempt counter.
    static func sweepExpiredLeases(
        on client: PostgresClient,
        namespaceID: String,
        queue: String,
        logger: Logger
    ) async throws {
        // Select expired runs and re-queue them atomically.
        // `FOR UPDATE SKIP LOCKED` ensures two concurrent sweepers on the
        // same queue never double-process the same run.
        let stream = try await client.query(
            """
            WITH expired AS (
                SELECT r.id AS run_id, r.task_id
                FROM strand.runs r
                WHERE r.namespace_id    = \(namespaceID)
                  AND r.queue           = \(queue)
                  AND r.state           = \(TaskState.running)
                  AND r.lease_expires_at <= NOW()
                ORDER BY r.lease_expires_at, r.id
                LIMIT 50
                FOR UPDATE SKIP LOCKED
            ),
            requeued_runs AS (
                UPDATE strand.runs
                SET state            = \(TaskState.pending),
                    available_at     = NOW(),
                    worker_id        = NULL,
                    lease_expires_at = NULL
                FROM expired
                WHERE strand.runs.id = expired.run_id
                RETURNING expired.run_id, expired.task_id
            )
            UPDATE strand.tasks
            SET state = \(TaskState.pending)
            FROM requeued_runs
            WHERE strand.tasks.id             = requeued_runs.task_id
              AND strand.tasks.namespace_id   = \(namespaceID)
            RETURNING requeued_runs.run_id
            """,
            logger: logger
        )
        var count = 0
        for try await _ in stream { count += 1 }
        if count > 0 {
            logger.warning(
                "re-queued \(count) run(s) with expired lease—worker was likely restarted",
                metadata: ["queue": "\(queue)"]
            )
            try await client.notifyWorkers(namespace: namespaceID, queue: queue, logger: logger)
        }
    }

    /// Reschedules or permanently fails PENDING/SLEEPING activities whose
    /// `schedule_to_start_timeout_seconds` elapsed before any worker claimed them.
    ///
    /// Two outcomes:
    ///   - `maxDuration` exceeded → mark task FAILED, wake parent workflow
    ///   - Otherwise → reset `available_at` with retry backoff, workflow not notified
    ///
    /// Each expired run is re-checked inside its own transaction with `FOR UPDATE`.
    /// If a worker claimed the run between the outer SELECT and the lock, the run
    /// is RUNNING and the `guard state == .pending || .sleeping` check skips it.
    static func sweepStartTimeoutActivities(
        on client: PostgresClient,
        namespaceID: String,
        queue: String,
        logger: Logger
    ) async throws {
        // One transaction per expired run: SELECT (lock) + fail + optional retry.
        // `try?` makes individual-run failures soft — a transient error on one run
        // does not prevent the rest from being processed.
        let stream = try await client.query(
            """
            SELECT r.id, r.task_id, r.attempt
            FROM   strand.runs r
            JOIN   strand.tasks t ON t.id = r.task_id
            WHERE  r.namespace_id = \(namespaceID)
              AND  r.queue        = \(queue)
              AND  r.state        IN (\(TaskState.pending), \(TaskState.sleeping))
              AND  t.kind         = \(TaskKind.activity)
              AND  t.schedule_to_start_timeout_seconds IS NOT NULL
              AND  r.available_at + t.schedule_to_start_timeout_seconds
                   * INTERVAL '1 second' <= NOW()
            ORDER  BY r.id
            LIMIT  50
            """,
            logger: logger
        )
        var expired: [(runID: UUID, taskID: UUID, attempt: Int)] = []
        for try await row in stream {
            var col = row.makeIterator()
            let runID = try col.next()!.decode(UUID.self, context: .default)
            let taskID = try col.next()!.decode(UUID.self, context: .default)
            let attempt = try col.next()!.decode(Int.self, context: .default)
            expired.append((runID: runID, taskID: taskID, attempt: attempt))
        }
        guard !expired.isEmpty else { return }
        let noun: Logger.Message =
            expired.count == 1
            ? "sweeping 1 schedule-to-start timeout activity"
            : "sweeping \(expired.count) schedule-to-start timeout activities"
        logger.debug(noun, metadata: ["strand.queue": .string(queue)])
        // FailureReason is a plain Codable class — encoding cannot fail; try! is safe.
        let reasonBuffer = try! JSON.encode(FailureReason(error: _ScheduleToStartTimeoutError()))
        for item in expired {
            try? await client.withTransaction(logger: logger) { conn in
                // Atomically re-check and fail this specific run.
                // FOR UPDATE ensures a concurrent worker that just claimed it sees
                // a RUNNING state — the next UPDATE will find 0 rows and skip it,
                // preventing a double-fail race on the same run.
                let lockStream = try await conn.query(
                    """
                    SELECT r.state, t.retry_strategy, t.deadline_at
                    FROM   strand.runs r
                    JOIN   strand.tasks t ON t.id = r.task_id
                    WHERE  r.id            = \(item.runID)
                      AND  r.namespace_id  = \(namespaceID)
                    FOR UPDATE
                    """,
                    logger: logger
                )
                guard let lockRow = try await lockStream.first(where: { _ in true }) else { return }
                var col = lockRow.makeIterator()
                let state = try col.next()!.decode(TaskState.self, context: .default)
                let retryStratBuf = try col.next()!.decode(ByteBuffer?.self, context: .default)
                let deadlineAt = try col.next()!.decode(Date?.self, context: .default)

                // If a worker claimed the run between the outer SELECT and this
                // FOR UPDATE, it's now RUNNING. Skip it — the worker owns it.
                guard state == .pending || state == .sleeping else { return }

                // Only maxDuration is a hard stop for schedule-to-start retries.
                // maxAttempts counts handler executions — nothing ran here, so it
                // is not decremented. If maxDuration is not set the activity keeps
                // re-queuing (with retry backoff) until a worker claims it.
                let isPermanent = deadlineAt.map { Date.now >= $0 } ?? false

                if isPermanent {
                    // maxDuration exceeded — fail permanently and wake the parent.
                    try await conn.query(
                        "UPDATE strand.runs SET state = \(TaskState.failed), failure_reason = \(reasonBuffer), finished_at = NOW() WHERE id = \(item.runID)",
                        logger: logger
                    )
                    try await conn.query(
                        "UPDATE strand.tasks SET state = \(TaskState.failed) WHERE id = \(item.taskID) AND namespace_id = \(namespaceID)",
                        logger: logger
                    )
                    try await emitTaskCompletionSignal(
                        conn: conn,
                        namespaceID: namespaceID,
                        taskID: item.taskID,
                        state: .failed,
                        resultBuffer: nil,
                        logger: logger
                    )
                } else {
                    // Re-queue in place. Nothing was executed so neither the attempt
                    // counter nor maxAttempts budget is consumed. The run is reset to
                    // PENDING/SLEEPING with the retry backoff applied to available_at.
                    let delay = retryDelay(strategy: retryStratBuf, attempt: item.attempt)
                    let wakeAt = Date.now.addingTimeInterval(delay)
                    let newState: TaskState = delay > 0 ? .sleeping : .pending
                    try await conn.query(
                        """
                        UPDATE strand.runs
                        SET state = \(newState), available_at = \(wakeAt),
                            worker_id = NULL, lease_expires_at = NULL
                        WHERE id = \(item.runID)
                        """,
                        logger: logger
                    )
                    try await conn.query(
                        "UPDATE strand.tasks SET state = \(newState) WHERE id = \(item.taskID) AND namespace_id = \(namespaceID)",
                        logger: logger
                    )
                    if newState == .pending {
                        try await conn.notifyWorkers(namespace: namespaceID, queue: queue, logger: logger)
                    }
                }
            }
        }
    }

    private struct _ScheduleToStartTimeoutError: Error, CustomStringConvertible {
        var description: String {
            "schedule-to-start timeout: activity was not claimed by any worker within the allowed window"
        }
    }

    // MARK: - Worker heartbeat

    /// Upserts a worker heartbeat row into `strand.workers`.
    /// Called on startup (running=0) and on every heartbeat tick (with current running count).
    static func upsertWorker(
        on client: PostgresClient,
        workerID: String,
        namespaceID: String,
        queue: String,
        concurrency: Int,
        running: Int,
        sdkVersion: String,
        logger: Logger
    ) async throws {
        try await client.query(
            """
            INSERT INTO strand.workers (id, namespace_id, queue, concurrency, running, sdk_version, started_at, updated_at)
            VALUES (\(workerID), \(namespaceID), \(queue), \(concurrency), \(running), \(sdkVersion), NOW(), NOW())
            ON CONFLICT (id, namespace_id, queue)
            DO UPDATE SET
                concurrency  = EXCLUDED.concurrency,
                running      = EXCLUDED.running,
                sdk_version  = EXCLUDED.sdk_version,
                updated_at   = NOW()
            """,
            logger: logger
        )
    }

    /// Deletes a worker row — called on clean shutdown.
    /// Workers killed without a graceful shutdown are swept by `sweepStaleWorkers`.
    static func deleteWorker(
        on client: PostgresClient,
        workerID: String,
        namespaceID: String,
        queue: String,
        logger: Logger
    ) async throws {
        try await client.query(
            """
            DELETE FROM strand.workers
            WHERE id           = \(workerID)
              AND namespace_id = \(namespaceID)
              AND queue        = \(queue)
            """,
            logger: logger
        )
    }

    /// Graceful-shutdown helper: expires in-flight run leases and removes the
    /// worker heartbeat row in a single round-trip.
    static func shutdownWorker(
        on client: PostgresClient,
        workerID: String,
        namespaceID: String,
        queue: String,
        logger: Logger
    ) async throws {
        try await client.query(
            """
            WITH expire_runs AS (
                UPDATE strand.runs
                SET lease_expires_at = NOW()
                WHERE worker_id    = \(workerID)
                  AND namespace_id = \(namespaceID)
                  AND state        = \(TaskState.running)
                  AND created_at  >= DATE_TRUNC('month', NOW()) - INTERVAL '1 month'
            )
            DELETE FROM strand.workers
            WHERE id           = \(workerID)
              AND namespace_id = \(namespaceID)
              AND queue        = \(queue)
            """,
            logger: logger
        )
    }

    /// Removes worker rows whose `updated_at` is older than `olderThanSeconds`.
    /// Called on each heartbeat tick so stale entries from crashed workers are cleaned up.
    static func sweepStaleWorkers(
        on client: PostgresClient,
        olderThanSeconds: Int,
        logger: Logger
    ) async throws {
        try await client.query(
            "DELETE FROM strand.workers WHERE updated_at < NOW() - \(olderThanSeconds) * INTERVAL '1 second'",
            logger: logger
        )
    }

    // MARK: - continueAsNew for child workflows

    /// Deletes transient workflow artefacts for `taskID` so a fresh activation
    /// starts from a clean state.
    ///
    /// Called inside an existing transaction by
    /// ``retryTask(on:namespaceID:taskID:resetHistory:logger:)`` when
    /// `resetHistory` is `true`. All retry modes operate on FAILED or CANCELLED
    /// tasks, which have no outstanding `event_waits` by construction, so this
    /// function never needs to touch that table.
    ///
    /// ``continueChildWorkflowAsNew(on:namespaceID:taskID:currentRunID:currentVersion:newInput:newRunID:logger:)``
    /// performs the same deletions inline as named CTE arms (plus `event_waits`,
    /// which is required for a still-RUNNING task) to keep that operation a
    /// **single round-trip**. If you add a table here, mirror it there.
    ///
    /// - Parameter clearHistory: Pass `true` when the caller wants a full
    ///   clean-slate reset. Deletes `workflow_history` so `nextHistorySeq`
    ///   resets to 1 and `WORKFLOW_STARTED` is re-emitted on the new activation.
    ///   Pass `false` for `continueAsNew`-style resets that intentionally
    ///   preserve the accumulated history across continuation cycles.
    static func clearWorkflowArtefacts(
        on conn: PostgresConnection,
        taskID: UUID,
        namespaceID: String,
        clearHistory: Bool,
        logger: Logger
    ) async throws {
        // Checkpoints — isolated from the new run by run_id in SELECT, but the
        // old rows still appear in the Loom dashboard for the old failed run.
        try await conn.query(
            "DELETE FROM strand.checkpoints WHERE task_id = \(taskID) AND namespace_id = \(namespaceID)",
            logger: logger
        )
        // Workflow state — keyed by task_id only; without this delete the fresh
        // _activate path restores stale signal-mutated fields (isPaused=true etc.)
        // instead of starting from W().
        try await conn.query(
            "DELETE FROM strand.workflow_state WHERE task_id = \(taskID) AND namespace_id = \(namespaceID)",
            logger: logger
        )
        // Pending signals — stale signals queued before the failure must not
        // replay against the fresh W() state of the reset run.
        try await conn.query(
            "DELETE FROM strand.workflow_signals WHERE task_id = \(taskID) AND namespace_id = \(namespaceID)",
            logger: logger
        )
        if clearHistory {
            // nextHistorySeq() uses MAX(seq); without this delete the new activation
            // inherits the old sequence number and isFirstActivation stays false
            // (WORKFLOW_STARTED is never re-emitted on the reset run).
            try await conn.query(
                "DELETE FROM strand.workflow_history WHERE task_id = \(taskID) AND namespace_id = \(namespaceID)",
                logger: logger
            )
            // Delete all terminal run records so the Runs panel shows a clean
            // slate. The newly-inserted PENDING run (created by retryTask before
            // this call) has state = 'PENDING' and is NOT matched by this DELETE.
            // PostgreSQL CTE isolation guarantees the same for resetChildTasks.
            try await conn.query(
                """
                DELETE FROM strand.runs
                WHERE  task_id      = \(taskID)
                  AND  namespace_id = \(namespaceID)
                  AND  state NOT IN ('PENDING', 'RUNNING', 'SLEEPING', 'WAITING')
                """,
                logger: logger
            )
        }
    }

    /// Resets a **child** workflow for continuation-as-new without signalling its parent.
    ///
    /// When `context.continueAsNew(input:)` is called inside a child workflow
    /// (one that has a `parent_task_id`), creating a brand-new task would break the
    /// parent’s `event_wait`, which is keyed on the **original** `task_id`. This
    /// function keeps the same `task_id` and instead:
    ///
    ///   1. Marks the current run `COMPLETED` — no `task_completions` row, no signal.
    ///   2. Resets `strand.tasks` to `PENDING` with the new input.
    ///   3. Deletes checkpoints, `workflow_state`, stale signals, and the child’s
    ///      own `event_waits` (the parent’s wait for this task is on the *parent*’s
    ///      `run_id` and is untouched).
    ///   4. Inserts a fresh `PENDING` run for the same task.
    ///
    /// The parent remains `WAITING` (its `event_waits.child_task_id` still points to
    /// `taskID`). When the chain finally calls `completeRun` with a real result,
    /// `emitTaskCompletionSignal` fires and the parent receives the correct value.
    ///
    /// The entire operation is one atomic CTE. If the CAS check
    /// (`state = RUNNING AND version = currentVersion`) fails (race / duplicate),
    /// all CTEs are no-ops — safe under concurrent execution.
    ///
    static func continueChildWorkflowAsNew(
        on client: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        currentRunID: UUID,
        currentVersion: Int,
        newInput: ByteBuffer,
        newRunID: UUID,
        logger: Logger
    ) async throws {
        try await client.query(
            """
            WITH
            complete_run AS (
                UPDATE strand.runs
                SET state = 'COMPLETED', finished_at = NOW()
                WHERE id            = \(currentRunID)
                  AND state         = 'RUNNING'
                  AND version       = \(currentVersion)
                RETURNING task_id
            ),
            reset_task AS (
                UPDATE strand.tasks
                SET state  = 'PENDING',
                    params = \(newInput)
                WHERE id           = (SELECT task_id FROM complete_run)
                  AND namespace_id = \(namespaceID)
                RETURNING id, queue, priority, fairness_key, fairness_weight, kind
            ),
            -- These DELETE arms mirror clearWorkflowArtefacts(clearHistory: false)
            -- plus del_event_waits (required here; FAILED tasks never have waits).
            -- Both are inlined to keep this a single round-trip.
            -- If you add a table to clearWorkflowArtefacts, add a matching arm here.
            del_checkpoints AS (
                DELETE FROM strand.checkpoints
                WHERE task_id      = (SELECT task_id FROM complete_run)
                  AND namespace_id = \(namespaceID)
            ),
            del_workflow_state AS (
                DELETE FROM strand.workflow_state
                WHERE task_id      = (SELECT task_id FROM complete_run)
                  AND namespace_id = \(namespaceID)
            ),
            del_signals AS (
                DELETE FROM strand.workflow_signals
                WHERE task_id      = (SELECT task_id FROM complete_run)
                  AND namespace_id = \(namespaceID)
            ),
            del_event_waits AS (
                -- Remove the child's OWN event_waits (activities / timers it was
                -- waiting for). The parent's event_wait is on the parent's run_id
                -- and is not touched.
                DELETE FROM strand.event_waits
                WHERE task_id = (SELECT task_id FROM complete_run)
            ),
            new_run AS (
                INSERT INTO strand.runs
                    (id, namespace_id, task_id, queue, attempt, state,
                     available_at, created_at, priority, fairness_key, fairness_weight, kind)
                SELECT \(newRunID), \(namespaceID), id, queue, 1, 'PENDING',
                       NOW(), NOW(), priority, fairness_key, fairness_weight, kind
                FROM reset_task
                RETURNING namespace_id, queue
            )
            SELECT pg_notify(\(StrandChannels.tasks), namespace_id || '/' || queue)
            FROM new_run
            """,
            logger: logger
        )
    }

    // MARK: - resetChildTasks

    /// Resets descendant tasks of `rootTaskID` to PENDING based on the retry mode,
    /// then notifies workers on affected queues.
    ///
    /// Called from ``StrandClient/requeueTask(id:options:namespaceID:)`` **before**
    /// ``retryTask(on:namespaceID:taskID:resetHistory:logger:)`` so the parent
    /// workflow's next activation finds fresh child slots instead of replaying old
    /// results from `task_completions`.
    ///
    /// | Mode                    | Descendants reset                                |
    /// |-------------------------|--------------------------------------------------|
    /// | `.failedOnly`           | FAILED and CANCELLED only                        |
    /// | `.failedAndDependents`  | FAILED/CANCELLED + any created at or after the   |
    /// |                         | earliest failure (even if they succeeded)         |
    /// | `.all`                  | Every descendant regardless of state             |
    ///
    /// For each selected descendant the function:
    /// 1. Deletes its `task_completions` row — the parent must not fast-path these
    ///    on its next activation.
    /// 2. Updates `strand.tasks` to PENDING (bumps or resets `attempt` based on
    ///    `resetHistory`).
    /// 3. Inserts a fresh PENDING run.
    ///
    /// Returns immediately when there are no descendants — safe to call for plain
    /// activity tasks.
    ///
    /// Run IDs are generated by `strand.gen_uuid_v7()` inside the CTE, keeping the
    /// entire operation a single round-trip while still producing time-ordered UUIDs.
    static func resetChildTasks(
        on client: PostgresClient,
        rootTaskID: UUID,
        namespaceID: String,
        mode: RetryOptions.Mode,
        resetHistory: Bool,
        logger: Logger
    ) async throws {
        try await client.withTransaction(logger: logger) { conn in
            try await resetChildTasks(
                on: conn,
                rootTaskID: rootTaskID,
                namespaceID: namespaceID,
                mode: mode,
                resetHistory: resetHistory,
                logger: logger
            )
        }
    }

    static func resetChildTasks(
        on conn: PostgresConnection,
        rootTaskID: UUID,
        namespaceID: String,
        mode: RetryOptions.Mode,
        resetHistory: Bool,
        logger: Logger
    ) async throws {
        let modeRaw = mode.rawValue
        // The sentinel bytes are owned by the type — no duplication of the JSON key.
        let sentinelBuf = ActivityFailedSentinel.encoded
        let stream = try await conn.query(
            """
            WITH RECURSIVE
            all_desc AS (
                -- Direct children of rootTaskID
                SELECT id, state, queue, priority, fairness_key, fairness_weight,
                       attempt, max_attempts, kind, parent_task_id, created_at
                FROM   strand.tasks
                WHERE  parent_task_id = \(rootTaskID)
                  AND  namespace_id   = \(namespaceID)
                UNION ALL
                -- Grandchildren and deeper
                SELECT t.id, t.state, t.queue, t.priority, t.fairness_key, t.fairness_weight,
                       t.attempt, t.max_attempts, t.kind, t.parent_task_id, t.created_at
                FROM   strand.tasks t
                JOIN   all_desc d ON t.parent_task_id = d.id
            ),
            -- Earliest point of failure; NULL when there are no failures.
            earliest_fail_at AS (
                SELECT MIN(created_at) AS t
                FROM   all_desc
                WHERE  state IN ('FAILED', 'CANCELLED')
            ),
            -- Which descendants to reset:
            --   'all'                   -> every descendant
            --   'failed_only'           -> FAILED / CANCELLED only
            --   'failed_and_dependents' -> FAILED / CANCELLED + any that were
            --                             created at or after the earliest failure
            to_reset AS (
                SELECT * FROM all_desc
                WHERE  \(modeRaw) = 'all'
                    OR state IN ('FAILED', 'CANCELLED')
                    OR (    \(modeRaw) = 'failed_and_dependents'
                        AND created_at >= COALESCE(
                                (SELECT t FROM earliest_fail_at),
                                'infinity'::timestamptz))
            ),
            -- 1. Remove old completion records so the parent workflow does not
            --    fast-path these children via task_completions on its next activation.
            del_completions AS (
                DELETE FROM strand.task_completions
                WHERE  task_id      IN (SELECT id FROM to_reset)
                  AND  namespace_id  = \(namespaceID)
            ),
            -- 2. Advance the task state and attempt counter.
            upd_tasks AS (
                UPDATE strand.tasks t
                SET    state        = 'PENDING',
                       attempt      = CASE WHEN \(resetHistory) THEN 1
                                          ELSE t.attempt + 1
                                     END,
                       max_attempts = CASE WHEN \(resetHistory) THEN t.max_attempts
                                          ELSE GREATEST(
                                                  COALESCE(t.max_attempts, t.attempt + 1),
                                                  t.attempt + 1)
                                     END
                FROM   to_reset tr
                WHERE  t.id = tr.id
            ),
            -- 3. One fresh PENDING run per reset task.
            --    strand.gen_uuid_v7() produces time-ordered UUIDs without a
            --    separate Swift round-trip (requires pgcrypto).
            new_runs AS (
                INSERT INTO strand.runs
                    (namespace_id, id, task_id, queue, attempt, state,
                     available_at, priority, fairness_key, fairness_weight,
                     kind, parent_task_id)
                SELECT \(namespaceID),
                       strand.gen_uuid_v7(),
                       tr.id,
                       tr.queue,
                       CASE WHEN \(resetHistory) THEN 1 ELSE tr.attempt + 1 END,
                       'PENDING',
                       NOW(),
                       tr.priority,
                       tr.fairness_key,
                       tr.fairness_weight,
                       tr.kind,
                       tr.parent_task_id
                FROM   to_reset tr
                RETURNING queue
            ),
            -- 4. When resetting history, remove all terminal run records for
            --    the selected child tasks so their Runs panels also show a
            --    clean slate. PostgreSQL CTE snapshot isolation ensures the
            --    newly-inserted PENDING rows (from new_runs above) are not
            --    visible to this DELETE — they did not exist at statement start.
            del_old_runs AS (
                DELETE FROM strand.runs
                WHERE  task_id      IN (SELECT id FROM to_reset)
                  AND  namespace_id  = \(namespaceID)
                  AND  state        NOT IN ('PENDING', 'RUNNING', 'SLEEPING', 'WAITING')
                  AND  \(resetHistory)
            ),
            -- 5. Clear the parent workflow's ActivityFailedSentinel checkpoints
            --    so the next activation re-dispatches the activities rather than
            --    hitting fast-path-1 and replaying the cached failure.
            --
            --    When a child activity fails the parent writes an
            --    ActivityFailedSentinel ({"failed":true}) at the activity's seq_num
            --    in strand.checkpoints (task_id = parent workflow task).  Without
            --    deleting it here the parent's next activation hits fast-path-1,
            --    reads the sentinel, and throws the same ActivityError again without
            --    ever re-dispatching the activity.
            --
            --    Every sentinel on this parent encodes to the same fixed byte
            --    sequence, so a direct value match is sufficient — no need to
            --    parse the idempotency key to recover the seq_num.
            --    (Not needed when resetHistory=true: retryTask calls
            --    clearWorkflowArtefacts which wipes all parent checkpoints.)
            del_parent_sentinels AS (
                DELETE FROM strand.checkpoints
                WHERE  task_id      = \(rootTaskID)
                  AND  namespace_id = \(namespaceID)
                  AND  NOT \(resetHistory)
                  AND  state        = \(sentinelBuf)
            )
            SELECT DISTINCT queue FROM new_runs
            """,
            logger: logger
        )
        var notified: Set<String> = []
        for try await row in stream {
            var col = row.makeIterator()
            let queue = try col.next()!.decode(String.self, context: .default)
            guard notified.insert(queue).inserted else { continue }
            try await conn.notifyWorkers(namespace: namespaceID, queue: queue, logger: logger)
        }
    }

    // MARK: - Retry

    /// Re-enqueues a failed task by inserting a new pending run.
    /// Bumps `max_attempts` if necessary so the retry is allowed.
    /// Returns the new run's ID and attempt number.
    static func retryTask(
        on client: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        resetHistory: Bool = false,
        logger: Logger
    ) async throws -> (runID: UUID, attempt: Int) {
        try await client.withTransaction(logger: logger) { conn in
            let stream = try await conn.query(
                """
                SELECT attempt, max_attempts FROM strand.tasks
                WHERE id = \(taskID) AND state IN (\(TaskState.failed), \(TaskState.cancelled))
                  AND namespace_id = \(namespaceID)
                FOR UPDATE
                """,
                logger: logger
            )
            guard let row = try await stream.first(where: { _ in true }) else {
                throw StrandError.database(
                    underlying: QueryError("task not found or not in failed state")
                )
            }
            var col = row.makeIterator()
            let attempt = try col.next()!.decode(Int.self, context: .default)
            let maxAttempts = try col.next()!.decode(Int?.self, context: .default)

            let nextAttempt: Int
            let newMaxAttempts: Int?
            if resetHistory {
                // Clean slate: reset to attempt 1, keep max_attempts unchanged.
                nextAttempt = 1
                newMaxAttempts = maxAttempts
            } else {
                // Continuing: bump attempt counter, ensure max_attempts allows this retry.
                nextAttempt = attempt + 1
                newMaxAttempts = maxAttempts.map { Swift.max($0, nextAttempt) }
            }
            let newRunID = UUID.v7()

            try await conn.query(
                """
                INSERT INTO strand.runs (namespace_id, id, task_id, queue, attempt, state, available_at,
                                       priority, fairness_key, fairness_weight,
                                       kind, parent_task_id, heartbeat_details)
                SELECT namespace_id, \(newRunID), id, queue, \(nextAttempt), \(TaskState.pending), NOW(),
                       priority, fairness_key, fairness_weight,
                       kind, parent_task_id,
                       -- Carry over the last heartbeat checkpoint when continuing (resetHistory=false)
                       -- so the activity can resume from its last progress marker.
                       -- Clean-slate retries (resetHistory=true) start fresh with NULL.
                       CASE WHEN NOT \(resetHistory)
                            THEN (SELECT r.heartbeat_details FROM strand.runs r
                                  WHERE r.task_id = t.id
                                  ORDER BY r.attempt DESC LIMIT 1)
                            ELSE NULL
                       END
                FROM strand.tasks t WHERE t.id = \(taskID) AND t.namespace_id = \(namespaceID)
                """,
                logger: logger
            )
            try await conn.query(
                """
                UPDATE strand.tasks
                SET state            = \(TaskState.pending),
                    attempt          = \(nextAttempt),
                    max_attempts     = \(newMaxAttempts),
                    cancel_requested = FALSE
                WHERE id = \(taskID)
                """,
                logger: logger
            )
            if resetHistory {
                // Clear failure_reason on prior runs so the dashboard shows a clean slate.
                try await conn.query(
                    """
                    UPDATE strand.runs
                    SET failure_reason = NULL
                    WHERE task_id = \(taskID) AND state IN (\(TaskState.failed), \(TaskState.cancelled))
                    """,
                    logger: logger
                )
                // Delete checkpoints, workflow state, pending signals, and history.
                // clearHistory=true so nextHistorySeq resets to 1 on the new activation.
                try await clearWorkflowArtefacts(
                    on: conn,
                    taskID: taskID,
                    namespaceID: namespaceID,
                    clearHistory: true,
                    logger: logger
                )
            }
            let qStream = try await conn.query(
                "SELECT queue FROM strand.tasks WHERE id = \(taskID) AND namespace_id = \(namespaceID)",
                logger: logger
            )
            if let qRow = try await qStream.first(where: { _ in true }) {
                var qCol = qRow.makeIterator()
                let q = try qCol.next()!.decode(String.self, context: .default)
                try await conn.notifyWorkers(namespace: namespaceID, queue: q, logger: logger)
            }
            return (newRunID, nextAttempt)
        }
    }

    // MARK: - Re-run (COMPLETED tasks)

    /// Creates a fresh new task from an existing COMPLETED one, copying its
    /// name, queue, params, priority, and kind. The original task is unchanged.
    /// Use this when the user wants to re-run a workflow that already succeeded.
    static func reRunTask(
        on client: PostgresClient,
        namespaceID: String,
        taskID: UUID,
        logger: Logger
    ) async throws -> EnqueueRow {
        try await client.withTransaction(logger: logger) { conn in
            // Read the original task's metadata.
            let src = try await conn.query(
                """
                SELECT name, queue, params, headers, scheduling_metadata, retry_strategy, max_attempts,
                       cancellation, priority, fairness_key, fairness_weight, kind
                FROM strand.tasks WHERE id = \(taskID) AND state = \(TaskState.completed)
                  AND namespace_id = \(namespaceID)
                FOR UPDATE
                """,
                logger: logger
            )
            guard let row = try await src.first(where: { _ in true }) else {
                throw StrandError.database(
                    underlying: QueryError("task not found or not in completed state")
                )
            }
            var col = row.makeIterator()
            let name = try col.next()!.decode(String.self, context: .default)
            let queue = try col.next()!.decode(String.self, context: .default)
            let params = try col.next()!.decode(ByteBuffer.self, context: .default)
            let headers = try col.next()!.decode(ByteBuffer?.self, context: .default)
            let schedulingMetadata = try col.next()!.decode(ByteBuffer?.self, context: .default)
            let retryStrategy = try col.next()!.decode(ByteBuffer?.self, context: .default)
            let maxAttempts = try col.next()!.decode(Int?.self, context: .default)
            let cancellation = try col.next()!.decode(ByteBuffer?.self, context: .default)
            let priority = try col.next()!.decode(TaskPriority.self, context: .default)
            let fairnessKey = try col.next()!.decode(String?.self, context: .default)
            let fairnessWeight = try col.next()!.decode(Double.self, context: .default)
            let kind = try col.next()!.decode(TaskKind.self, context: .default)

            let newTaskID = UUID.v7()
            let newRunID = UUID.v7()

            // Create the queue row if not present (idempotent).
            try await createQueue(on: conn, namespaceID: namespaceID, name: queue, logger: logger)

            try await conn.query(
                """
                INSERT INTO strand.tasks
                    (id, namespace_id, queue, name, params, headers, scheduling_metadata,
                     retry_strategy, max_attempts, cancellation, priority, fairness_key,
                     fairness_weight, kind, state)
                VALUES (\(newTaskID), \(namespaceID), \(queue), \(name), \(params),
                        \(headers), \(schedulingMetadata), \(retryStrategy), \(maxAttempts),
                        \(cancellation), \(priority), \(fairnessKey), \(fairnessWeight),
                        \(kind), \(TaskState.pending))
                """,
                logger: logger
            )

            try await conn.query(
                """
                INSERT INTO strand.runs (namespace_id, id, task_id, queue, attempt, state, available_at,
                                        priority, fairness_key, fairness_weight, kind)
                VALUES (\(namespaceID), \(newRunID), \(newTaskID), \(queue), 1, \(TaskState.pending), NOW(),
                        \(priority), \(fairnessKey), \(fairnessWeight), \(kind))
                """,
                logger: logger
            )
            try await conn.notifyWorkers(namespace: namespaceID, queue: queue, logger: logger)
            return EnqueueRow(taskID: newTaskID, runID: newRunID, attempt: 1, created: true)
        }
    }

    // MARK: - Task completion signals

    /// Persists the child completion and signals any waiting parent workflow.
    ///
    /// 1. **Insert** into `strand.task_completions` (idempotent via ON CONFLICT DO NOTHING).
    /// 2. **Flag** RUNNING parents via `has_buffered_completion = TRUE`; step-7 detects
    ///    this at the end of the parent's current activation and transitions to PENDING.
    /// 3. **Notify** workers for WAITING/SLEEPING parents so the poll loop can call
    ///    `wakeCompletedWaiting`.  RUNNING parents receive no notify here because
    ///    step-7's own deferred `notifyWorkers` fires after its transaction commits.
    ///
    /// The parent run state is owned exclusively by:
    ///   - step-7 `withTransaction`  (RUNNING → WAITING/PENDING)
    ///   - `wakeCompletedWaiting`    (WAITING → PENDING, from poll loop)
    ///   - External callers          (cancelTask, etc.)
    ///
    /// Must be called inside an existing transaction (`conn`).
    static func emitTaskCompletionSignal(
        conn: PostgresConnection,
        namespaceID: String,
        taskID: UUID,
        state: TaskState,
        resultBuffer: ByteBuffer?,
        logger: Logger
    ) async throws {
        try await conn.query(
            """
            WITH
            ins_completion AS (
                INSERT INTO strand.task_completions (namespace_id, task_id, state, result)
                VALUES (\(namespaceID), \(taskID), \(state), \(resultBuffer))
                ON CONFLICT (task_id) DO NOTHING
            ),
            flag_running AS (
                -- Parent is RUNNING (mid-activation): set has_buffered_completion so
                -- the parent's step-7 withTransaction detects the child at the end of
                -- its current activation and transitions to PENDING.
                -- The parent's activation holds the runs row lock — do NOT try to
                -- modify runs.state here to avoid lock-order conflicts.
                UPDATE strand.runs r
                SET    has_buffered_completion = TRUE
                FROM   strand.event_waits ew
                WHERE  ew.child_task_id = \(taskID)
                  AND  r.id             = ew.run_id
                  AND  r.state          = \(TaskState.running)
                  AND  r.namespace_id   = \(namespaceID)
            ),
            notif AS (
                -- Collect the parent queue for WAITING/SLEEPING parents so workers
                -- can run wakeCompletedWaiting and transition them to PENDING.
                -- RUNNING parents are excluded: step-7's deferred notifyWorkers fires
                -- after its own transaction commits.
                SELECT r.queue, r.namespace_id
                FROM   strand.event_waits ew
                JOIN   strand.runs r ON r.id = ew.run_id
                WHERE  ew.child_task_id = \(taskID)
                  AND  r.state IN (\(TaskState.waiting), \(TaskState.sleeping))
                  AND  r.namespace_id   = \(namespaceID)
                LIMIT 1
            )
            SELECT pg_notify(\(StrandChannels.tasks), namespace_id || '/' || queue)
            FROM notif
            """,
            logger: logger
        )
    }

    /// Transitions WAITING workflow runs to PENDING when their child activities have
    /// completed.  Called from each worker's poll loop immediately before `claimTasks`.
    ///
    /// A WAITING run has no active activation, so there is no concurrent writer:
    /// this is the only code path that makes WAITING → PENDING transitions.
    /// `FOR UPDATE SKIP LOCKED` lets multiple workers process different runs in
    /// parallel without contention.
    static func wakeCompletedWaiting(
        on client: PostgresClient,
        namespaceID: String,
        queue: String,
        logger: Logger
    ) async throws {
        let stream = try await client.query(
            """
            WITH
            to_wake AS (
                -- WAITING runs that have at least one event_wait child already in
                -- task_completions — the child completed but the parent was not
                -- immediately transitioned (e.g. was RUNNING at completion time).
                -- EXISTS is used instead of JOIN so that FOR UPDATE works without
                -- a DISTINCT clause (Postgres forbids FOR UPDATE + DISTINCT).
                SELECT r.id AS run_id, r.task_id
                FROM   strand.runs r
                WHERE  r.namespace_id = \(namespaceID)
                  AND  r.queue        = \(queue)
                  AND  r.state        = \(TaskState.waiting)
                  AND  r.created_at  >= DATE_TRUNC('month', NOW()) - INTERVAL '1 month'
                  AND  EXISTS (
                      SELECT 1
                      FROM   strand.event_waits ew
                      JOIN   strand.task_completions tc ON tc.task_id = ew.child_task_id
                      WHERE  ew.run_id        = r.id
                        AND  ew.child_task_id IS NOT NULL
                  )
                ORDER BY r.id
                LIMIT 50
                FOR UPDATE SKIP LOCKED
            ),
            woken AS (
                UPDATE strand.runs
                SET state        = \(TaskState.pending),
                    available_at = NOW(),
                    lease_expires_at = NULL
                FROM to_wake
                WHERE strand.runs.id = to_wake.run_id
                RETURNING to_wake.run_id, to_wake.task_id
            )
            UPDATE strand.tasks
            SET state = \(TaskState.pending)
            FROM woken
            WHERE strand.tasks.id           = woken.task_id
              AND strand.tasks.namespace_id = \(namespaceID)
            RETURNING woken.run_id
            """,
            logger: logger
        )
        var count = 0
        for try await _ in stream { count += 1 }
        if count > 0 {
            logger.debug(
                "woke \(count) WAITING run(s) with completed children",
                metadata: ["strand.queue": .string(queue)]
            )
        }
    }
}

// MARK: - Internal helpers

/// Computes the retry delay from the task's encoded retry strategy.
private func retryDelay(strategy buf: ByteBuffer?, attempt: Int) -> TimeInterval {
    guard let buf, let s = try? JSON.decode(RetryStrategy.self, from: buf) else { return 0 }
    let initial = Double(s.initialDelay.components.seconds)
    let cap = Double(s.maxDelay.components.seconds)
    guard initial > 0 || cap > 0 else { return 0 }
    return Swift.min(initial * pow(s.multiplier, Double(Swift.max(attempt - 1, 0))), cap)
}

struct QueryError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { self.description = msg }
}

// MARK: - Worker notification helpers

extension PostgresConnection {
    /// Sends a `pg_notify` on `strand_tasks` for the given `(namespace, queue)` pair.
    ///
    /// `pg_notify` is transactional — the notification is delivered only after the
    /// enclosing transaction commits, so callers inside a `withTransaction` block
    /// never produce phantom wakeups for tasks that haven't landed yet.
    func notifyWorkers(namespace: String, queue: String, logger: Logger) async throws {
        let notification = StrandChannels.Notification(namespace: namespace, queue: queue)
        try await query(
            "SELECT pg_notify(\(StrandChannels.tasks), \(notification.payload))",
            logger: logger
        )
    }
}

extension PostgresClient {
    /// Pool-level convenience — acquires a connection then delegates to
    /// ``PostgresConnection/notifyWorkers(namespace:queue:logger:)``.
    func notifyWorkers(namespace: String, queue: String, logger: Logger) async throws {
        try await withConnection { conn in
            try await conn.notifyWorkers(namespace: namespace, queue: queue, logger: logger)
        }
    }
}
