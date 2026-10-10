# Batch Sliding Window

## What it demonstrates

| Concept | Where |
|---|---|
| **Cross-workflow signal** | `RecordProcessorWorkflow` → `SlidingWindowWorkflow` via `context.signalExternalWorkflow` |
| **`@WorkflowSignal` handler** | `SlidingWindowWorkflow.recordCompleted(_ id: Int)` |
| **`context.condition` throttling** | Blocks dispatch until `activeCount < windowSize` |
| **`context.startChildWorkflow` fire-and-forget** | `SlidingWindowWorkflow` launches each `RecordProcessorWorkflow` without waiting |
| **`context.continueAsNew`** | `SlidingWindowWorkflow` resets history between pages |
| **`context.suggestContinueAsNew`** | Advisory property (logged at each page boundary) |
| **Parallel child workflow fan-out** | `BatchWorkflow` runs N `SlidingWindowWorkflow` children simultaneously |

## Signal flow

```
RecordProcessorWorkflow
  └── ProcessRecord activity (simulates work via sleep)
  └── context.signalExternalWorkflow(SlidingWindowWorkflow.RecordCompleted, taskID: parentID, payload: recordID)
              │
              ▼
SlidingWindowWorkflow
  └── @WorkflowSignal recordCompleted(_ id: Int)
        activeRecords.remove(id); progress += 1
  └── context.condition { activeRecords.count < windowSize }
        unblocks when a slot is free
```

## Architecture

```
BatchWorkflow
  ├── GetRecordCount activity
  └── runChildWorkflow(SlidingWindowWorkflow) × N partitions (parallel via withThrowingTaskGroup)
        SlidingWindowWorkflow
          ├── GetRecords activity (generates synthetic records)
          ├── for each record:
          │     context.condition { activeRecords.count < windowSize }
          │     context.startChildWorkflow(RecordProcessorWorkflow, parentClosePolicy: .abandon)
          └── @WorkflowSignal recordCompleted(_ id: Int)
                  activeRecords.remove(id); progress += 1
          └── continueAsNew when more pages remain (history reset, in-flight children survive)
                RecordProcessorWorkflow
                  ├── ProcessRecord activity (sleep)
                  └── context.signalExternalWorkflow(SlidingWindowWorkflow.RecordCompleted, …)
```

## Run

```bash
cd Examples
swift run BatchSlidingWindow
```

Prerequisites: Postgres running at `localhost:5499` (see `docker-compose.yml` in the root).
