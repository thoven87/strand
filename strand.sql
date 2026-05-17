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

-- pgcrypto: required by strand.gen_uuid_v7() for gen_random_bytes().
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ─────────────────────────────────────────────────────────────────────────────
-- UUIDv7 generator (PostgreSQL < 18 compatibility shim)
--
-- PostgreSQL 18 shipped a built-in gen_uuid_v7(). This function provides the
-- same semantics for PostgreSQL 15–17 using pgcrypto's gen_random_bytes().
--
-- RFC 9562 layout:
--   bits  0-47  unix_ts_ms   48-bit millisecond timestamp (big-endian)
--   bits 48-51  ver          0b0111 (version 7)
--   bits 52-63  rand_a       12 random bits
--   bits 64-65  var          0b10   (RFC 4122 variant)
--   bits 66-127 rand_b       62 random bits
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION strand.gen_uuid_v7()
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    unix_ms BIGINT;
    rand_b  BYTEA;
BEGIN
    unix_ms := (extract(epoch FROM clock_timestamp()) * 1000)::BIGINT;
    rand_b  := gen_random_bytes(10);
    RETURN encode(
        -- bytes 0-5: 48-bit millisecond timestamp
        substring(int8send(unix_ms) FROM 3)
        -- bytes 6-7: version nibble 7 (0x7) || 12 random bits
        || set_byte(substring(rand_b FROM 1 FOR 2), 0,
                    (get_byte(rand_b, 0) & 15) | 112)
        -- bytes 8-15: variant 10xxxxxx || 62 random bits
        || set_byte(substring(rand_b FROM 3 FOR 8), 0,
                    (get_byte(rand_b, 2) & 63) | 128),
        'hex')::UUID;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Monthly partition helpers
--
-- strand.runs and strand.workflow_history are partitioned by created_at
-- (PARTITION BY RANGE). StrandPruner manages the lifecycle:
--   • create_range_partition — idempotent; called at startup and every 12 h.
--   • list_partitions_before — finds old partitions to detach and drop.
--
-- Naming convention: strand.<table>_<YYYYMM>  e.g. strand.runs_202601
--
-- IMPORTANT: Postgres autovacuum does NOT run ANALYZE on partitioned parent
-- tables — only on their child partitions. Without periodic manual ANALYZE on
-- strand.runs and strand.workflow_history the query planner produces wildly
-- wrong row estimates, causing sequential scans on the claim path under load.
-- StrandPruner.analyzeParentTables() calls ANALYZE on both parents every 12 h.
-- ─────────────────────────────────────────────────────────────────────────────

-- create_range_partition(base_table, month_start, fill_factor)
-- Creates a child table strand.<base_table>_<YYYYMM> covering one calendar month.
-- Returns TRUE if the partition was newly created, FALSE if it already existed.
CREATE OR REPLACE FUNCTION strand.create_range_partition(
    base_table  TEXT,
    month_start DATE,
    fill_factor INTEGER DEFAULT 80
) RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    suffix  TEXT := to_char(date_trunc('month', month_start), 'YYYYMM');
    p_name  TEXT := base_table || '_' || suffix;   -- e.g. 'runs_202601'
    p_from  TEXT := to_char(date_trunc('month', month_start), 'YYYY-MM-DD');
    p_to    TEXT := to_char(date_trunc('month', month_start)
                            + INTERVAL '1 month', 'YYYY-MM-DD');
BEGIN
    -- Idempotent: exit immediately if the partition already exists.
    IF EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'strand' AND c.relname = p_name
    ) THEN
        RETURN FALSE;
    END IF;

    -- Create the child table attached to the parent's partition set.
    EXECUTE format(
        'CREATE TABLE strand.%I PARTITION OF strand.%I
         FOR VALUES FROM (%L::TIMESTAMPTZ) TO (%L::TIMESTAMPTZ)',
        p_name, base_table, p_from, p_to
    );

    -- Mirror the storage/vacuum settings of the parent table.
    EXECUTE format(
        $fmt$ALTER TABLE strand.%I SET (
            fillfactor                      = %s,
            autovacuum_vacuum_scale_factor  = 0.05,
            autovacuum_vacuum_threshold     = 50,
            autovacuum_analyze_scale_factor = 0.02,
            autovacuum_analyze_threshold    = 50,
            autovacuum_vacuum_cost_delay    = 2,
            autovacuum_vacuum_cost_limit    = 2000
        )$fmt$,
        p_name, fill_factor
    );

    RETURN TRUE;
