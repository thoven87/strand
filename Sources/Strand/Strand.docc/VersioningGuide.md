# Versioning workflows

Three strategies for safely changing workflow logic in a running system.

## Overview

Strand replays every workflow activation from its checkpoint history. That
replay is only correct if the Swift code produces the same sequence of
`runActivity` / `sleep` / `waitForEvent` calls on every activation of the
same workflow instance. Changing that sequence mid-flight — by deploying new
code while workflows are in-flight — can corrupt checkpoint mapping and cause
replays to resume at the wrong suspension point.

Three strategies address this problem. Choose the one that fits your workflow's
lifetime.

## Strategy 1 — Type-name versioning

Define a new workflow type (`OrderWorkflowV2`) alongside the original. Register
both types on workers during the transition window so that in-flight V1
instances can continue draining while new enqueues already use V2.

```swift
// Both types registered on workers during the transition window:
StrandWorker(
    workflows: [OrderWorkflowV1.self, OrderWorkflowV2.self],
    ...
)

// A typealias keeps all enqueue call sites unchanged:
typealias OrderWorkflow = OrderWorkflowV2

try await client.startWorkflow(OrderWorkflow.self, ...)   // enqueues V2
```

Once all V1 instances reach a terminal state, remove `OrderWorkflowV1` and the
`typealias`, and stop registering the old type.

**Best for:** short-lived workflows where the old fleet drains within hours.

## Strategy 2 — Queue-name versioning

Old workers listen on `"orders-v1"`, new workers on `"orders-v2"`. Route new
tasks to the new queue at enqueue time.

```swift
// Enqueue new tasks onto the v2 queue:
try await client.startWorkflow(
    OrderWorkflow.self,
    options: WorkflowOptions(queue: "orders-v2"),
    input: order
)
```

In-flight instances on `"orders-v1"` drain naturally; old workers can be
retired once that queue is empty.

**Best for:** cases where many workflow types share a queue and a single queue
rename covers all of them.

## Strategy 3 — Inline patching with `context.version(changeID:)`

Add a version guard inside the handler. New workflow instances take the new
code path and store `true` as a checkpoint. In-flight instances that have
already passed the guard replay whatever value was stored on their first
encounter.

```swift
struct OrderWorkflow: Workflow {
    mutating func run(
        context: WorkflowContext<Self>,
        input: OrderInput
    ) async throws -> OrderResult {
        let charge = try await context.runActivity(
            ChargeCardActivity.self,
            input: .init(amount: input.total)
        )

        // Deploying a fraud-check step. New workflows run it; in-flight
        // workflows that ran past this point before the deploy skip it.
        if try context.version(changeID: "add-fraud-check") {
            try await context.runActivity(
                FraudCheckActivity.self,
                input: .init(paymentID: charge.paymentID)
            )
        }

        return try await context.runActivity(
            ShipOrderActivity.self,
            input: .init(paymentID: charge.paymentID)
        )
    }
}
```

**Best for:** long-running workflows that cannot be drained and restarted
within a reasonable window (days or weeks).

### Deployment procedure

1. Add the `context.version(changeID:)` guard and the new code path.
2. Deploy the updated binary to a canary worker.
3. Optionally mark all in-flight workflows to use the old path (see below).
4. Roll out the remaining workers.
5. Once all pre-deploy instances complete, remove the `else` branch and the
   version guard in a follow-up deploy.

### Marking in-flight workflows

``StrandClient/markVersion(changeID:value:taskID:callSiteIndex:)`` writes a
version checkpoint directly into the database. Call it while the workflow is
SLEEPING — between activations — so the checkpoint is in place when the next
activation loads its cache.

```swift
// Find in-flight task IDs from the Loom dashboard, a query, or your own
// bookkeeping, then pin each one to the pre-deploy code path:
for id in inFlightTaskIDs {
    try await client.markVersion(
        changeID: "add-fraud-check",
        value: false,    // false → old path; true → new path
        taskID: id
    )
}
```

> **Tip:** Poll the workflow's state until it is `.sleeping` before calling
> `markVersion`. If the workflow hasn't yet reached the `version(changeID:)`
> call point, `markVersion` estimates the target sequence number. That
> estimate is reliable as long as you call `markVersion` while the workflow is
> in a sleep — not while it is actively running.

## Determinism: always call `version` unconditionally

``WorkflowContext/version(changeID:)`` consumes a **sequence number** from the
same monotonic counter as ``WorkflowContext/runActivity(_:input:options:fileID:line:)``,
``WorkflowContext/sleep(for:fileID:line:)`` and
``WorkflowContext/waitForEvent(_:as:timeout:fileID:line:)``. Every context call
must appear in the same position in the control flow on every activation of the
same workflow instance.

