# Worker tuning

Practical guidance on choosing concurrency limits, queue topology, timeouts,
and connection pool sizing for production deployments.

## The two concurrency knobs

Every `StrandWorker` has two independent limits:

```swift
WorkerOptions(
    queue: "orders",
    workflowConcurrency: 8,    // max simultaneous workflow activations
    activityConcurrency: 32,   // max simultaneous activity executions
)
```

They control different things and should be sized independently.

### `workflowConcurrency`

A **workflow activation** is a short CPU-bound operation: replay checkpoints,
call the handler, write commands to Postgres. A typical activation takes
< 50 ms and holds no I/O resources during replay. You can run many of these
concurrently without worrying about Postgres connections — activations only
hold a connection for the final write batch, not for the entire replay.

**Good starting value**: `4–16`. Increase if you see workflow tasks queuing
while your workers are not CPU-saturated.

```swift
// CPU-heavy orchestration (many child workflows, deep replay)
workflowConcurrency: 8

// Simple pass-through orchestrators (one activity each)
workflowConcurrency: 32
```

### `activityConcurrency`

An **activity execution** typically holds open a Postgres connection (for
heartbeating via `extendClaim`), an outbound HTTP/gRPC connection, or a
database handle for the duration of its run. Each concurrent activity is a
real resource consumer.

**Rule of thumb**: `activityConcurrency ≤ postgres_pool_size - overhead`.

```swift
// For a pool of 20 connections, leaving ~5 for heartbeats / queries:
activityConcurrency: 15

// I/O-light activities (fast HTTP calls < 200 ms): can go higher
activityConcurrency: 64   // if using an external service with its own pool
```

---

## Queue topology

The most impactful tuning decision is how many queues to use.

### Single queue (simplest)

All workflows and activities share one pool of workers. Use when:
- Your workload is uniform
- No task type should starve others
- You have a small team and want operational simplicity

```swift
let worker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(queue: "default"),
    workflows: [OrderWorkflow.self, ReportWorkflow.self],
    activities: [ChargeCardActivity(), ShipOrderActivity(), GenerateReportActivity()]
)
```

### Dedicated queues for resource contention

Split queues when one task type would monopolise all slots. Classic example:
a slow AI/LLM activity should not prevent fast order activities from running.

```swift
// Fast operational work — many slots, short timeout
let opsWorker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(
        queue: "ops",
        activityConcurrency: 32,
        claimTimeout: .seconds(30)
    ),
    activities: [ChargeCardActivity(), SendEmailActivity()]
)

// Slow AI work — few slots, long timeout, heartbeat required
let aiWorker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(
        queue: "ai",
        activityConcurrency: 3,       // Ollama can handle 3 concurrent requests
        claimTimeout: .seconds(300)   // models take time to generate
    ),
    activities: [OllamaSummarizeActivity(), EmbeddingActivity()]
)
```

### The HN Summary pattern: dedicated summariser queue

The ``HackerNewsSummary`` example uses this split:

```swift
// Orchestrator: high concurrency, low timeout (activations are fast)
WorkerOptions(queue: "hn-orchestrator", workflowConcurrency: 8, activityConcurrency: 8)

// Summariser: limited concurrency to rate-limit Ollama
WorkerOptions(queue: "hn-summarizer",  workflowConcurrency: 3, activityConcurrency: 3)
```

Route child workflows to the constrained queue via `ChildWorkflowOptions`:

```swift
try await context.runChildWorkflow(
    SummarizeStoryWorkflow.self,
    options: .init(queue: "hn-summarizer"),
    input: storyID
)
```

`workflowConcurrency: 3` becomes an effective rate-limit on simultaneous
Ollama calls without any application-level semaphore.

---

## Claim timeout

`claimTimeout` has two roles:

1. **Initial lease**: `lease_expires_at = NOW() + claimTimeout` is set when a
   run is claimed. If the worker crashes before completing, `leaseExpiryLoop`
   re-queues the run after this interval.