END;
$$;

-- drop_partition(base_table, partition_name)
-- Drops a partition that has already been detached (or drops it with plain
-- DETACH when CONCURRENTLY is not required).
-- Using format('%I') guarantees safe identifier quoting on the SQL side so
-- Swift callers do not need to build raw DDL strings.
--
-- NOTE: DETACH PARTITION CONCURRENTLY cannot run inside any PL/pgSQL block
-- (Postgres bans it in transaction contexts). Swift therefore calls DETACH via
-- a raw connection using PostgresQuery(unsafeSQL:) where the identifier values
-- are sourced exclusively from strand.list_partitions_before — a pg_inherits
-- system-catalog query, not from user input — so the raw-string approach is safe.
CREATE OR REPLACE FUNCTION strand.drop_partition(
    base_table     TEXT,
    partition_name TEXT
) RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    -- Plain DETACH (no CONCURRENTLY) — safe inside a function / transaction.
    -- Use this in dev environments or when lock contention is not a concern.
    -- Production callers should DETACH CONCURRENTLY first (from app code),
    -- then call this function to DROP the now-detached table.
    EXECUTE format('DROP TABLE IF EXISTS strand.%I', partition_name);
END;
$$;

-- list_partitions_before(base_table, cutoff_date)
-- Returns the names (without schema) of partitions for base_table whose
-- calendar month is strictly before cutoff_date.
-- Uses the naming convention <table>_<YYYYMM> inside the strand schema.
CREATE OR REPLACE FUNCTION strand.list_partitions_before(
    base_table  TEXT,
    cutoff_date DATE
) RETURNS TABLE (partition_name TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    parent_oid OID;
BEGIN
    SELECT c.oid INTO parent_oid
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'strand' AND c.relname = base_table;

    IF parent_oid IS NULL THEN RETURN; END IF;

    RETURN QUERY
    SELECT c.relname::TEXT
    FROM   pg_inherits i
    JOIN   pg_class c     ON c.oid = i.inhrelid
    JOIN   pg_namespace n ON n.oid = c.relnamespace
    WHERE  i.inhparent = parent_oid
      AND  n.nspname   = 'strand'
      -- Match naming convention: <base_table>_<YYYYMM>
      AND  c.relname ~ ('^' || base_table || '_\d{6}$')
      -- The YYYYMM suffix encodes the month; compare to cutoff
      AND  to_date(substring(c.relname FROM '\d{6}$'), 'YYYYMM') < cutoff_date;
END;
$$;

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
    heartbeat_timeout_seconds INTEGER,        -- max seconds between heartbeats; NULL = claimTimeout
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
    -- First task in a continueAsNew chain. NULL for the chain's first task and for all
    -- child tasks. Set only on root workflows spawned by context.continueAsNew().
    first_task_id   UUID,

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
    backfill_id  UUID,                  -- set when fired by StrandScheduler.processBackfills; FK added below

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
        'PENDING', 'RUNNING', 'SLEEPING', 'WAITING', 'COMPLETED', 'FAILED', 'CANCELLED',
        'CONTINUED_AS_NEW'
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
    WHERE state NOT IN ('COMPLETED', 'FAILED', 'CANCELLED', 'CONTINUED_AS_NEW');

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

CREATE INDEX IF NOT EXISTS strand_tasks_continued_as_new_idx
    ON strand.tasks (namespace_id, queue, completed_at DESC)
    WHERE state = 'CONTINUED_AS_NEW' AND completed_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS strand_tasks_first_task_idx
    ON strand.tasks (first_task_id)
    WHERE first_task_id IS NOT NULL;

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

-- strand.runs is partitioned RANGE by created_at (monthly buckets).
--
-- The PRIMARY KEY is (id, created_at) — Postgres requires the partition key
-- to be part of every unique constraint on a partitioned table.
-- A separate non-unique index on id alone (strand_runs_id_idx) keeps
-- point-lookups fast when only the UUID is known (completeRun, failRun, etc.).
--
-- FK note: strand.event_waits formerly had run_id REFERENCES strand.runs(id)
-- ON DELETE CASCADE. That FK cannot reference a non-PK column on a partitioned
-- table, so it is declared as a plain column (no FK). Application code and the
-- cascade-drop via partition DROP TABLE maintain the invariant in practice.
CREATE TABLE IF NOT EXISTS strand.runs (
    id           UUID    NOT NULL,
    namespace_id TEXT    NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id),
    task_id      UUID    NOT NULL,   -- logical FK to strand.tasks(id); no DB constraint (see above)
    queue        TEXT    NOT NULL,   -- denormalised for fast claim query
    attempt      INTEGER NOT NULL,

    -- Optimistic concurrency: incremented on every state transition.
    -- completeRun / failRun must CAS on (id, state, version) to prevent
    -- double-execution when multiple workers race (e.g. after lease expiry).
    version      BIGINT  NOT NULL DEFAULT 0,

    state            TEXT        NOT NULL DEFAULT 'PENDING',
    worker_id        TEXT,
    sdk_version      TEXT,        -- Strand SDK version of the worker that claimed this run
    has_buffered_completion BOOLEAN NOT NULL DEFAULT FALSE,  -- set by emitTaskCompletionSignal when parent is RUNNING
    lease_expires_at TIMESTAMPTZ,
    available_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Re-activation metadata (set when woken from an event wait)
    wake_event    TEXT,
    event_payload BYTEA,

    -- Last heartbeat payload written by context.heartbeat(_:).
    -- Loaded into ClaimedTask on the next attempt so the activity can resume
    -- exactly where it left off. NULL until the activity first calls heartbeat(_:).
    heartbeat_details BYTEA,

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

    -- Composite PK includes created_at (the partition key).
    CONSTRAINT strand_runs_pkey  PRIMARY KEY (id, created_at),
    CONSTRAINT strand_runs_kind  CHECK (kind IN ('WORKFLOW', 'ACTIVITY')),
    CONSTRAINT strand_runs_state CHECK (state IN (
        'PENDING', 'RUNNING', 'SLEEPING', 'WAITING', 'COMPLETED', 'FAILED', 'CANCELLED'
    ))
) PARTITION BY RANGE (created_at);

