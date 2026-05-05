# Examples

Runnable examples showing Strand in production-grade scenarios.
Each example is a self-contained Swift executable in the
[`Examples/`](https://github.com/thoven87/strand/tree/main/Examples) directory.

## Running an example

```bash
# Apply the schema once
psql "postgresql://strand:strand@localhost:5499/strand_dev" -f strand.sql

# Run any example
cd Examples
swift run CIPipeline
swift run SmartBuilding
swift run HackerNewsSummary
swift run GroundwaterPipeline
swift run DevServer
```

## CIPipeline — durable CI/CD with an approval gate

Models a full CI/CD pipeline as a durable workflow. If the build worker crashes
during any stage, the pipeline resumes from the last completed step on restart.

**Key patterns:**
- Parallel quality gates (`async let` fan-out of lint + tests + security scan)
- Automatic retry — unit tests fail on attempt 1, pass on attempt 2
- Signal-based deployment approval gate (`context.condition` + ``WorkflowSignalDefinition``)

```swift
// Stage 2: lint, tests, and security scan run simultaneously.
// Each is an independent Activity with its own retry policy.
async let lint     = context.runActivity(LintActivity.self,         input: input)
async let tests    = context.runActivity(UnitTestActivity.self,      input: input)
async let security = context.runActivity(SecurityScanActivity.self,  input: input)
let (l, t, s) = try await (lint, tests, security)

// Stage 4: suspend until a human (or bot) sends the "approve" signal.
// Kill the process here and restart — the workflow is still waiting.
try await context.condition(timeout: .hours(24)) { $0.approvalDecision != nil }
```

Approve a pending deployment from your application:

```swift
let handle: WorkflowHandle<CIPipelineWorkflow> = ...
try await handle.signal(
    CIPipelineWorkflow.Approve.self,
    payload: ApprovalDecision(approved: true, approver: "alice")
)
```

Or from the Loom dashboard: task detail → **Send Signal** → name: `approve`,
payload: `{"approved": true, "approver": "alice"}`.

## SmartBuilding — IoT sensor monitoring

Monitors a smart building with one long-lived `RoomMonitorWorkflow` per room,
all running in parallel. Demonstrates Strand's suitability for device-centric
workloads where each entity gets its own durable workflow.

**Key patterns:**
- `context.sleep(for:)` between sensor polling cycles
- Per-entity child workflows fanned out with `async let`
- In-flight threshold updates via `WorkflowSignalDefinition`

```swift
// Each room runs independently — a crash in one room's monitor
// does not affect the others.
async let lobby      = context.runChildWorkflow(RoomMonitorWorkflow.self, input: rooms[0])
async let office     = context.runChildWorkflow(RoomMonitorWorkflow.self, input: rooms[1])
async let serverRoom = context.runChildWorkflow(RoomMonitorWorkflow.self, input: rooms[2])
async let conference = context.runChildWorkflow(RoomMonitorWorkflow.self, input: rooms[3])
let reports = try await [lobby, office, serverRoom, conference]
```

Inside each room monitor, `context.sleep` keeps the workflow alive between cycles
without holding a worker slot:

```swift
for cycle in 1...input.cycles {
    let readings = try await context.runActivity(ReadSensorsActivity.self, input: ...)
    // check thresholds, fire alerts ...
    if cycle < input.cycles {
        try await context.sleep(for: .seconds(30))  // releases the worker slot
    }
}
```

Update thresholds on a running workflow without restarting it:

```swift
try await handle.signal(
    name: RoomMonitorWorkflow.UpdateThresholds.signalName,
    payload: ThresholdUpdate(newThresholds: raised, reason: "post-incident")
)
```

## HackerNewsSummary — AI fan-out with Ollama

Fetches the top Hacker News stories and summarises each one with a locally
running Ollama model. One `SummarizeStoryWorkflow` child per story runs
concurrently, with `activityConcurrency` capping the load on the model.

**Key patterns:**
- Child workflow fan-out over a dynamic collection
- Controlled concurrency (`activityConcurrency` limit)
- Ollama activity integration

**Prerequisites:** Ollama running locally with `qwen3` pulled.

```bash
ollama pull qwen3
cd Examples && swift run HackerNewsSummary
```

## GroundwaterPipeline — 6.2M-row data pipeline

Downloads California groundwater measurements from the CNRA open data API,
ingests them into PostgreSQL in parallel chunks, computes per-county statistics,
and optionally runs Ollama trend classification.

**Key patterns:**
- Runtime fan-out (chunk count computed from file size at runtime, not hardcoded)
- Sub-chunk cursor recovery — crash at row 650, resume at row 600
- Multi-queue routing (orchestrator + ingestion + analytics queues)
- Long-running activities with `context.heartbeat()`

```bash
# Quick test run — 2 chunks, no AI
cd Examples
MAX_CHUNKS=2 RUN_AI=false swift run GroundwaterPipeline
```

See [`Examples/Sources/GroundwaterPipeline/README.md`](https://github.com/thoven87/strand/blob/main/Examples/Sources/GroundwaterPipeline/README.md)
for full configuration and the complete dataset walk-through.

## DevServer — local development backend

Runs the Strand API server (Hummingbird), two worker pools, and a live seeder
that continuously enqueues workflow tasks. Used as the backend for the Loom
dashboard during local development.

```bash
# Terminal 1
cd Examples && swift run DevServer

# Terminal 2
cd loom && npm run dev   # → http://localhost:5173
```

## Pattern reference

| Pattern | Example |
|---|---|
| Parallel activity fan-out (`async let`) | CIPipeline, SmartBuilding |
| Child workflow fan-out | SmartBuilding, HackerNewsSummary, GroundwaterPipeline |
| Signal + `condition` approval gate | CIPipeline |
| In-flight state update via signal | SmartBuilding, CIPipeline |
| `context.sleep` between cycles | SmartBuilding |
| Automatic activity retry | CIPipeline (unit tests) |
| Multi-queue routing | GroundwaterPipeline |
| Runtime fan-out (dynamic chunk count) | GroundwaterPipeline |
| Scheduled workflow | GroundwaterPipeline (nightly) |
| Ollama / AI activity integration | HackerNewsSummary, GroundwaterPipeline |