2. **Heartbeat extension**: each `context.heartbeat()` call extends the lease
   by `claimTimeout` more seconds.

**Set it to your p95 activity duration + a safety margin:**

```swift
// Activity typically finishes in 5–15 s → 60 s is plenty
WorkerOptions(claimTimeout: .seconds(60))

// Long-running batch activity (minutes) → make it longer, heartbeat often
WorkerOptions(claimTimeout: .seconds(300))  // and call context.heartbeat() every 30 s
```

**The 2× fatal deadline**: if no heartbeat or checkpoint is written for
`2 × claimTimeout`, the in-process deadline poller cancels the task. This
prevents zombie tasks from holding a slot forever. For activities that make
steady progress and heartbeat regularly, this deadline is continuously renewed
and never fires.

**Per-activity override**: when one activity in a queue needs a different
budget, use `ActivityOptions.timeout` rather than changing the worker default:

```swift
try await context.runActivity(
    HeavyBatchActivity.self,
    input: batch,
    options: ActivityOptions(
        timeout: .seconds(600),          // this activity gets 10 min per attempt
        maxDuration: .hours(4)       // but no more than 4 h total across retries
    )
)
```

---

## LISTEN/NOTIFY and the poll interval

Workers hold a dedicated PostgreSQL `LISTEN` connection and wake up the
moment a task becomes `PENDING`. Every path that creates a pending run —
`enqueueTask`, `emitTaskCompletionSignal`, `emitEvent`, `retryTask`, and
others — sends `pg_notify('strand_tasks', '<namespace>/<queue>')` inside its
transaction. The notification is only delivered after the transaction commits,
so the worker always sees a claimable row.

### `pollInterval` — safety-net fallback only

With LISTEN/NOTIFY active, `pollInterval` (default: `5 s`) fires only for
two edge cases:
- The LISTEN connection was briefly down during the 1-second reconnect
  back-off.
- A `SLEEPING` task's `available_at` fired (timer expiry). Timer wakeups
  are driven by `available_at <= NOW()` in `claimTasks` — no `NOTIFY` is
  sent for this transition, so the fallback poll catches them.

Keep `pollInterval` at a few seconds. Sub-100 ms values add unnecessary DB
load without reducing task-pickup latency — NOTIFY handles the fast path.

### `notifyJitter` — thundering-herd mitigation

`NOTIFY` is broadcast: every worker on the queue wakes simultaneously. With
hundreds of workers, a single enqueue can trigger hundreds of concurrent
`claimTasks` queries. `notifyJitter` (default: `50 ms`) applies a random
delay drawn from `[0, notifyJitter]` **only on NOTIFY wakeups** so claims
spread across the window instead of hitting Postgres all at once.

Tuning formula: keep `N / W_ms ≈ 2–5` concurrent claims.

| Workers | `notifyJitter` |
|---------|----------------|
| 1 | `.zero` |
| ≤ 10 | `.milliseconds(20)` |
| ≤ 100 | `.milliseconds(100)` |
| 300+ | `.milliseconds(300)` |

`FOR UPDATE SKIP LOCKED` guarantees correctness regardless of jitter — each
row is claimed by exactly one worker. Jitter is a load knob, not a
correctness requirement.

---

## Fairness keys

Fairness keys enforce per-tenant FIFO and prevent a single tenant from
monopolising all worker slots.

```swift
// Enqueue with a tenant-scoped fairness key
try await client.enqueue(
    ProcessReportActivity.self,
    input: reportInput,
    options: ActivityOptions(
        fairnessKey:    tenantID,   // string key, e.g. "tenant-acme"
        fairnessWeight: 1.0         // relative throughput weight
    )
)
```

**How it works**: within each fairness key only the *oldest* eligible task is
dispatched at a time (FIFO per key). Keys then compete via
`random() / fairnessWeight` so no key starves. A key with `weight: 5.0` gets
~5× the throughput of a key with `weight: 1.0`.

