# DevServer

A local development backend that runs the Strand HTTP API server alongside
two worker pools and a live seeder. Used as the backend for the Loom dashboard
during local development. Exports traces, metrics, and logs to
[Jaeger](https://www.jaegertracing.io/) via OTLP/gRPC using
[swift-otel](https://github.com/swift-otel/swift-otel).

---

## What it runs

| Component | Detail |
|---|---|
| HTTP API | Hummingbird on `http://localhost:8080` |
| `orders` worker | `workflowConcurrency: 4`, `activityConcurrency: 8` |
| `reports` worker | `workflowConcurrency: 2`, `activityConcurrency: 4` |
| Seeder | New workflow tasks every 30 s — keeps the dashboard live |
| OTel exporter | OTLP/gRPC → Jaeger on `localhost:4317` (no auth needed) |

---

## Prerequisites

```bash
# Start Postgres + Jaeger
podman compose up -d

# Apply schema (first time only)
PGPASSWORD=strand psql -h 127.0.0.1 -p 5499 -U strand -d strand_dev \
    -f ../../../strand.sql
```

---

## Quick start

```bash
# Terminal 1 — API server + workers
cd Examples && swift run DevServer

# Terminal 2 — Loom dashboard
cd loom && npm run dev   # → http://localhost:5173

# Terminal 3 — Jaeger UI
open http://localhost:16686
# Select service: strand-devserver
```

No environment variables needed — DevServer connects to Jaeger on the
default OTLP gRPC port (`4317`) with no authentication.

---

## What you'll see in Jaeger

Open `http://localhost:16686`, select **strand-devserver** from the service
dropdown, and click **Find Traces**.

Each workflow execution appears as a trace. Expand any trace to see the full
span tree — from `StrandWorker.claimRun` down through checkpoint replay and
every activity execution, with durations at each level.

---

## Using a different collector

Set `OTEL_EXPORTER_OTLP_ENDPOINT` and optionally `OTEL_EXPORTER_OTLP_AUTH`
to point at any OTLP/gRPC-compatible backend:

```bash
# Honeycomb
OTEL_EXPORTER_OTLP_ENDPOINT=https://api.honeycomb.io:443 \
OTEL_EXPORTER_OTLP_AUTH=<your-api-key> \
swift run DevServer

# SigNoz (self-hosted)
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
swift run DevServer
```

---

## Configuration

| Environment variable | Default | Description |
|---|---|---|
| `POSTGRES_HOST` | `localhost` | Postgres host |
| `POSTGRES_PORT` | `5499` | Postgres port |
| `POSTGRES_USER` | `strand` | Username |
| `POSTGRES_PASSWORD` | `strand` | Password |
| `POSTGRES_DB` | `strand_dev` | Database |
| `OTEL_SERVICE_NAME` | `strand-devserver` | Service name in traces |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4317` | OTLP gRPC endpoint |
| `OTEL_EXPORTER_OTLP_AUTH` | *(none)* | Base64 `user:pass` for auth-required collectors |
| `OTEL_ENABLE_LOGS` | `false` | Set `true` for collectors that support log ingestion |
| `OTEL_ENABLE_METRICS` | `false` | Set `true` for collectors that support metrics ingestion |
