-- Srand — Postgres-native durable workflow engine
-- ─────────────────────────────────────────────────────────────────────────────
-- Fresh-install schema. Apply once against an empty database:
--
--   psql "$DATABASE_URL" -f strand.sql
--
-- Conventions:
--   • All JSON stored as BYTEA — encoded/decoded in Swift, never parsed by Postgres.
--   • Primary keys are UUIDs generated client-side as UUIDv7 (time-ordered),
--     keeping B-tree inserts sequential and reducing page splits.
--   • State values are UPPERCASE strings: 'PENDING', 'RUNNING', etc.
--   • `kind` distinguishes orchestrators ('WORKFLOW') from leaf work ('ACTIVITY').
--   • `namespace_id` scopes every row to a logical tenant. All queries must
--     include namespace_id. Indexes follow namespace_id
--     is the first column in every composite index.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE SCHEMA IF NOT EXISTS strand;

-- ─────────────────────────────────────────────────────────────────────────────
-- Namespaces — top-level isolation boundary.
--
-- Provides hard data isolation between tenants. Every execution table carries
-- namespace_id so queries can be scoped, retention policies applied, and
-- resource limits enforced per namespace.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS strand.namespaces (
    id             TEXT        NOT NULL,   -- slug: "default", "acme-corp", "team-payments"
    display_name   TEXT,
    retention_days INTEGER     NOT NULL DEFAULT 30,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_namespaces_pkey PRIMARY KEY (id)
);

-- Every fresh install gets a default namespace.
INSERT INTO strand.namespaces (id, display_name) VALUES ('default', 'Default') ON CONFLICT DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- Queue registry
-- One row per (namespace, queue) pair. Created by workers at startup.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS strand.queues (
    namespace_id TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id),
    name         TEXT        NOT NULL,
    is_paused    BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_queues_pkey PRIMARY KEY (namespace_id, name)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Tasks — the logical unit of work.
-- Append-mostly; rows are created at enqueue time and updated as state changes.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS strand.tasks (
    id           UUID        NOT NULL,
    namespace_id TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id),
    queue        TEXT        NOT NULL,
    name         TEXT        NOT NULL,   -- registered workflow/activity name

    -- Payloads: BYTEA blobs, never parsed by Postgres.
    params               BYTEA       NOT NULL,
    headers              BYTEA,
    scheduling_metadata  BYTEA,      -- NULL for directly-enqueued tasks; set by StrandScheduler
    retry_strategy       BYTEA,
    cancellation         BYTEA,

    max_attempts    INTEGER,
    timeout_seconds INTEGER,                  -- per-attempt execution cap in seconds; NULL = worker's claimTimeout
    idempotency_key TEXT,

    -- Dispatch routing
    priority        INTEGER     NOT NULL DEFAULT 3,   -- 1 (critical) … 5 (minimal)
    fairness_key    TEXT,                             -- tenant/group key for weighted dispatch
    fairness_weight FLOAT       NOT NULL DEFAULT 1.0, -- throughput weight relative to 1.0

    -- Execution classification
    kind            TEXT        NOT NULL DEFAULT 'WORKFLOW',
    --   'WORKFLOW'  — top-level orchestrator, enqueued directly by the client
    --   'ACTIVITY'  — leaf unit of work, spawned by a workflow via runActivity
    parent_task_id  UUID,  -- NULL for root; set when spawned by runActivity / runChildWorkflow

    -- Lifecycle
    state        TEXT        NOT NULL DEFAULT 'PENDING',
    attempt      INTEGER     NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    first_run_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,
    -- maxDuration: hard wall-clock deadline across all attempts.
    -- failRun refuses to retry after this timestamp regardless of remaining maxAttempts.
    -- claimTasks skips tasks past this deadline so workers never start doomed work.
    deadline_at  TIMESTAMPTZ,
    result       BYTEA,                  -- JSON-encoded success payload

    CONSTRAINT strand_tasks_pkey            PRIMARY KEY (id),
    -- FK to strand.queues: tasks are always in a registered queue.
    -- ON DELETE CASCADE means dropping a queue removes all its tasks,
    -- which then cascades to runs, checkpoints, history, state, and signals.
    CONSTRAINT strand_tasks_queue_fk        FOREIGN KEY (namespace_id, queue)
                                            REFERENCES strand.queues(namespace_id, name)
                                            ON DELETE CASCADE,
    CONSTRAINT strand_tasks_idempotency_key UNIQUE (namespace_id, queue, idempotency_key),
    CONSTRAINT strand_tasks_kind            CHECK (kind IN ('WORKFLOW', 'ACTIVITY')),
    CONSTRAINT strand_tasks_state           CHECK (state IN (
        'PENDING', 'RUNNING', 'SLEEPING', 'WAITING', 'COMPLETED', 'FAILED', 'CANCELLED'
    ))
);

