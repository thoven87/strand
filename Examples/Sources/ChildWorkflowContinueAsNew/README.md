# Child Workflow Continue-As-New

Demonstrates that when a **child workflow** calls `continueAsNew`, the parent
is **not** notified of the intermediate runs — it receives a single completion
signal only when the full chain finishes.

## What this example shows

```
ParentWorkflow
    └── runChildWorkflow(ChildWorkflow, totalRuns: 5)
            │
            ├── ChildWorkflow run 1  → continueAsNew(totalCount: 1, remainingRuns: 4)
            ├── ChildWorkflow run 2  → continueAsNew(totalCount: 2, remainingRuns: 3)
            ├── ChildWorkflow run 3  → continueAsNew(totalCount: 3, remainingRuns: 2)
            ├── ChildWorkflow run 4  → continueAsNew(totalCount: 4, remainingRuns: 1)
            └── ChildWorkflow run 5  → return "completed after 5 runs"
                        │
                        └── Parent wakes once, receives result, completes
```

Key behaviours demonstrated:

- **Parent transparency** — the parent calls `runChildWorkflow` once and
  blocks. It never wakes for intermediate `continueAsNew` hops.
- **History isolation** — each child run starts with zero prior history,
  keeping `loadCompletedChildActivities` O(1) per child activation regardless
  of how many iterations the chain has processed.
- **Single result delivery** — only the final child run (when `remainingRuns`
  reaches 0) produces a result; intermediate runs return `Never` via
  `continueAsNew`.

## Why this matters in practice

Without `continueAsNew`, a child processing a large dataset would accumulate
one history entry per item. After thousands of items, each parent re-activation
must scan all completed children — quadratic total cost. `continueAsNew` caps
the per-run history at a constant size.

See `HHAXDailySyncWorkflow` in the lhcsa ETL pipeline for a production use of
this pattern: the parent hands off to `HHAXBillingSyncWorkflow` as a child, and
the child processes ~100 billing batches with fresh history.

## Run

```bash
# Prerequisites: Postgres at localhost:5499 with strand.sql applied
cd Examples
swift run ChildWorkflowContinueAsNew
```

## Watch in Loom

Start the Loom dashboard (`cd loom && npm run dev`) and open
`http://localhost:5173`. Navigate to the `ChildWorkflow` task to see:

- **Chain tab** — all 5 child runs linked with run numbers and states
- **CONTINUED_AS_NEW** badge on runs 1–4
- **COMPLETED** badge on run 5
- Parent task wakes exactly once after run 5 completes
