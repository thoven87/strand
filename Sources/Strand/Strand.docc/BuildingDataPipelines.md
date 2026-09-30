# Building data pipelines

Strand's durability, fan-out/fan-in, and scheduling primitives map cleanly onto
the standard data engineering lifecycle: define the time window, wait for
upstream data, guard against duplicates, process in parallel, and record
what you did. This guide walks through each stage using real Strand APIs.

## Define your data window

Every scheduled pipeline run covers a specific data period. Use
`context.schedulingMetadata.logicalDate` as the canonical anchor — it is
stable across retries and backfill re-runs. `executionTime` drifts with poll
latency and is always "now" for backfills, making it wrong for data logic.

```swift
@Workflow
struct NightlyIngestionPipeline {
    mutating func run(
        context: WorkflowContext<Self>,
        input: PipelineInput
    ) async throws -> PipelineResult {

        // Priority chain — resolve the data period before doing any work.
        let partitionDate: Date = {
            if let explicit = input.explicitDate { return explicit }        // manual trigger with explicit date
            return context.schedulingMetadata?.logicalDate                // scheduled or backfill run ← preferred
                ?? context.taskCreatedAt                                   // ad-hoc startWorkflow call
                ?? context.activationTime                                  // last resort
        }()

        let isBackfill = context.schedulingMetadata?.backfillId != nil

        context.logger.info(
            "Pipeline starting",
            metadata: [
                "partition": "\(partitionDate.ISO8601Format())",
                "backfill":  "\(isBackfill)",
            ]
        )

        // All subsequent stages use `partitionDate` to define their data range.
        // ...
    }
}
```

> **Rule:** never compute `partitionDate` from `Date()` or `context.executionTime`.
> Those values differ between a live run and a backfill re-run of the same slot.

## Wait for upstream data

A pipeline that starts before its source data arrives will silently produce an
empty or partial result. Gate the pipeline on upstream readiness before
processing anything.

### Event-based sensor (preferred)

When the upstream system can emit an event, subscribe with `waitForEvent`. The
workflow suspends at zero CPU cost until the event arrives or a timeout elapses:

```swift
// Upstream pipeline emits this when it finishes writing its output.
struct SourceReadyEvent: WorkflowEvent {
    typealias Payload = SourceReadyPayload
    static let name = "source.users.ready"
}
struct SourceReadyPayload: Codable, Sendable {
    let partitionDate: Date      // predicate routes to the correct waiting slot
    let rowCount: Int
}

// In the downstream pipeline's run():
guard let ready = try await context.waitForEvent(
    SourceReadyEvent.self,
    matching: \.partitionDate == partitionDate,
    timeout: .hours(6)
) else {
    // SLA exceeded — surface a clear error rather than silently ingesting nothing.
    throw PipelineError.upstreamTimedOut(
        "users source not ready within 6 hours for \(partitionDate.ISO8601Format())"
    )
}
context.logger.info("Upstream ready: \(ready.rowCount) rows available")
```

The `matching:` predicate is evaluated in Postgres. Each pipeline slot
independently blocks on its own partition date — concurrent slots do not
interfere.

Emit the event from the upstream pipeline's final activity:

```swift
// In the upstream pipeline:
try await client.emit(
    SourceReadyEvent.self,
    payload: SourceReadyPayload(partitionDate: partitionDate, rowCount: rowsWritten),
    queue: "pipelines"
)
```

### Polling sensor (fallback)

When the upstream system cannot emit events, poll for readiness in a bounded
loop:

```swift
let maxWaitMinutes = 360  // 6 hours
for attempt in 1...maxWaitMinutes {
    let ready = try await context.runActivity(
        PipelineActivities.CheckSourceReady.self,
        input: .init(partitionDate: partitionDate),
        options: ActivityOptions(maxAttempts: 3)
    )
    if ready { break }
    if attempt == maxWaitMinutes {
        throw PipelineError.upstreamTimedOut("users source not ready after \(maxWaitMinutes) min")
    }
    try await context.sleep(for: .minutes(1))
}
```

Each `sleep` and activity call is a checkpoint — if the worker restarts, the
loop resumes from the last completed poll rather than restarting the six-hour
wait.