-- Hot management path: namespace_id first
CREATE INDEX IF NOT EXISTS strand_tasks_ns_queue_state_idx
    ON strand.tasks (namespace_id, queue, state);

-- Kind-filtered queries (Workflows page, Activities page)
CREATE INDEX IF NOT EXISTS strand_tasks_ns_kind_idx
    ON strand.tasks (namespace_id, queue, kind, state);

-- Most-recent-first task list (new API sort order)
CREATE INDEX IF NOT EXISTS strand_tasks_ns_id_desc_idx
    ON strand.tasks (namespace_id, queue, id DESC)
    WHERE state NOT IN ('COMPLETED', 'FAILED', 'CANCELLED');

-- Parent-child lineage: "show all activities spawned by this workflow"
CREATE INDEX IF NOT EXISTS strand_tasks_parent_idx
    ON strand.tasks (parent_task_id)
    WHERE parent_task_id IS NOT NULL;

-- Skips tasks past their maxDuration deadline in claimTasks.
CREATE INDEX IF NOT EXISTS strand_tasks_deadline_idx
    ON strand.tasks (namespace_id, queue, deadline_at)
    WHERE deadline_at IS NOT NULL AND state = 'PENDING';

-- ── Historic / metrics queries on terminal states ────────────────────────────
--
-- Partial indexes scoped to each terminal state so historic queries (dashboard
-- metrics, task list, cleanup) never touch live-task pages. Each index is
-- ordered by its natural completion timestamp so range scans are efficient.
--
-- Without these, every MetricsRoutes or ManagementQueries call that filters on
-- a terminal state must scan the full strand.tasks table.

CREATE INDEX IF NOT EXISTS strand_tasks_completed_at_idx
    ON strand.tasks (namespace_id, queue, completed_at DESC)
    WHERE state = 'COMPLETED' AND completed_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS strand_tasks_cancelled_at_idx
    ON strand.tasks (namespace_id, queue, cancelled_at DESC)
    WHERE state = 'CANCELLED' AND cancelled_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS strand_tasks_failed_idx
    ON strand.tasks (namespace_id, queue, created_at DESC)
    WHERE state = 'FAILED';