**When to use:**
- Multi-tenant SaaS: key = tenant ID, weight = subscription tier
- Rate-limiting a specific integration: key = "stripe" or "openai"
- Prioritising internal vs external work: same priority level, different weights

**When not to use:** adding fairness keys introduces a correlated subquery in
`claimTasks` that is O(1) per candidate thanks to `strand_runs_fairness_idx`.
On queues with no fairness keys, the index is not used and there is no overhead.

---

## Connection pool sizing

Each worker needs Postgres connections for:
- `pollLoop` claim queries (1 connection at a time)
- `leaseExpiryLoop` sweep queries (1 connection at a time)
- Running activity heartbeats (1 per concurrent activity)
- Workflow checkpoint writes (brief, returned to pool quickly)

**Minimum safe pool size:**

```
min_pool = activityConcurrency        // heartbeats
         + 2                          // poll + lease sweep
         + scheduler_if_present       // +1 if running StrandScheduler
         + dashboard_api_if_present   // +N for concurrent HTTP requests
```

**Example**: 32 activity slots + worker + scheduler + dashboard:

```swift
PostgresClient(configuration: .init(
    // ...
    maximumConnections: 40   // 32 + 2 + 1 + 5 headroom
))
```

Undersizing the pool causes `pollLoop` to stall waiting for a connection,
which directly increases task claim latency. Oversizing is harmless up to
Postgres's `max_connections` limit (default 100 per instance).

---

## Retry strategy reference

```swift
// Standard: 5 attempts, exponential 2 s → 4 s → 8 s → capped at 5 min
StrandOptions(
    defaultMaxAttempts: 5,
    defaultRetryStrategy: .backoff(initial: .seconds(2), multiplier: 2, cap: .minutes(5))
)

// For external API calls that may be rate-limited (slower back-off):
ActivityOptions(
    maxAttempts: 10,
    retryStrategy: .backoff(initial: .seconds(10), multiplier: 1.5, cap: .minutes(10))
)

// For idempotent fast operations (retry quickly):
ActivityOptions(
    maxAttempts: 5,
    retryStrategy: .immediate()
)

// Never retry validation errors — fail fast:
var strategy = RetryStrategy.backoff()
strategy.doNotRetry(ValidationError.self)
ActivityOptions(maxAttempts: 3, retryStrategy: strategy)
```

---

## Quick-reference: common configurations

### Low-latency API gateway

```swift
WorkerOptions(
    queue:                "api",
    workflowConcurrency:  16,
    activityConcurrency:  64,
    claimTimeout:         .seconds(15)
    // pollInterval left at default (5 s) — LISTEN/NOTIFY handles fast wakeup;
    // tune notifyJitter based on how many workers share this queue.
)
```

### Background data pipeline (GroundwaterPipeline-style)

```swift
// Ingestion workers — high throughput, can be retried
WorkerOptions(queue: "ingestion", activityConcurrency: 40, claimTimeout: .seconds(120))

// Analytics workers — fewer, heavier
WorkerOptions(queue: "analytics", activityConcurrency: 10, claimTimeout: .seconds(300))

// AI workers — rate-limited by model capacity
WorkerOptions(queue: "ai", activityConcurrency: 5, claimTimeout: .seconds(600))
```

### Multi-tenant SaaS

```swift
// All tenants share one queue; fairness keys prevent starvation
WorkerOptions(queue: "default", activityConcurrency: 32)

// Enqueue with fairness key per tenant
ActivityOptions(fairnessKey: tenant.id, fairnessWeight: tenant.tierWeight)
```

### Scheduled summariser (HackerNews-style)

```swift
// Orchestrator: fast activations, many slots
WorkerOptions(queue: "orchestrator", workflowConcurrency: 16, activityConcurrency: 16)

// AI worker: rate-limited by model
WorkerOptions(queue: "ai-worker", workflowConcurrency: 3, activityConcurrency: 3)
```