## Guard against duplicate runs

Idempotency is non-negotiable in data pipelines. A manual retrigger, an
`.all` catch-up run, or a backfill must not double-write data that was already
successfully processed. Check the partition's status at the top of `run()` and
return early if it has already completed:

```swift
// Check a bookkeeping table (e.g. pipeline_runs) for this partition.
let status = try await context.runActivity(
    PipelineActivities.CheckPartitionStatus.self,
    input: .init(datasetID: input.datasetID, partitionDate: partitionDate),
    options: ActivityOptions(maxAttempts: 3)
)

switch status {
case .completed(let result):
    // Already done — return the original result so downstream workflows
    // that depend on this pipeline can proceed without re-processing.
    context.logger.info("Partition already completed, skipping")
    return result

case .inProgress:
    // Another instance is running — this should not normally happen with
    // `.latest` accuracy, but `.all` can produce concurrent slots.
    throw PipelineError.concurrentRun("partition \(partitionDate) already in progress")

case .notStarted:
    break  // proceed
}

// Insert a PENDING row so concurrent starters see `inProgress`.
try await context.runActivity(
    PipelineActivities.MarkPartitionStarted.self,
    input: .init(datasetID: input.datasetID, partitionDate: partitionDate),
    options: ActivityOptions(maxAttempts: 3)
)
```

Record the final result at the end of the pipeline:

```swift
try await context.runActivity(
    PipelineActivities.MarkPartitionCompleted.self,
    input: .init(
        datasetID: input.datasetID,
        partitionDate: partitionDate,
        rowsWritten: totalRowsInserted
    )
)
```

## Fan-out with error isolation

Production pipelines need chunk-level failure isolation: a single bad chunk
must not abort the entire pipeline. Use a non-throwing task group so each chunk
is independent:

```swift
struct ChunkOutcome: Sendable {
    let offset: Int
    let rowsInserted: Int
    let error: String?       // nil = success
}

var outcomes: [ChunkOutcome] = []

await withTaskGroup(of: ChunkOutcome.self) { group in
    for i in 0..<chunkCount {
        let offset = i * chunkSize
        let limit  = min(chunkSize, totalRows - offset)

        group.addTask {
            do {
                let inserted = try await context.runChildWorkflow(
                    IngestChunkWorkflow.self,
                    options: ChildWorkflowOptions(queue: "ingestion"),
                    input: ChunkInput(
                        partitionDate: partitionDate,
                        offset: offset,
                        limit: limit
                    )
                )
                return ChunkOutcome(offset: offset, rowsInserted: inserted, error: nil)
            } catch {
                context.logger.error(
                    "Chunk failed — will retry independently",
                    metadata: ["offset": "\(offset)", "error": "\(error)"]
                )
                return ChunkOutcome(offset: offset, rowsInserted: 0, error: "\(error)")
            }
        }
    }
    for await outcome in group { outcomes.append(outcome) }
}

let failedChunks   = outcomes.filter { $0.error != nil }
let totalInserted  = outcomes.reduce(0) { $0 + $1.rowsInserted }

// Fail the pipeline only if too many chunks failed — tolerate a small percentage.
let failureRate = Double(failedChunks.count) / Double(chunkCount)
if failureRate > 0.05 {
    throw PipelineError.tooManyFailedChunks(
        "\(failedChunks.count)/\(chunkCount) chunks failed (\(Int(failureRate * 100))%)"
    )
}
```

Each failed chunk is an independent child workflow in the FAILED state. It can
be retried from the Loom dashboard without re-running completed chunks.

## Conditional stages

Skip downstream stages when the upstream has nothing to produce — avoid
running compute-heavy analytics on empty data:

```swift
guard totalInserted > 0 else {
    context.logger.info("No new rows — skipping stats and enrichment stages")
    return PipelineResult(
        partitionDate: partitionDate,
        rowsInserted: 0,
        failedChunks: failedChunks.count,
        statsComputed: false,
        isBackfill: isBackfill
    )
}

// Stage 2 only runs when there is new data to aggregate.
let stats = try await context.runChildWorkflow(
    StatsWorkflow.self,
    options: ChildWorkflowOptions(queue: "analytics"),
    input: StatsInput(partitionDate: partitionDate, datasetID: input.datasetID)
)
```

