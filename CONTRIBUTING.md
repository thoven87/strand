# Contributing to Strand

Thank you for your interest in contributing! This document explains the project's
conventions and architecture to help you get oriented quickly.

## AI Disclosure

> [!IMPORTANT]
>
> If you are using **any kind of AI assistance** to contribute to Strand,
> it must be disclosed in the pull request. A template is provided.

If you are using any kind of AI assistance while contributing to this project
you must disclose this in the pull request and the extent to which it was used.
When you use AI for PR descriptions you must also disclose that.

It is rude not to disclose AI usage to the reviewer and it makes it hard to
understand how much scrutiny needs to be placed on the contribution. We are
strong supporters and users of AI, but we also recognise the challenges that
lack of disclosure presents on open-source projects. Please be respectful to
maintainers and your fellow humans.

## SQL Maintenance

All schema changes go into [`strand.sql`](strand.sql) — the single source of
truth for the database schema. SDKs never issue schema-altering SQL directly.

During development, changes land only in `strand.sql`. For production releases,
targeted `ALTER TABLE` migration scripts should accompany schema changes. See
`Sources/Strand/Strand.docc/Migrations.md` for the recommended approach.

## Conventions

### Postgres

- All tables live in the `strand` schema.
- Primary keys are **UUIDv7** (time-ordered, sequential B-tree inserts).
- All JSON payloads are stored as **BYTEA** — encoded/decoded in Swift, never
  parsed by Postgres. No `jsonb` columns.
- State values are **UPPERCASE strings**: `'PENDING'`, `'RUNNING'`, `'COMPLETED'`,
  `'FAILED'`, `'CANCELLED'`, `'SLEEPING'`, `'WAITING'`.
- Every execution table carries `namespace_id` and it must appear as the **first
  column** in every composite index.
- Never query execution tables without a `namespace_id` filter.
- Use `FOR UPDATE SKIP LOCKED` for task claiming.
- Always use the `version` CAS check on `strand.runs` for state transitions.

### Swift

- Language version: **Swift 6.3**, strict concurrency everywhere.
- Use `JSON.encode` / `JSON.decode` (in `JSONHelpers.swift`) — never
  `Foundation.JSONEncoder` / `JSONDecoder` directly.
- Use `UUID.v7()` for new primary keys.
- All new Postgres queries belong in one of the four query files:
  `Queries.swift`, `ManagementQueries.swift`, `ScheduleQueries.swift`, or
  `WorkflowStateQueries.swift`. Do not add queries elsewhere.
- Keep files under ~500 lines and focused on a single concern.
- `TaskKind` is a Swift enum — use `.workflow` / `.activity` enum cases, never
  raw strings `"WORKFLOW"` / `"ACTIVITY"`.

### Dashboard (Loom)

The UI lives in `loom/`. It is a Vite + React 18 + TanStack app.

- Run the dev server with `cd loom && npm run dev` (proxies `/api` to port 8080).
- Build for production with `cd loom && npm run build` (outputs to
  `Sources/StrandServer/Resources/ui/`).
- No mock data in production routes — demos and fixtures live only in tests.

## Architecture Essentials

### The Two-Type Model

**`WorkflowDefinition<P, R>`** — orchestration only. No I/O, no `Date.now`, no
`UUID()`. Calls `ctx.runActivity(...)`, `ctx.sleep(for:)`, `ctx.waitForEvent(...)`.

**`Activity<P, R>`** — leaf unit of work. All I/O lives here. Independently
retried. Can be enqueued standalone or called from a workflow.

### Execution Model

1. Worker claims a run (`FOR UPDATE SKIP LOCKED`).
2. Worker loads checkpoints into `WorkflowContext` / `TaskContext`.
3. Handler calls `ctx.runActivity(...)` → enqueues activity, suspends via
   `InternalError.suspend`, releases the worker slot.
4. Activity runs on another worker slot.
5. Activity completes → `emitTaskCompletionSignal` fires → orchestrator
   transitions to `PENDING` → worker re-claims and re-runs from the top.
6. On re-run, `ctx.runActivity(...)` hits the `task_completions` fast path and
   returns immediately without suspension.

No worker slot is held while an activity runs. The orchestrator is `SLEEPING`.

### State Transitions

```
PENDING → RUNNING → COMPLETED
                 → FAILED      (retried with back-off up to maxRetries)
                 → CANCELLED
                 → SLEEPING    (ctx.sleep / waiting for child)
                 → WAITING     (waitForEvent)
```

## Running Tests

Tests require a local Postgres instance (see `docker-compose.yml`):

```bash
# Start Postgres
podman compose up -d

# Apply schema (once per fresh DB)
PGPASSWORD=strand psql -h 127.0.0.1 -p 5499 -U strand -d strand_dev -f strand.sql

# Run all tests
POSTGRES_HOST=127.0.0.1 swift test

# Run a specific suite
POSTGRES_HOST=127.0.0.1 swift test --filter IntegrationTests
```

## Pull Request Guidelines

- Run `swift test` before opening a PR and include the result in the description.
- Keep PRs focused — one logical change per PR.
- Update `strand.sql` for any schema change; include a migration note if the
  change is not additive.
- Add or update integration tests for any new query function or workflow
  behaviour.
- Disclose AI usage as described above.