-- ── Storage / autovacuum tuning ───────────────────────────────────────────────
--
-- fillfactor = 85: reserves 15 % of each heap page for in-place rewrites.
-- When `state` changes (PENDING → RUNNING → COMPLETED) Postgres performs a
-- HOT (Heap-Only Tuple) update — the new row version stays on the same page,
-- no index entries are rewritten, and index bloat is prevented.
--
-- Aggressive autovacuum: the state column changes on every task execution, so
-- dead tuples accumulate quickly. A 2 % scale factor and 1 ms cost delay keep
-- the table lean without holding back normal work.
ALTER TABLE strand.tasks SET (
    fillfactor                          = 85,
    autovacuum_vacuum_scale_factor      = 0.02,
    autovacuum_vacuum_threshold         = 50,
    autovacuum_analyze_scale_factor     = 0.02,
    autovacuum_analyze_threshold        = 100,
    autovacuum_vacuum_cost_limit        = 2000,
    autovacuum_vacuum_cost_delay        = 1
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Runs — individual execution attempts.
-- High churn: rows transition through states frequently.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS strand.runs (
    id           UUID    NOT NULL,
    namespace_id TEXT    NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id),
    task_id      UUID    NOT NULL REFERENCES strand.tasks(id) ON DELETE CASCADE,
    queue        TEXT    NOT NULL,   -- denormalised for fast claim query
    attempt      INTEGER NOT NULL,

    -- Optimistic concurrency: incremented on every state transition.
    -- completeRun / failRun must CAS on (id, state, version) to prevent
    -- double-execution when multiple workers race (e.g. after lease expiry).
    version      BIGINT  NOT NULL DEFAULT 0,

    state            TEXT        NOT NULL DEFAULT 'PENDING',
    worker_id        TEXT,
    lease_expires_at TIMESTAMPTZ,
    available_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Re-activation metadata (set when woken from an event wait)
    wake_event    TEXT,
    event_payload BYTEA,

    failure_reason BYTEA,

    -- Inherited from strand.tasks at run creation
    priority        INTEGER     NOT NULL DEFAULT 3,
    fairness_key    TEXT,
    fairness_weight FLOAT       NOT NULL DEFAULT 1.0,
    kind            TEXT        NOT NULL DEFAULT 'WORKFLOW',
    parent_task_id  UUID,

    started_at  TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT strand_runs_pkey  PRIMARY KEY (id),
    CONSTRAINT strand_runs_kind  CHECK (kind IN ('WORKFLOW', 'ACTIVITY')),
    CONSTRAINT strand_runs_state CHECK (state IN (
        'PENDING', 'RUNNING', 'SLEEPING', 'WAITING', 'COMPLETED', 'FAILED', 'CANCELLED'
    ))
);

-- strand.runs is the highest-churn table: attempt, state, lease_expires_at,
-- started_at and finished_at all change on every execution. fillfactor = 80
-- gives extra headroom for HOT updates. autovacuum is more aggressive than the
-- Postgres default (5 % scale factor) to keep dead-tuple accumulation in check.
ALTER TABLE strand.runs SET (
    fillfactor                      = 80,
    autovacuum_vacuum_scale_factor  = 0.05,
    autovacuum_analyze_scale_factor = 0.02,
    autovacuum_vacuum_threshold     = 50,
    autovacuum_analyze_threshold    = 50,
    autovacuum_vacuum_cost_delay    = 2
);

-- Hot claim path: namespace_id first, then priority ASC so critical tasks are never starved.
CREATE INDEX IF NOT EXISTS strand_runs_claim_idx
    ON strand.runs (namespace_id, queue, priority ASC, available_at, id)
    WHERE state IN ('PENDING', 'SLEEPING');

-- Supports the correlated NOT EXISTS subquery in claimTasks that enforces FIFO
-- within a fairness key. Without this index the subquery degrades to a range scan
-- over all PENDING/SLEEPING rows in the queue at high queue depth.
CREATE INDEX IF NOT EXISTS strand_runs_fairness_idx
    ON strand.runs (namespace_id, queue, fairness_key, available_at, priority, id)
    WHERE state = ANY (ARRAY['PENDING'::text, 'SLEEPING'::text])
      AND fairness_key IS NOT NULL;

-- Added `queue` so leaseExpiryLoop seeks directly to the right queue instead of
-- scanning all expired leases in the namespace and filtering as a recheck.
CREATE INDEX IF NOT EXISTS strand_runs_lease_idx
    ON strand.runs (namespace_id, queue, lease_expires_at)
    WHERE state = 'RUNNING'::text AND lease_expires_at IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- Checkpoints — sideEffect() / replay cache within a workflow activation.
