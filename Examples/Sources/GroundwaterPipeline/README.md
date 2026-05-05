# Groundwater Pipeline

A production-grade data pipeline that downloads **6.2 million rows** of California
groundwater level measurements from the [CNRA Open Data Portal][cnra], inserts
them into a range-partitioned PostgreSQL table, computes per-county statistics
using SQL aggregates, and runs Ollama AI trend classification for each of
California's 58 counties.

[cnra]: https://data.cnra.ca.gov/dataset/periodic-groundwater-level-measurements

---

## What it demonstrates

| Strand feature | Where |
|---|---|
| 3-level fan-out | Pipeline → 125 chunk workflows → 58 county stats → 58 AI calls |
| Data-driven fan-width | Row count from CKAN API; county list from SQL — nothing hardcoded |
| `context.heartbeat()` | Every 1 000 rows during a 50k-row streaming download |
| Child workflows | Each 50k-row chunk is an independent durable workflow |
| Multi-queue routing | 4 queues with different concurrency budgets |
| PostgreSQL partitioned tables | Range partitioned by decade (pre-1970 → 2030+) |
| Streaming CSV | `URLSession.bytes` — never loads the full CSV into memory |
| UNNEST bulk insert | Single SQL query per 1 000-row batch via `PostgresBindings` |
| Idempotent writes | `ON CONFLICT DO NOTHING` / `ON CONFLICT DO UPDATE` throughout |
| `context.activationTime` | Stable timestamps across re-activations |
| Crash recovery | Kill mid-run → restart → resumes from last completed chunk |

---

## Prerequisites

- PostgreSQL 15+ on `localhost:5499` (same as other Strand examples)
- Ollama running locally with `qwen3` pulled (AI stage only)
- Internet access to `data.cnra.ca.gov`

```bash
# Pull the model if you plan to run the AI stage
ollama pull qwen3
```

---

## Quick start

```bash
# 1. Apply the Strand schema (once, if not already done)
psql "postgresql://strand:strand@localhost:5499/strand_dev" -f ../../../strand.sql

# 2. Test run — 2 chunks (100k rows), no AI (~2 min)
cd Examples
MAX_CHUNKS=2 RUN_AI=false swift run GroundwaterPipeline

# 3. Full pipeline — all 125 chunks (6.2M rows) + AI (~30-60 min)
swift run GroundwaterPipeline
```

The CNRA schema (`cnra.*` tables) is created automatically on first run.

---

## Configuration

All options are environment variables:

| Variable | Default | Description |
|---|---|---|
| `CHUNK_SIZE` | `50000` | Rows per ingestion chunk (50k → 125 chunks for 6.2M) |
| `MAX_CHUNKS` | *(all)* | Cap the number of chunks; omit to ingest everything |
| `RUN_AI` | `true` | Run Ollama trend analysis after stats. Set `false` to skip |
| `RESUME_ONLY` | `false` | Start workers without launching a new pipeline; use after a crash or Ctrl+C to resume in-flight workflows |
| `POSTGRES_HOST` | `localhost` | |
| `POSTGRES_PORT` | `5499` |
| `POSTGRES_USER` | `strand` |
| `POSTGRES_PASSWORD` | `strand` |
| `POSTGRES_DB` | `strand_dev` |

---

## Architecture

Four Strand queues run concurrently in the same process:

```
gw-orchestrator   1 wf  / 8  act  — GroundwaterPipelineWorkflow, StatsWorkflow
gw-ingestion     20 wf  / 40 act  — IngestChunkWorkflow × 125
gw-analytics     10 wf  / 20 act  — StatsWorkflow (county fan-out)
gw-ai             5 wf  / 10 act  — AIAnalysisWorkflow × 58 counties
```

### Pipeline stages

```
GroundwaterPipelineWorkflow
│
├─ DiscoverActivity
│   → CKAN API → 6,209,669 rows → compute chunk count
│
├─ Fan-out: IngestChunkWorkflow × 125   (gw-ingestion)
│   └─ DownloadAndInsertActivity
│       ├─ URLSession.bytes   stream CSV line by line
│       ├─ GroundwaterRow.init(csvLine:)  RFC 4180 parser
│       ├─ insertBatch()   UNNEST single-query bulk insert
│       └─ context.heartbeat()   every 1 000 rows
│
├─ StatsWorkflow   (gw-analytics)
│   ├─ DiscoverCountiesActivity   SELECT DISTINCT county_name
│   └─ Fan-out: ComputeCountyStatsActivity × 58
│       └─ SQL: AVG / MIN / MAX / STDDEV + 5-year trend delta
│          → cnra.county_stats
│
└─ AIAnalysisWorkflow   (gw-ai, rate-limited)
    └─ Fan-out: OllamaTrendActivity × 58
        └─ qwen3 (format: json)
           → DECLINING | STABLE | RECOVERING + 2-sentence narrative
           → cnra.county_stats.trend / ai_narrative
```