-- Fast UUID point-lookup when created_at is not known.
-- Queries like completeRun / failRun use WHERE id = $runID; Postgres scans
-- the active partition indexes (typically 2-3 monthly partitions).
CREATE INDEX IF NOT EXISTS strand_runs_id_idx
    ON strand.runs (id);

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
    namespace_id TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id) ON DELETE CASCADE,
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
-- Workflow version markers — queryable projection of context.version(changeID:) calls.
--
-- Written in two paths:
--   1. First encounter of version(changeID:) — via the .recordVersionMarker
--      WorkflowCommand processed in applyScheduleCommands.
--   2. client.markVersion(...) — operator-driven migration tooling.
--
-- The canonical source of truth for replay is strand.checkpoints.
-- This table exists for observability and namespace-level migration queries:
--   SELECT task_id FROM strand.workflow_version_markers
--   WHERE namespace_id = 'default' AND change_id = 'v2-payment' AND value = false;
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS strand.workflow_version_markers (
    namespace_id TEXT        NOT NULL REFERENCES strand.namespaces(id) ON DELETE CASCADE,
    task_id      UUID        NOT NULL REFERENCES strand.tasks(id)      ON DELETE CASCADE,
    change_id    TEXT        NOT NULL,
    value        BOOLEAN     NOT NULL,
    marked_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_workflow_version_markers_pkey PRIMARY KEY (task_id, change_id)
);

-- Namespace-level migration query: find all tasks where change_id X = false.
CREATE INDEX IF NOT EXISTS strand_version_markers_migration_idx
    ON strand.workflow_version_markers (namespace_id, change_id, value);