-- Keyed by (task_id, seq_num). Read at activation start; bypassed when hit.
-- seq_num is a monotonic integer counter per workflow task,
-- every checkpoint-producing operation gets a
-- unique integer identity regardless of operation type.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS strand.checkpoints (
    namespace_id TEXT        NOT NULL DEFAULT 'default',
    task_id      UUID        NOT NULL REFERENCES strand.tasks(id) ON DELETE CASCADE,
    seq_num      INTEGER     NOT NULL,                  -- global activation counter;
    name         TEXT,                                  -- optional human-readable label for debugging only
    state        BYTEA       NOT NULL,                  -- JSON-encoded cached value
    run_id       UUID        NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_checkpoints_pkey PRIMARY KEY (task_id, seq_num)
);

CREATE INDEX IF NOT EXISTS strand_checkpoints_ns_idx
    ON strand.checkpoints (namespace_id, task_id, seq_num);

-- ─────────────────────────────────────────────────────────────────────────────
-- Events — append-only emission log.
-- Each call to ctx.emitEvent / StrandClient.emitEvent inserts a new row with a
-- UUIDv7 id. Rows are never overwritten; the "latest value" is the row with the
-- highest created_at DESC for a given (namespace_id, queue, name) triple.
-- Used by ctx.waitForEvent / ctx.emitEvent.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS strand.events (
    id           UUID        NOT NULL,  -- UUIDv7, always generated by Swift via UUID.v7()
    namespace_id TEXT        NOT NULL DEFAULT 'default',
    queue        TEXT        NOT NULL,
    name         TEXT        NOT NULL,
    payload      BYTEA,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_events_pkey PRIMARY KEY (id)
);

-- Fast lookup: awaitEvent fast-path ("is there already an emission for this name?")
-- and the events page list (ordered newest first per name).
CREATE INDEX IF NOT EXISTS strand_events_name_idx
    ON strand.events (namespace_id, queue, name, created_at DESC);

-- One row per (event emission → task woken) pair.
-- emission_id links back to the specific strand.events row that caused this wake.
-- Pruned automatically via ON DELETE CASCADE when the task is deleted by StrandPruner.
CREATE TABLE IF NOT EXISTS strand.event_triggers (
    id           UUID        NOT NULL,  -- UUIDv7, always generated by Swift via UUID.v7()
    namespace_id TEXT        NOT NULL DEFAULT 'default',
    queue        TEXT        NOT NULL,
    event_name   TEXT        NOT NULL,
    emission_id  UUID        REFERENCES strand.events(id) ON DELETE SET NULL,
    task_id      UUID        NOT NULL REFERENCES strand.tasks(id) ON DELETE CASCADE,
    run_id       UUID        NOT NULL,
    triggered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_event_triggers_pkey PRIMARY KEY (id)
);

-- Fast lookup: "which tasks did event X trigger?" (used by the events page)
CREATE INDEX IF NOT EXISTS strand_event_triggers_event_idx
    ON strand.event_triggers (namespace_id, queue, event_name, triggered_at DESC);

-- Reverse lookup: "which event triggered task Y?" (task detail → event link)
CREATE INDEX IF NOT EXISTS strand_event_triggers_task_idx
    ON strand.event_triggers (task_id);

-- Forward lookup: "which tasks were woken by this specific emission?"
CREATE INDEX IF NOT EXISTS strand_event_triggers_emission_idx
    ON strand.event_triggers (emission_id)
    WHERE emission_id IS NOT NULL;