## Capture lineage

Return a structured result that records what happened — source, period,
volumes, errors, timing. Downstream workflows and monitoring queries can inspect
this without touching the raw data tables:

```swift
struct PipelineResult: Codable, Sendable {
    let datasetID: String
    let partitionDate: Date
    let isBackfill: Bool
    let rowsRead: Int
    let rowsInserted: Int
    let failedChunks: Int
    let statsComputed: Bool
    let durationSeconds: Double
    let warnings: [String]
}
```

Write the same struct to a `pipeline_runs` bookkeeping table inside
`MarkPartitionCompleted` so it is queryable from SQL alongside the pipeline
output:

```sql
SELECT dataset_id, partition_date, rows_inserted, failed_chunks, duration_seconds
FROM   pipeline_runs
WHERE  partition_date >= NOW() - INTERVAL '7 days'
ORDER  BY partition_date DESC;
```

## Watermark / incremental ingestion

Full-refresh pipelines re-read everything every night. Incremental pipelines
read only what changed since the last run — orders of magnitude faster for large
datasets. Track a high-water mark in Postgres:

```swift
// Read the last successfully processed timestamp for this dataset.
let watermark = try await context.runActivity(
    PipelineActivities.FetchWatermark.self,
    input: .init(datasetID: input.datasetID),
    options: ActivityOptions(maxAttempts: 3)
)

// Pull only rows modified since the watermark (plus a small overlap for
// late-arriving data, e.g. 15 minutes).
let since = watermark.lastProcessedAt.addingTimeInterval(-15 * 60)

let newRows = try await context.runActivity(
    PipelineActivities.FetchChangedRows.self,
    input: .init(datasetID: input.datasetID, since: since, until: partitionDate),
    options: ActivityOptions(
        timeout: .minutes(30),
        heartbeatTimeout: .seconds(30),
        maxAttempts: 3
    )
)

// ... ingest newRows ...

// Advance the watermark only after successful ingestion.
// A crash before this point leaves the watermark unchanged —
// the next run will overlap and re-process the same rows (safe, idempotent).
try await context.runActivity(
    PipelineActivities.AdvanceWatermark.self,
    input: .init(
        datasetID: input.datasetID,
        newMark: newRows.latestModifiedAt
    ),
    options: ActivityOptions(maxAttempts: 5)
)
```

The watermark is a Postgres row, not a heartbeat detail — it persists across
runs. `context.heartbeat(_:)` is for within-run progress; cross-run state
belongs in a database table.

## Multi-queue worker setup

Assign each stage to a dedicated queue so you can scale and tune concurrency
independently:

```swift
// Orchestrator — long-lived, low concurrency
let orchestratorWorker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(queue: "pipeline", workflowConcurrency: 10, activityConcurrency: 4),
    workflows: [NightlyIngestionPipeline.self],
    activityContainers: [PipelineActivities(db: db)]
)

// Ingestion — high concurrency, I/O bound
let ingestionWorker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(queue: "ingestion", workflowConcurrency: 20, activityConcurrency: 40),
    workflows: [IngestChunkWorkflow.self],
    activityContainers: [IngestionActivities(db: db, api: apiClient)]
)

// Analytics — compute bound, separate scaling knob
let analyticsWorker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(queue: "analytics", workflowConcurrency: 5, activityConcurrency: 10),
    workflows: [StatsWorkflow.self],
    activityContainers: [AnalyticsActivities(db: db)]
)
```

## Scheduling, catch-up, and backfill

### Registering a nightly pipeline

```swift
var strand = StrandService(postgres: postgres, options: .init(
    queues: [.init(name: "pipeline", workflows: [NightlyIngestionPipeline.self],
                   activityContainers: [PipelineActivities(db: db)])],
    scheduler: .init()
))

strand.addSchedule(.workflow(
    "nightly-ingestion",
    pattern: .daily(hour: 2, timezone: utcTZ),   // 02:00 UTC daily
    workflowType: NightlyIngestionPipeline.self,
    input: PipelineInput(datasetID: "orders"),
    queue: "pipeline",
    options: ScheduleOptions(accuracy: .latest)   // skip stale slots on restart
))
```