-- ─────────────────────────────────────────────────────────────────────────────
-- Events — append-only emission log.
-- Each call to ctx.emitEvent / StrandClient.emitEvent inserts a new row with a
-- UUIDv7 id. Rows are never overwritten; the "latest value" is the row with the
-- highest created_at DESC for a given (namespace_id, queue, name) triple.
-- Used by ctx.waitForEvent / ctx.emitEvent.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS strand.events (
    id           UUID        NOT NULL,  -- UUIDv7, always generated by Swift via UUID.v7()
    namespace_id TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id) ON DELETE CASCADE,
    queue        TEXT        NOT NULL,
    name         TEXT        NOT NULL,
    -- JSONB: the only table in Strand that stores payload as JSONB rather than BYTEA.
    -- Justified exception: strand.events is content-routable (waitForEvent predicates
    -- use `payload @> predicate` at emission time), making JSONB the honest type.
    -- All other payload columns remain BYTEA per the project convention.
    payload      JSONB,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_events_pkey PRIMARY KEY (id)
);

-- Fast lookup: awaitEvent fast-path ("is there already an emission for this name?")
-- and the events page list (ordered newest first per name).
CREATE INDEX IF NOT EXISTS strand_events_name_idx
    ON strand.events (namespace_id, queue, name, created_at DESC);
-- GIN index enabling efficient `payload @> predicate` containment checks at
-- event emission time. Sparse: only non-trivial payloads (not empty object)
-- are indexed — most events have real content.
CREATE INDEX IF NOT EXISTS strand_events_payload_gin
    ON strand.events USING GIN (payload)
    WHERE payload IS NOT NULL AND payload <> '{}';

-- One row per (event emission → task woken) pair.
-- emission_id links back to the specific strand.events row that caused this wake.
-- Pruned automatically via ON DELETE CASCADE when the task is deleted by StrandPruner.
CREATE TABLE IF NOT EXISTS strand.event_triggers (
    id           UUID        NOT NULL,  -- UUIDv7, always generated by Swift via UUID.v7()
    namespace_id TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id) ON DELETE CASCADE,
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

-- ALTER TABLE strand.runs ADD COLUMN IF NOT EXISTS heartbeat_details BYTEA;
-- ALTER TABLE strand.tasks ADD COLUMN IF NOT EXISTS heartbeat_timeout_seconds INTEGER;
-- ALTER TABLE strand.tasks ADD COLUMN IF NOT EXISTS backfill_id UUID REFERENCES strand.backfills(id) ON DELETE SET NULL;
-- ALTER TABLE strand.backfills ADD COLUMN IF NOT EXISTS schedule_id UUID REFERENCES strand.schedules(id) ON DELETE SET NULL;

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
    namespace_id  TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id),
    task_id       UUID        NOT NULL REFERENCES strand.tasks(id) ON DELETE CASCADE,
    run_id        UUID        NOT NULL,   -- logical FK to strand.runs(id); no DB constraint (partitioned table)
    queue         TEXT        NOT NULL,
    seq_num       INTEGER     NOT NULL,
    -- Named-event waits (context.waitForEvent): event_name is non-null, child_task_id is null.
    -- Task-completion waits (runActivity / runChildWorkflow): child_task_id is non-null, event_name is null.
    -- The two are mutually exclusive; exactly one is non-null per row.
    event_name    TEXT,
    child_task_id UUID        REFERENCES strand.tasks(id) ON DELETE CASCADE,
    timeout_at    TIMESTAMPTZ,
    -- Equality filter stored as JSONB. At emission, Postgres evaluates
    -- `incoming_payload @> predicate` via GIN index — only matching waiters are woken.
    -- '{}' (empty object) matches any payload and is the default for un-predicated waits
    -- (auto-scoped typed events, string-based waitForEvent). A non-trivial predicate
    -- like {"approvalId": "abc-123"} filters to matching payloads only.
    predicate     JSONB NOT NULL DEFAULT '{}',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_event_waits_pkey PRIMARY KEY (run_id, seq_num)
);

-- Wake-up lookup by named event (waitForEvent path).
CREATE INDEX IF NOT EXISTS strand_event_waits_event_idx
    ON strand.event_waits (namespace_id, queue, event_name);