-- Uniqueness guard: one trigger row per (emission, task) pair.
-- Prevents duplicate rows when applyScheduleCommands fast-path re-fires for
-- the same emission after a run retries (fresh _activate re-processes .awaitEvent).
-- Partial (WHERE emission_id IS NOT NULL) because emission_id is nullable for
-- pre-migration rows that pre-date the append-only log.
-- Migration note: if existing duplicate rows block index creation, delete them first:
--   DELETE FROM strand.event_triggers a USING strand.event_triggers b
--   WHERE a.id > b.id AND a.emission_id = b.emission_id
--     AND a.task_id = b.task_id AND a.emission_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS strand_event_triggers_emission_task_idx
    ON strand.event_triggers (emission_id, task_id)
    WHERE emission_id IS NOT NULL;

-- Migration for existing databases:
-- ALTER TABLE strand.events DROP CONSTRAINT strand_events_pkey;
-- ALTER TABLE strand.events ADD COLUMN id UUID;
-- UPDATE strand.events SET id = gen_random_uuid() WHERE id IS NULL;
-- ALTER TABLE strand.events ALTER COLUMN id SET NOT NULL;
-- ALTER TABLE strand.events ADD CONSTRAINT strand_events_pkey PRIMARY KEY (id);
-- CREATE INDEX IF NOT EXISTS strand_events_name_idx ON strand.events (namespace_id, queue, name, created_at DESC);
-- ALTER TABLE strand.event_triggers ADD COLUMN IF NOT EXISTS emission_id UUID REFERENCES strand.events(id) ON DELETE SET NULL;
-- CREATE INDEX IF NOT EXISTS strand_event_triggers_emission_idx ON strand.event_triggers (emission_id) WHERE emission_id IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- Event waits — runs suspended waiting for a named event.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS strand.event_waits (
    namespace_id  TEXT        NOT NULL DEFAULT 'default',
    task_id       UUID        NOT NULL REFERENCES strand.tasks(id) ON DELETE CASCADE,
    run_id        UUID        NOT NULL REFERENCES strand.runs(id) ON DELETE CASCADE,
    queue         TEXT        NOT NULL,
    seq_num       INTEGER     NOT NULL,
    -- Named-event waits (context.waitForEvent): event_name is non-null, child_task_id is null.
    -- Task-completion waits (runActivity / runChildWorkflow): child_task_id is non-null, event_name is null.
    -- The two are mutually exclusive; exactly one is non-null per row.
    event_name    TEXT,
    child_task_id UUID        REFERENCES strand.tasks(id) ON DELETE CASCADE,
    timeout_at    TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_event_waits_pkey PRIMARY KEY (run_id, seq_num)
);

-- Wake-up lookup by named event (waitForEvent path).
CREATE INDEX IF NOT EXISTS strand_event_waits_event_idx
    ON strand.event_waits (namespace_id, queue, event_name);

-- Wake-up lookup by child task ID (runActivity / runChildWorkflow completion path).
CREATE INDEX IF NOT EXISTS strand_event_waits_child_task_idx
    ON strand.event_waits (child_task_id) WHERE child_task_id IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- Task completions — permanent terminal record for every finished task.
--
-- Written atomically with completeRun / failRun / cancelTask.
-- Read by runActivity / awaitActivity to handle the race where a child
-- completes before the parent registers its event wait.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS strand.task_completions (
    namespace_id TEXT        NOT NULL DEFAULT 'default',
    task_id      UUID        NOT NULL REFERENCES strand.tasks(id) ON DELETE CASCADE,
    state        TEXT        NOT NULL,   -- 'COMPLETED' | 'FAILED' | 'CANCELLED'
    result       BYTEA,
    completed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_task_completions_pkey PRIMARY KEY (task_id)
);

