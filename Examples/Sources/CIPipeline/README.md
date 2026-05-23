# CI/CD Pipeline

A durable CI/CD pipeline modelled as a Strand workflow. If a build worker
crashes during any stage, the pipeline resumes from the last completed step
on restart — no work is lost, no stage runs twice.

---

## What it demonstrates

| Strand feature | Where |
|---|---|
| Parallel activity fan-out | Lint + unit tests + security scan run simultaneously via `async let` |
| Automatic retry | `UnitTestActivity` fails on attempt 1, passes on attempt 2 |
| Signal-based approval gate | `context.condition` suspends until an `approve` signal arrives |
| `WorkflowSignal` | Typed `handle.signal(CIPipelineWorkflow.Approve.self, payload:)` |
| Durability under crash | Kill the process at any stage; restart resumes from the last checkpoint |

---

## Pipeline stages

```
[ 1 ] Checkout          clone the repo
[ 2 ] Quality Gates     lint + unit tests + security scan (all parallel)
[ 3 ] Build             compile release artifact
[ 4 ] Approval Gate     wait for an operator to send the "approve" signal
[ 5 ] Deploy            rolling update across instances
```

---

## Prerequisites

- PostgreSQL 15+ on `localhost:5499`

```bash
psql "postgresql://strand:strand@localhost:5499/strand_dev" -f ../../../strand.sql
```

---

## Quick start

```bash
cd Examples
swift run CIPipeline
```

The demo sends an approval signal automatically after ~18 s so the pipeline
runs end-to-end without manual intervention.

---

## Sending the approval signal manually

To try the approval gate interactively, comment out the auto-approve `Task` in
`CIPipelineExample.swift`, then send the signal from a second terminal once the
pipeline reaches stage 4:

```swift
// In your own code or the REPL:
let client = StrandClient(postgres: postgres, queue: "ci-pipeline",
                          namespace: "ci-pipeline-demo")
let handle = client.workflowHandle(id: taskID, as: CIPipelineWorkflow.self)
try await handle.signal(
    CIPipelineWorkflow.Approve.self,
    payload: ApprovalDecision(approved: true, approver: "alice")
)
```

Or from the **Loom dashboard**: open the task → **Send Signal**:

| Field | Value |
|---|---|
| Signal name | `approve` |
| Payload | `{"approved": true, "approver": "alice"}` |

To reject the deployment: `{"approved": false, "approver": "alice"}`.

---

## Crash recovery demo

Kill the process at any point during the run (`Ctrl-C`). Restart with
`swift run CIPipeline`. Because each stage is a checkpointed activity, the
pipeline resumes from the last completed stage — try killing during the Build
stage and watch it skip Checkout and Quality Gates on restart.
