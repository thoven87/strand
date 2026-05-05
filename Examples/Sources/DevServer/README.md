# DevServer

A local development backend that runs the Strand HTTP API server alongside
two worker pools and a live seeder. Used as the backend for the Loom dashboard
during local development.

---

## What it runs

| Component | Detail |
|---|---|
| HTTP API | Hummingbird server on `http://localhost:8080` |
| `orders` worker | `workflowConcurrency: 4`, `activityConcurrency: 8` |
| `reports` worker | `workflowConcurrency: 2`, `activityConcurrency: 4` |
| Seeder | Creates new workflow tasks every 30 s so the dashboard always has live data |

---

## Prerequisites

- PostgreSQL 15+ on `localhost:5499`

```bash
psql "postgresql://strand:strand@localhost:5499/strand_dev" -f ../../../strand.sql
```

---

## Quick start

```bash
# Terminal 1 — API server + workers
cd Examples
swift run DevServer

# Terminal 2 — Loom dashboard
cd loom
npm install   # first time only
npm run dev   # → http://localhost:5173
```

The dashboard proxies `/api` to `http://localhost:8080` automatically.

---

## What you'll see

- The **Tasks** page fills up with `OrderWorkflow` and `DailyReportWorkflow`
  tasks as the seeder fires every 30 s.
- Workflows run through PENDING → RUNNING → COMPLETED with activities visible
  in the trace view.
- The **Workers** page shows the two active worker processes with live
  `runningTasks` and `completedRecently` counts.
- The **Queues** page shows per-state breakdowns for `orders` and `reports`.

---

## Configuration

| Environment variable | Default | Description |
|---|---|---|
| `POSTGRES_HOST` | `localhost` | Postgres host |
| `POSTGRES_PORT` | `5499` | Postgres port |
| `POSTGRES_USER` | `strand` | Username |
| `POSTGRES_PASSWORD` | `strand` | Password |
| `POSTGRES_DB` | `strand_dev` | Database |