-- GIN index on predicate for efficient @> containment lookups at emission time.
-- Sparse: only non-trivial predicates ({} excluded) benefit from GIN. Rows with
-- the default '{}' are matched unconditionally by exact event_name lookup.
CREATE INDEX IF NOT EXISTS strand_event_waits_predicate_gin
    ON strand.event_waits USING GIN (predicate)
    WHERE predicate <> '{}';

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
    namespace_id TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id) ON DELETE CASCADE,
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
    namespace_id TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id) ON DELETE CASCADE,
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
    id           UUID        NOT NULL DEFAULT strand.gen_uuid_v7(),
    seq          BIGSERIAL   NOT NULL,   -- monotonic total order, unaffected by transaction commit ordering
    namespace_id TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id) ON DELETE CASCADE,
    task_id      UUID        NOT NULL REFERENCES strand.tasks(id) ON DELETE CASCADE,
    signal_name  TEXT        NOT NULL,
    payload      BYTEA,
    update_correlation_id TEXT,      -- non-NULL for @WorkflowUpdate signals; NULL for @WorkflowSignal
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_workflow_signals_pkey PRIMARY KEY (id)
);

-- Ordered drain: namespace_id first, then arrival order via monotonic sequence.
-- BIGSERIAL seq is allocated at INSERT time (not commit time), giving a causal
-- total order even when two concurrent transactions commit in the wrong wall-clock order.
CREATE INDEX IF NOT EXISTS strand_workflow_signals_inbox_idx
    ON strand.workflow_signals (namespace_id, task_id, seq ASC);

-- ─────────────────────────────────────────────────────────────────────────────
-- Workflow update results — stores the typed result (or error) of every
-- @WorkflowUpdate handler call so the caller can poll for it.
--
-- Separate from strand.events so update results never appear in Loom's
-- Events page (which shows only user-emitted ctx.emitEvent() rows).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS strand.workflow_updates (
    id              UUID        NOT NULL DEFAULT strand.gen_uuid_v7(),
    namespace_id    TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id) ON DELETE CASCADE,
    correlation_id  TEXT        NOT NULL,   -- UUID generated by the caller; unique per update
    task_id         UUID        NOT NULL REFERENCES strand.tasks(id) ON DELETE CASCADE,
    result          BYTEA,                  -- JSON-encoded Output on success (null on error)
    error           TEXT,                   -- validation error message (null on success)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_workflow_updates_pkey    PRIMARY KEY (id),
    CONSTRAINT strand_workflow_updates_corr_uk UNIQUE (namespace_id, correlation_id)
);

CREATE INDEX IF NOT EXISTS strand_workflow_updates_corr_idx
    ON strand.workflow_updates (namespace_id, correlation_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- Task logs — structured per-task log lines emitted by context.log(…).
--
-- Partitioned RANGE by created_at (monthly). No ON CONFLICT — log writes are
-- fire-and-forget. No FK to strand.tasks — partition DROP TABLE handles cleanup
-- automatically when StrandPruner drops expired months.
--
-- Powers the Loom "Logs" tab on the task detail page.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS strand.task_logs (
    id           UUID        NOT NULL DEFAULT strand.gen_uuid_v7(),
    namespace_id TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id),
    task_id      UUID        NOT NULL,   -- logical FK to strand.tasks(id); no DB constraint (partitioned)
    run_id       UUID        NOT NULL,   -- which run/attempt produced this entry
    level        TEXT        NOT NULL DEFAULT 'INFO',
    message      TEXT        NOT NULL,
    metadata     BYTEA,                  -- optional JSON key-value pairs
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT strand_task_logs_pkey  PRIMARY KEY (id, created_at),
    CONSTRAINT strand_task_logs_level CHECK (level IN ('DEBUG', 'INFO', 'WARN', 'ERROR'))
) PARTITION BY RANGE (created_at);