Placing `version(changeID:)` inside a branch whose condition changes between
activations shifts all downstream sequence numbers and corrupts checkpoint
replay.

```swift
// ✗ WRONG — version() only reached when isPaused is true.
//   If isPaused changes between activations, downstream seqNums shift.
if isPaused {
    let _ = try context.version(changeID: "v2-feature")
}
let result = try await context.runActivity(A.self, input: x)  // ← wrong seqNum

// ✓ CORRECT — version() is always reached; its return value drives branching.
let useV2 = try context.version(changeID: "v2-feature")
if isPaused && useV2 { ... }
let result = try await context.runActivity(A.self, input: x)  // ← stable seqNum
```

The same rule applies to all context calls. `version(changeID:)` is no
different — it is just easy to overlook because it doesn't `await`.

## Multi-step migrations

For two successive breaking changes, use two independent `changeID` strings and
call both unconditionally. The latest changeID takes precedence in the
branching logic.

```swift
// Both calls are unconditional. Each gets its own stable sequence number.
let isV2 = try context.version(changeID: "add-fraud-check")
let isV3 = try context.version(changeID: "parallel-charge")

if isV3 {
    // current code path — both new changes applied
    let fraud = try await context.runActivity(FraudCheckActivity.self, input: x)
    async let charge = context.runActivity(ChargeCardActivity.self, input: x)
    async let ship   = context.runActivity(ShipOrderActivity.self, input: x)
    _ = try await (charge, ship)
} else if isV2 {
    // intermediate path — only the fraud-check change applied
    let fraud = try await context.runActivity(FraudCheckActivity.self, input: x)
    let charge = try await context.runActivity(ChargeCardActivity.self, input: x)
    _ = try await context.runActivity(ShipOrderActivity.self, input: x)
} else {
    // original path
    let charge = try await context.runActivity(ChargeCardActivity.self, input: x)
    _ = try await context.runActivity(ShipOrderActivity.self, input: x)
}
```

### `callSiteIndex` for multi-step `markVersion`

When marking in-flight workflows that haven't yet reached any version call,
the sequence-number estimate is:

```
seqNum = (count of already-written checkpoints) + callSiteIndex
```

To mark two consecutive version calls in the same sleep window, call
`markVersion` for the earlier changeID first (with `callSiteIndex: 1`),
then for the later one (also `callSiteIndex: 1` — the count has advanced):

```swift
// Workflow structure: sleep(seqNum 1), version("add-fraud-check", seqNum 2),
//                    version("parallel-charge", seqNum 3)
// While sleeping (1 checkpoint written):
try await client.markVersion(changeID: "add-fraud-check",  value: false, taskID: id)
// ↑ count=1, callSiteIndex=1 → seqNum=2 ✓. Count is now 2.
try await client.markVersion(changeID: "parallel-charge", value: false, taskID: id)
// ↑ count=2, callSiteIndex=1 → seqNum=3 ✓
```

To mark only the second changeID without touching the first, pass
`callSiteIndex: 2` in a single call (before any prior `markVersion` has run):

```swift
try await client.markVersion(changeID: "parallel-charge", value: false,
                              taskID: id, callSiteIndex: 2)
// count=1, callSiteIndex=2 → seqNum=3 ✓
```

## Build-ID-based worker routing — not needed

Some workflow engines route task-queue polls to workers that advertise a
specific build ID, maintaining a version-sets graph per queue in a coordination
service that makes the routing decision at dispatch time.

Strand has no separate coordination service. Equivalent routing would require
embedding a version graph into the PostgreSQL claim query — significant
operational complexity for a problem that Strategy 2 already solves at enqueue
time. When you write `WorkflowOptions(queue: "orders-v2")`, the routing
decision is stored durably in `strand.tasks.queue` and requires no in-flight
state in any server process. That is simpler, not weaker.

## Choosing a strategy

| Situation | Recommended strategy |
|---|---|
| Workflow completes in < 1 hour | 1 — type-name or 2 — queue-name |
| Many workflow types share a queue | 2 — queue-name |
| Workflow can run for days or weeks | 3 — inline patching |
| Breaking change touches only one of N workflow types on a queue | 3 — inline patching |
| You need an audit trail of which code path each instance took | 3 — checkpoint is visible in the Loom dashboard |

## Topics

### Versioning API
- ``WorkflowContext/version(changeID:)``
- ``StrandClient/markVersion(changeID:value:taskID:callSiteIndex:)``