### Catch-up after an outage

`accuracy` controls what happens when the scheduler restarts with missed slots:

| Accuracy | Use when |
|---|---|
| `.latest` | One run is enough — analytics dashboards, summaries. **Default.** |
| `.all` | Every slot must execute — financial reconciliation, compliance audit trails. |
| `.last(n)` | Bounded catch-up — recover the last `n` slots after a weekend outage. |

```swift
// Financial pipeline — no slot can be skipped
options: ScheduleOptions(accuracy: .all)

// Recover the 3 most recent missed slots after a weekend outage
options: ScheduleOptions(accuracy: .last(3))
```

### Backfilling historical data

Use `client.createBackfill()` to re-process a date range with controlled
concurrency. Set `allowOverwrite: false` to skip slots that already completed
successfully — only failed or missing slots are re-run:

```swift
let handle = try await client.createBackfill(
    NightlyIngestionPipeline.self,
    input: PipelineInput(datasetID: "orders"),
    schedule: .daily(hour: 2, timezone: utcTZ),
    range: startDate ..< endDate,
    options: BackfillOptions(
        concurrency: 4,          // 4 historical slots at a time
        allowOverwrite: false,   // skip successfully completed slots
        description: "Backfill orders after schema migration"
    )
)

// Poll progress
let status = try await handle.status()
print("\(status.completedSlots)/\(status.totalSlots) slots done (\(Int(status.progressFraction * 100))%)")
```

See <doc:Scheduling> for the full backfill API including `halt()`, `resume()`,
and single-slot replay.

## SLA enforcement

Set `maxDuration` on the pipeline workflow so a runaway job is killed and
on-call is paged rather than having a zombie run block the next slot:

```swift
let handle = try await client.startWorkflow(
    NightlyIngestionPipeline.self,
    options: WorkflowOptions(maxDuration: .hours(4)),
    input: PipelineInput(datasetID: "orders")
)
```

When `maxDuration` elapses, the workflow transitions to FAILED with a timeout
error, releasing its queue slot for the next scheduled run. Combine with
`accuracy: .latest` so a timed-out pipeline does not cascade into a catch-up flood.

## Rate-limited API ingestion

When fan-out drives traffic against an external API, share a rate-limit bucket
across all concurrent chunks. The leaky-bucket allocator enforces the ceiling
cluster-wide regardless of how many workers are running:

```swift
// Allow at most 200 API calls per second across all ingestion chunks.
// The "api.partner" key is shared — every chunk draws from the same bucket.
let ingestionOptions = ActivityOptions(
    timeout: .minutes(10),
    heartbeatTimeout: .seconds(30),
    maxAttempts: 3,
    rateLimit: .init(limit: 200, period: .seconds(1), key: "api.partner")
)
```

If the API returns a 429, advance the bucket cursor to postpone subsequent calls:

```swift
} catch where isRateLimitError(error) {
    try await context.bumpRateLimit(by: .seconds(60))
    throw error  // retry will start 60 s later
}
```

## Local activities — in-process transforms

For lightweight, side-effect-free transformations (JSON normalization, type
coercion, simple derivations) that don't need their own retry budget or task
row, use `runLocalActivity`. It runs inline in the workflow activation:

```swift
let normalized = try await context.runLocalActivity(
    NormalizeSchemaActivity.self,
    input: rawRecord
)
```

Keep local activities fast and idempotent. Any I/O — database writes, HTTP
calls, S3 reads — belongs in a regular activity so it can be retried
independently and observed in the Loom dashboard.

## See also

- <doc:Scheduling> — partition time in depth, catch-up modes, backfill API, timetables
- <doc:Activities> — idempotency patterns, heartbeat progress, rate limiting
- <doc:Examples#GroundwaterPipeline-—-6.2M-row-data-pipeline> — a working
  end-to-end pipeline against a 6.2 M-row public dataset with runtime fan-out,
  cursor recovery, and multi-queue routing
