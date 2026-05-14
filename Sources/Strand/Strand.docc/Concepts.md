# Core concepts

How Strand achieves durable execution on top of Postgres.

## The execution model

A **workflow** is a Swift struct that conforms to ``Workflow``. Its `run` function
is the orchestration logic. It calls `context.runActivity(...)` to dispatch leaf
units of work, and `context.sleep(for:)` / `context.waitForEvent(...)` to
suspend until external events arrive.

An **activity** is a Swift struct that conforms to ``Activity`` and
performs I/O: database queries, HTTP calls, file operations. Activities are the
only place where side effects should live.

A **worker** is a long-running service (``StrandWorker``) that polls Postgres for
pending tasks, claims them with `FOR UPDATE SKIP LOCKED`, executes them, and
writes results back. Multiple workers can run concurrently — Postgres guarantees
each run is claimed by exactly one worker at a time.

## Checkpointing

When a workflow calls `context.runActivity(...)`:

1. The activity is written to `strand.tasks` with state `PENDING`.
2. The workflow's current run transitions to `SLEEPING`.
3. The worker slot is freed — no thread is held while the activity runs.
4. An activity worker claims the activity task, executes it, and stores the
   result in `strand.task_completions`.
5. A completion signal wakes the workflow's sleeping run.
6. The workflow re-activates. `context.runActivity(...)` returns the stored
   result instantly without re-executing.

This replay pattern means the workflow handler function runs from the top on
every activation. Completed steps are skipped via the checkpoint cache.
Non-deterministic code — `Date.now`, `UUID()`, random numbers — must go inside
activities so that replays produce the same decisions.

## Exactly-once execution

Strand uses optimistic concurrency (a `version` CAS on `strand.runs`) to
prevent double-completion. If a worker crashes after completing an activity but
before acknowledging the result, the lease expiry loop will re-queue the
activity. The activity will run again, but the completion INSERT into
`strand.task_completions` uses `ON CONFLICT DO NOTHING`, so the workflow only
sees one result.

## What does NOT belong in a workflow

A workflow handler must be **deterministic and side-effect-free**:

- ❌ HTTP requests
- ❌ Database writes
- ❌ `Date.now` (use ``WorkflowContext/activationTime`` instead)
- ❌ `UUID()` (use `context.uuid()` instead)
- ❌ `Bool.random()` or any other non-deterministic value (use `context.random(in:)`)

All of these belong inside activities.

## Namespaces

Every ``StrandClient`` and ``StrandWorker`` is scoped to a namespace. The
default is `"default"`. Use namespaces to isolate tenants or environments:

```swift
let client = StrandClient(postgres: postgres, queue: "orders", namespace: "acme-corp")
let worker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(queue: "orders", namespace: "acme-corp"),
    workflows: [OrderWorkflow.self],
    activities: [ChargeCardActivity()]
)
```

All queries are automatically namespace-scoped — tasks in `"acme-corp"` are
invisible to workers in `"default"`.