### Database schema

```sql
cnra.groundwater_measurements   -- 6.2M rows, partitioned by decade
cnra.county_stats               -- 58 counties, stats + AI narrative
cnra.chunk_progress             -- per-chunk idempotency + progress
cnra.pipeline_runs              -- one row per swift run invocation
```

The measurements table uses **PostgreSQL range partitioning**:

```
cnra.gw_pre1970   before 1970
cnra.gw_1970s     1970–1979
cnra.gw_1980s     1980–1989
cnra.gw_1990s     1990–1999
cnra.gw_2000s     2000–2009
cnra.gw_2010s     2010–2019
cnra.gw_2020s     2020–2029
cnra.gw_future    2030+
```

Partition pruning means a query like `WHERE msmt_date >= '2020-01-01'` scans
only `gw_2020s` and `gw_future` rather than all 6.2M rows.

---

## Monitoring

While the pipeline is running:

```sql
-- Overall progress
SELECT job_id, ingested_rows, total_rows,
       ROUND(ingested_rows::numeric / total_rows * 100, 1) AS pct,
       status, started_at
FROM cnra.pipeline_runs ORDER BY started_at DESC LIMIT 5;

-- Chunk-level progress (one row per 50k-row chunk)
SELECT COUNT(*) AS chunks_done,
       SUM(rows_inserted) AS rows_inserted,
       SUM(rows_inserted)::float / 50000 AS effective_chunks
FROM cnra.chunk_progress
WHERE job_id = 'gw-...'
  AND completed_at IS NOT NULL;

-- County stats after analytics stage
SELECT county_name, measurement_count,
       ROUND(avg_depth_ft, 1) AS avg_depth_ft,
       trend_delta_ft,
       trend, LEFT(ai_narrative, 80) AS narrative
FROM cnra.county_stats
ORDER BY measurement_count DESC;
```

The Strand dashboard also shows every workflow and activity in real time:

```bash
cd ../../loom && npm run dev   # → http://localhost:5173
# namespace: groundwater-pipeline
```

---

## Crash recovery

Strand stores all state in PostgreSQL. If the process is killed mid-run:

```bash
# Resume without starting a new pipeline
RESUME_ONLY=true swift run GroundwaterPipeline
```

Workers will claim any pending/sleeping tasks and continue from exactly where
they left off. Completed chunks are not re-downloaded (`chunk_progress` guards
against it via `ON CONFLICT (job_id, chunk_offset) DO NOTHING`).

---

## Performance

Full pipeline on a MacBook Pro (M-series), Postgres on localhost:

| Stage | Rows / items | Time |
|---|---|---|
| Ingestion | 6.2M rows across 125 chunks | ~25–30 min |
| Stats | 58 county SQL aggregates | < 30 s |
| AI analysis | 58 Ollama calls (qwen3) | ~3–5 min |
| **Total** | | **~30–35 min** |

The main bottleneck is the CNRA API rate — each chunk is a separate HTTP
request to `data.cnra.ca.gov`. With 20 concurrent ingestion workers the
API is the limit, not Postgres or Swift.

---

## File layout

```
Sources/GroundwaterPipeline/
├── cnra_schema.sql                  SQL schema (partitioned tables + indexes)
├── Types.swift                      All domain types, CSV parser, constants
├── GroundwaterPipelineExample.swift @main — 4 worker pools, ServiceGroup
├── Activities/
│   ├── DiscoverActivity.swift       CKAN API → total row count
│   ├── DiscoverCountiesActivity.swift  SELECT DISTINCT county_name
│   ├── DownloadAndInsertActivity.swift  Stream → parse → UNNEST insert
│   ├── ComputeCountyStatsActivity.swift SQL aggregates + trend delta
│   └── OllamaTrendActivity.swift    qwen3 JSON classification + narrative
└── Workflows/
    ├── GroundwaterPipelineWorkflow.swift  Main 3-stage orchestrator
    ├── IngestChunkWorkflow.swift    Wraps DownloadAndInsertActivity
    ├── StatsWorkflow.swift          County fan-out for SQL stats
    └── AIAnalysisWorkflow.swift     County fan-out for Ollama + FetchCountyStats
```
