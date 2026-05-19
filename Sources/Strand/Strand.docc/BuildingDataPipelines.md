# Building data pipelines

Strand's fan-out/fan-in pattern and child workflows make it well-suited for
multi-stage data pipelines where each stage can run on independent worker pools.

## Pattern overview

```
┌─────────────────────────────────────────────────────┐
│  IngestionPipeline                                   │
│    1. DiscoverActivity   → totalRows                 │
│    2. fan-out N × IngestChunkWorkflow (parallel)     │
│    3. StatsWorkflow      → per-partition aggregates  │
└─────────────────────────────────────────────────────┘
```

Each stage is a child workflow on a dedicated queue with its own worker pool.
If the orchestrator process crashes mid-pipeline, Strand replays from the last
completed stage boundary.

## Example: chunked ingestion pipeline

```swift
struct IngestionPipeline: Workflow {
    typealias Input  = PipelineInput
    typealias Output = PipelineResult

    mutating func run(
        context: WorkflowContext<Self>,
        input: PipelineInput
    ) async throws -> PipelineResult {
        // Stage 1: discover total record count
        let discovery = try await context.runActivity(
            DiscoverActivity.self,
            input: .init(source: input.sourceURL),
            options: ActivityOptions(maxAttempts: 3)
        )

        // Stage 2: fan-out one chunk workflow per N rows
        let chunkSize = 50_000
        let chunkCount = (discovery.totalRows + chunkSize - 1) / chunkSize

        var inserted = 0
        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<chunkCount {
                group.addTask {
                    try await context.runChildWorkflow(
                        IngestChunkWorkflow.self,
                        options: ChildWorkflowOptions(queue: "ingestion"),
                        input: ChunkInput(
                            source: input.sourceURL,
                            offset: i * chunkSize,
                            limit: chunkSize
                        )
                    )
                }
            }
            for try await rowsInserted in group {
                inserted += rowsInserted
            }
        }

        // Stage 3: compute statistics on a separate queue
        let stats = try await context.runChildWorkflow(
            StatsWorkflow.self,
            options: ChildWorkflowOptions(queue: "analytics"),
            input: StatsInput(datasetID: input.datasetID)
        )

        return PipelineResult(
            totalRows: discovery.totalRows,
            rowsInserted: inserted,
            statsComputed: stats.partitionCount
        )
    }
}
```

## Multi-queue worker setup

Assign each stage to a dedicated queue so you can tune concurrency and scale
independently:

```swift
// Orchestrator — low concurrency, long-lived
let orchestratorWorker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(
        queue: "pipeline",
        workflowConcurrency: 10,
        activityConcurrency: 4
    ),
    workflows: [IngestionPipeline.self],
    activities: [DiscoverActivity()]
)

// Ingestion — high concurrency, CPU/network bound
let ingestionWorker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(
        queue: "ingestion",
        workflowConcurrency: 20,
        activityConcurrency: 40
    ),
    workflows: [IngestChunkWorkflow.self],
    activities: [DownloadAndInsertActivity()]
)

// Analytics — separate pool
let analyticsWorker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(
        queue: "analytics",
        workflowConcurrency: 5,
        activityConcurrency: 10
    ),
    workflows: [StatsWorkflow.self],
    activities: [ComputePartitionStatsActivity()]
)
```

## Crash recovery

Because each chunk is an independent child workflow:

- A worker crash mid-ingestion only re-runs the in-flight chunks, not the
  whole pipeline.
- Completed chunks are skipped on replay via the checkpoint cache.
- The orchestrator resumes from the last completed stage boundary.

## Scheduling a nightly pipeline

When the schedule is known at compile time, register it at boot via
`StrandService.addSchedule`. This is the recommended pattern because the
schedule is declared alongside the rest of your service configuration and
starts automatically with the worker process:

```swift
var strand = StrandService(
    postgres: postgres,
    options: .init(
        queues: [
            .init(name: "pipeline", workflows: [IngestionPipeline.self], activities: [DiscoverActivity()])
        ],
        scheduler: .init()   // enable the scheduler
    )
)
strand.addSchedule(.workflow(
    "nightly-ingestion",
    pattern: .daily(offset: "PT2H"),   // 02:00 UTC
    workflowType: IngestionPipeline.self,
    input: PipelineInput(sourceURL: "s3://my-bucket/data/", datasetID: "nightly"),
    queue: "pipeline",
    options: ScheduleOptions(accuracy: .latest)   // skip stale slots on restart
))
```

`client.schedule(...)` is still valid when the schedule is created **at
runtime** — for example, from an HTTP handler when a user configures a new
pipeline:

```swift
// Runtime creation — e.g. from an HTTP handler when a user configures a new pipeline
try await client.schedule(
    name: "custom-ingestion-\(userID)",
    pattern: .cron(userCron),
    workflowType: IngestionPipeline.self,
    input: PipelineInput(sourceURL: userBucket, datasetID: userID)
)
```

## Local activities — in-process steps

For lightweight, purely-in-memory steps that don't need their own task row,
use `context.runLocalActivity(...)`. Local activities run inline in the
workflow activation and are retried as part of the workflow's own execution,
not as independent tasks:

```swift
let normalized = try await context.runLocalActivity(
    NormalizeInputActivity.self,
    input: rawInput
)
// normalized is computed in-process; no strand.tasks row is created
```

Use local activities only for fast, idempotent, side-effect-free transformations.
Any I/O should remain in a regular (non-local) activity so it can be retried
independently.

## See also

- <doc:Examples#GroundwaterPipeline-—-6.2M-row-data-pipeline> — a working
  example against a real 6.2M-row dataset with runtime fan-out, cursor recovery,
  and multi-queue routing.
- <doc:Examples#SmartBuilding-—-IoT-sensor-monitoring> — per-entity child
  workflows fanned out in parallel, each sleeping between sensor cycles.