-- Task-scoped log scan (Loom Logs tab, newest-first).
CREATE INDEX IF NOT EXISTS strand_task_logs_task_idx
    ON strand.task_logs (namespace_id, task_id, created_at DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- Workflow history — append-only event log per workflow execution.
--
-- Every significant decision (activity scheduled, activity completed, signal
-- received, timer fired, workflow completed, …) is appended here.
-- Used by the UI timeline and future workflow-reset functionality.
-- ─────────────────────────────────────────────────────────────────────────────

-- strand.workflow_history is append-only and intentionally NOT partitioned.
--
-- Reason: batchAppendHistory uses ON CONFLICT (task_id, seq) DO NOTHING for
-- idempotency. Postgres requires that the ON CONFLICT target be a unique
-- constraint, and unique constraints on partitioned tables must include the
-- partition key. Adding created_at to the PK would break the ON CONFLICT
-- clause and allow duplicate (task_id, seq) rows in different partitions.
-- The table is append-only (no UPDATEs), so bloat accumulation is much lower
-- than strand.runs. Retention is handled by StrandPruner via DELETE cascaded
-- from strand.tasks (ON DELETE CASCADE FK is preserved).
CREATE TABLE IF NOT EXISTS strand.workflow_history (
    namespace_id TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id) ON DELETE CASCADE,
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

-- Storage / autovacuum tuning for workflow_history.
--
-- No fillfactor: this table is append-only (no UPDATEs). HOT update savings
-- only apply when the same row is updated in-place; reserving free space on
-- heap pages would just waste storage without reducing index churn.
--
-- Autovacuum is tuned aggressively because dead tuples arrive in bursts:
-- when StrandPruner CASCADE-DELETEs an old task, all its history rows die at
-- once. The default scale_factor=0.2 would let those dead tuples sit until
-- 20% of the table is dead; 0.05 triggers cleanup after each meaningful prune
-- cycle instead.
ALTER TABLE strand.workflow_history SET (
    autovacuum_vacuum_scale_factor  = 0.05,
    autovacuum_analyze_scale_factor = 0.05,
    autovacuum_vacuum_threshold     = 50,
    autovacuum_analyze_threshold    = 50,
    autovacuum_vacuum_cost_delay    = 2
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Trace spans — write-through OLAP table for the Loom trace and history views.
--
-- Written by the engine at every span lifecycle event (same transactions as the
-- transactional tables). The dashboard reads exclusively from this table:
--
--   /trace   → WHERE namespace_id=$1 AND root_task_id=$2 ORDER BY queued_at
--   /history → WHERE namespace_id=$1 AND task_id=$2 AND event_type IS NOT NULL ORDER BY seq_num
--
-- id format:
--   Task spans  : task_id.uuidString              (e.g. "019E2ED0-7891-...")
--   History spans: "\(taskID):\(seqNum)"          (e.g. "019E2ED0-7891-...:4")
--
-- root_task_id is the top-level workflow's task_id. For root tasks it equals
-- task_id. For children it is propagated from the parent's root_task_id via a
-- subquery at INSERT time (parent span is always inserted before its children).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS strand.trace_spans (
    id           TEXT        NOT NULL,
    namespace_id TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id) ON DELETE CASCADE,
    root_task_id UUID        NOT NULL,  -- top-level workflow task; index key for /trace
    task_id      UUID        NOT NULL,  -- owning task; index key for /history
    parent_id    TEXT,                  -- parent span id (task_id string or history span id)
    kind         TEXT        NOT NULL,  -- WORKFLOW|ACTIVITY|SLEEP|WAIT|SIGNAL|UPDATE|EMIT|CONDITION
    name         TEXT        NOT NULL,
    state        TEXT        NOT NULL,  -- QUEUED|RUNNING|COMPLETED|FAILED|CANCELLED
    attempt      INT         NOT NULL DEFAULT 0,
    worker_id    TEXT,
    max_attempts INT,
    queued_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at   TIMESTAMPTZ,
    finished_at  TIMESTAMPTZ,
    error        TEXT,
    -- History tab fields (only populated for discrete history events)
    event_type   TEXT,                  -- raw HistoryEventType e.g. "ACTIVITY_SCHEDULED"
    event_data   BYTEA,                 -- raw JSON payload for the history tab expand drawer
    seq_num      INT,                   -- ordering for history view
    CONSTRAINT strand_trace_spans_pkey PRIMARY KEY (id)
);

-- /trace endpoint: one index scan per workflow execution
CREATE INDEX IF NOT EXISTS strand_trace_spans_root_idx
    ON strand.trace_spans (namespace_id, root_task_id, queued_at ASC);

-- /history endpoint: one index scan per task
CREATE INDEX IF NOT EXISTS strand_trace_spans_task_idx
    ON strand.trace_spans (namespace_id, task_id, seq_num ASC NULLS LAST);

-- OLAP latency queries: PERCENTILE_CONT per task name over a time window
-- Powers: GET /api/:namespace/metrics/latency
CREATE INDEX IF NOT EXISTS strand_trace_spans_latency_idx
    ON strand.trace_spans (namespace_id, finished_at DESC)
    WHERE kind IN ('WORKFLOW', 'ACTIVITY')
      AND state = 'COMPLETED'
      AND started_at IS NOT NULL
      AND finished_at IS NOT NULL;

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
-- Backfills — retroactive scheduled execution over a historical time range.
--
-- One row per backfill request. `StrandScheduler.processBackfills()` polls
-- RUNNING rows each cycle and enqueues up to `concurrency` slots at a time.
-- Each enqueued task carries `backfill_id` so the dashboard can list all
-- tasks that belong to a given backfill.
-- ───────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS strand.backfills (
    id               UUID        NOT NULL,
    namespace_id     TEXT        NOT NULL REFERENCES strand.namespaces(id),
    queue            TEXT        NOT NULL,
    task_name        TEXT        NOT NULL,
    task_kind        TEXT        NOT NULL DEFAULT 'WORKFLOW',
    params           BYTEA       NOT NULL,
    headers          BYTEA,
    retry_strategy   BYTEA,
    max_attempts     INTEGER,
    schedule_pattern BYTEA       NOT NULL,   -- JSON-encoded SchedulePattern
    range_start      TIMESTAMPTZ NOT NULL,   -- inclusive
    range_end        TIMESTAMPTZ NOT NULL,   -- exclusive
    concurrency      INTEGER     NOT NULL DEFAULT 1,
    allow_overwrite  BOOLEAN     NOT NULL DEFAULT false,
    description      TEXT,
    schedule_id      UUID        REFERENCES strand.schedules(id) ON DELETE SET NULL,
    status           TEXT        NOT NULL DEFAULT 'RUNNING',
    next_slot_time   TIMESTAMPTZ NOT NULL,   -- cursor: next slot to fire
    total_slots      INTEGER     NOT NULL DEFAULT 0,
    completed_slots  INTEGER     NOT NULL DEFAULT 0,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at     TIMESTAMPTZ,
    CONSTRAINT strand_backfills_pkey   PRIMARY KEY (id),
    CONSTRAINT strand_backfills_kind   CHECK (task_kind IN ('WORKFLOW', 'ACTIVITY')),
    CONSTRAINT strand_backfills_status CHECK (status IN ('RUNNING', 'HALTED', 'COMPLETED', 'FAILED')),
    CONSTRAINT strand_backfills_conc   CHECK (concurrency >= 1)
);

-- StrandScheduler polls this index each cycle.
CREATE INDEX IF NOT EXISTS strand_backfills_running_idx
    ON strand.backfills (namespace_id, status)
    WHERE status = 'RUNNING';

-- Now that strand.backfills exists, add the FK from strand.tasks.
ALTER TABLE strand.tasks
    ADD CONSTRAINT strand_tasks_backfill_fk
    FOREIGN KEY (backfill_id) REFERENCES strand.backfills(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS strand_tasks_backfill_idx
    ON strand.tasks (backfill_id)
    WHERE backfill_id IS NOT NULL;

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
    namespace_id TEXT        NOT NULL DEFAULT 'default' REFERENCES strand.namespaces(id) ON DELETE CASCADE,
    queue        TEXT        NOT NULL,
    concurrency  INTEGER     NOT NULL,    -- configured workflowConcurrency + activityConcurrency
    running      INTEGER     NOT NULL DEFAULT 0,   -- currently executing tasks
    sdk_version  TEXT,                              -- Strand SDK version from build, e.g. "1.0.0" or commit SHA
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Initial monthly partitions (fresh install)
--
-- Create partitions for the current month and the next two months so the
-- schema is immediately usable. StrandPruner.ensurePartitions() maintains
-- this lead time at runtime (called at startup and every 12 h).
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    i INTEGER;
BEGIN
    FOR i IN 0..2 LOOP
        PERFORM strand.create_range_partition(
            'runs',
            date_trunc('month', NOW() + (i || ' months')::INTERVAL)::DATE
        );
        PERFORM strand.create_range_partition(
            'task_logs',
            date_trunc('month', NOW() + (i || ' months')::INTERVAL)::DATE
        );
    END LOOP;
END;
$$;

-- Seed parent-table statistics for the query planner.
-- Autovacuum never ANALYZEs partitioned parents — must be run manually
-- (and by StrandPruner.analyzeParentTables every 12 h).
ANALYZE strand.runs;
ANALYZE strand.task_logs;
