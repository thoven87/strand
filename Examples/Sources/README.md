# Strand Examples

Runnable examples demonstrating Strand in production-grade scenarios.
Each example connects to a local PostgreSQL instance (port 5499).

```bash
# One-time schema setup
psql "postgresql://strand:strand@localhost:5499/strand_dev" -f ../strand.sql
```

---

## Examples

### [HackerNewsSummary](HackerNewsSummary/)

Fetches the top Hacker News stories, summarises each with a locally-running
Ollama model, and prints the results. Demonstrates:

- Child workflow fan-out (one `SummarizeStoryWorkflow` per story)
- Ollama activity integration
- Controlled concurrency (`activityConcurrency` cap to avoid overloading the model)

**Prerequisites:** Ollama running locally with `qwen3` pulled.

```bash
cd Examples
swift run HackerNewsSummary
```

### [CIPipeline](CIPipeline/)

Models a CI/CD pipeline as a durable Strand workflow. Demonstrates:

- Parallel activity fan-out (lint + unit tests + security scan run simultaneously)
- Automatic retry (unit tests fail on attempt 1, succeed on attempt 2 — the workflow never sees the failure)
- Signal-based approval gate (`context.condition` suspends the workflow until an `Approve` signal arrives)
- Durability (kill the process at any stage; restart resumes from the last completed stage)

```bash
cd Examples
swift run CIPipeline
```

### [SmartBuilding](SmartBuilding/)

Monitors four rooms of a smart building in parallel, each with its own durable
`RoomMonitorWorkflow`. The server room experiences a temperature spike on cycle 3,
triggering an alert. The ops team sends an `UpdateThresholds` signal to the running
workflow, demonstrating in-flight state mutation without restarting anything.
Demonstrates:

- Per-entity child workflows running in parallel (one per room, fanned out with `async let`)
- `context.sleep(for:)` between sensor polling cycles — durable across restarts
- Signals to update running workflow state in-flight (`UpdateThresholds` signal)
- Activities with deterministic sensor-variance simulation
- Durability — kill the process mid-cycle and restart; each room resumes from its last completed cycle

```bash
cd Examples
swift run SmartBuilding
```

### [GroundwaterPipeline](GroundwaterPipeline/)

Ingests 6.2 M rows of California groundwater data from the CNRA public API,
computes per-county statistics, and optionally runs an AI trend analysis.
Demonstrates:

- Runtime fan-out (chunk count driven by file size, not hardcoded)
- Sub-chunk cursor recovery (crash at row 650 → resume at row 600)
- Multi-queue routing (orchestrator queue + worker queue)
- Long-running pipelines with durable checkpointing

See [`GroundwaterPipeline/README.md`](GroundwaterPipeline/README.md) for
full setup and configuration.

```bash
cd Examples
MAX_CHUNKS=2 RUN_AI=false swift run GroundwaterPipeline
```

### [DevServer](DevServer/)

Runs a Strand HTTP dashboard API alongside two worker pools and a background
seeder that continuously generates workflow tasks. Used as the backend for
the Loom dashboard during local development.

**Prerequisites:** Loom dev server: `cd loom && npm run dev`

```bash
cd Examples
swift run DevServer
# Then in a separate terminal:
cd loom && npm run dev   # → http://localhost:5173
```