-- Namespace-scoped completion lookups (used by management queries and UI)
CREATE INDEX IF NOT EXISTS strand_task_completions_ns_idx
    ON strand.task_completions (namespace_id, completed_at DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- Workflow state — serialised @Workflow struct persisted between activations.
--
-- Loaded at activation start so the handler resumes with the correct state.
-- Updated atomically with each run completion.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS strand.workflow_state (
    namespace_id TEXT        NOT NULL DEFAULT 'default',
    task_id      UUID        NOT NULL REFERENCES strand.tasks(id) ON DELETE CASCADE,
    state        BYTEA       NOT NULL,  -- JSON-encoded @Workflow struct
    state_seq    BIGINT      NOT NULL DEFAULT 0,  -- monotonic; updated each activation
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_workflow_state_pkey PRIMARY KEY (task_id)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Workflow signals — inbox for externally-delivered signals.
--
-- Inserted by client.signal(...) / handle.signal(...).
-- Drained and applied to the workflow struct at the start of each activation.
-- Deleted after application.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS strand.workflow_signals (
    id           UUID        NOT NULL DEFAULT gen_random_uuid(),
    seq          BIGSERIAL   NOT NULL,   -- monotonic total order, unaffected by transaction commit ordering
    namespace_id TEXT        NOT NULL DEFAULT 'default',
    task_id      UUID        NOT NULL REFERENCES strand.tasks(id) ON DELETE CASCADE,
    signal_name  TEXT        NOT NULL,
    payload      BYTEA,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_workflow_signals_pkey PRIMARY KEY (id)
);

-- Ordered drain: namespace_id first, then arrival order via monotonic sequence.
-- BIGSERIAL seq is allocated at INSERT time (not commit time), giving a causal
-- total order even when two concurrent transactions commit in the wrong wall-clock order.
CREATE INDEX IF NOT EXISTS strand_workflow_signals_inbox_idx
    ON strand.workflow_signals (namespace_id, task_id, seq ASC);

-- ─────────────────────────────────────────────────────────────────────────────
-- Workflow history — append-only event log per workflow execution.
--
-- Every significant decision (activity scheduled, activity completed, signal
-- received, timer fired, workflow completed, …) is appended here.
-- Used by the UI timeline and future workflow-reset functionality.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS strand.workflow_history (
    namespace_id TEXT        NOT NULL DEFAULT 'default',
    task_id      UUID        NOT NULL REFERENCES strand.tasks(id) ON DELETE CASCADE,
    seq          BIGINT      NOT NULL,  -- 1-based monotonic per workflow
    event_type   TEXT        NOT NULL,  -- 'WORKFLOW_STARTED' | 'ACTIVITY_SCHEDULED' |
                                        -- 'ACTIVITY_COMPLETED' | 'SIGNAL_RECEIVED' |
                                        -- 'TIMER_FIRED' | 'CHILD_WORKFLOW_STARTED' |
                                        -- 'WORKFLOW_COMPLETED' | 'WORKFLOW_FAILED' | …
    event_data   BYTEA,                 -- JSON payload; schema depends on event_type
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_workflow_history_pkey PRIMARY KEY (task_id, seq)
);

-- Namespace-scoped history scan (UI timeline, reset, audit)
CREATE INDEX IF NOT EXISTS strand_workflow_history_ns_idx
    ON strand.workflow_history (namespace_id, task_id, seq ASC);



-- ────────────────────────────────────────────────────────────────────────────────────
-- Schedules — cron/interval/one-shot task triggers.
-- Polled by StrandScheduler. Fires WORKFLOW or ACTIVITY tasks into strand.tasks when due.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS strand.schedules (
    id           UUID        NOT NULL,
    namespace_id TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id),
    queue        TEXT        NOT NULL,
    name         TEXT        NOT NULL,   -- human-readable; unique per (namespace, queue)
    task_name    TEXT        NOT NULL,   -- registered workflow name to fire

    params         BYTEA       NOT NULL,  -- JSON-encoded workflow input
    headers        BYTEA,
    pattern        BYTEA       NOT NULL,  -- JSON-encoded SchedulePattern
    retry_strategy BYTEA,
    cancellation   BYTEA,
    max_attempts   INTEGER,
    accuracy       TEXT        NOT NULL DEFAULT 'latest',
    kind           TEXT        NOT NULL DEFAULT 'WORKFLOW',  -- 'WORKFLOW' or 'ACTIVITY'

    -- Airflow-style lifecycle
    starts_at TIMESTAMPTZ,  -- NULL = active immediately
    ends_at   TIMESTAMPTZ,  -- NULL = runs indefinitely

    -- StandScheduler execution state
    is_active    BOOLEAN     NOT NULL DEFAULT TRUE,
    next_run_at  TIMESTAMPTZ,
    last_run_at  TIMESTAMPTZ,   -- wall-clock time of the most recent fire (for display)
    last_slot_at TIMESTAMPTZ,   -- scheduled slot time of the most recent fire (for catch-up base)
    last_task_id UUID,
    run_count    INTEGER     NOT NULL DEFAULT 0,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT strand_schedules_pkey       PRIMARY KEY (id),
    CONSTRAINT strand_schedules_ns_name    UNIQUE (namespace_id, queue, name)
);

-- Scheduler poll: namespace_id first, only active schedules with upcoming fire time
CREATE INDEX IF NOT EXISTS strand_schedules_due_idx
    ON strand.schedules (namespace_id, next_run_at)
    WHERE is_active = TRUE AND next_run_at IS NOT NULL;

-- ───────────────────────────────────────────────────────────────────────────────
-- Workers — ephemeral runtime heartbeat table.
--
-- Each StrandWorker instance upserts one row per queue on startup and
-- refreshes updated_at on every heartbeat cycle. A background sweeper deletes
-- rows older than 2×heartbeat_interval so stale entries are self-cleaning.
--
-- UNLOGGED: no WAL writes at all — as fast as writing to a local file.
-- On crash the table is truncated, which is fine: workers re-register on the
-- next startup. This table is never replicated to standbys.
--
-- Dashboard and management queries read from here to show live queue health
-- (running, concurrency, paused) without scanning strand.runs.
-- ───────────────────────────────────────────────────────────────────────────────

CREATE UNLOGGED TABLE IF NOT EXISTS strand.workers (
    id           TEXT        NOT NULL,    -- "<hostname>:<pid>"
    namespace_id TEXT        NOT NULL DEFAULT 'default',
    queue        TEXT        NOT NULL,
    concurrency  INTEGER     NOT NULL,    -- configured workflowConcurrency + activityConcurrency
    running      INTEGER     NOT NULL DEFAULT 0,   -- currently executing tasks
    paused       BOOLEAN     NOT NULL DEFAULT FALSE,
    started_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_workers_pkey PRIMARY KEY (id, namespace_id, queue)
);

-- Live queue health lookup from the Workers dashboard page.
CREATE INDEX IF NOT EXISTS strand_workers_ns_queue_idx
    ON strand.workers (namespace_id, queue);

-- ───────────────────────────────────────────────────────────────────────────────
-- Count estimate — fast approximate row counts for large tables.
--
-- Uses the query planner’s own statistics (updated by autovacuum ANALYZE) to
-- return an estimate in sub-millisecond time without a sequential scan.
-- The planner estimate is typically within 5–10 % of the real count once
-- autovacuum has run; for dashboard displays this is more than accurate enough.
--
-- Usage:
--   SELECT strand.count_estimate('default', 'reports', 'PENDING');
--
-- Complement with exact COUNT(*) when the estimate returns < 50,000
-- (planner statistics are less reliable for small tables).
-- ───────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION strand.count_estimate(
    ns   TEXT,
    q    TEXT,
    st   TEXT
) RETURNS BIGINT AS $$
DECLARE
    plan JSONB;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON)
        SELECT id FROM strand.tasks
        WHERE namespace_id = $1
          AND queue        = $2
          AND state        = $3'
        INTO plan
        USING ns, q, st;
    RETURN (plan -> 0 -> 'Plan' ->> 'Plan Rows')::BIGINT;
END;
$$ LANGUAGE plpgsql;
