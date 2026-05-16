# Versioning workflows

Three strategies for safely changing workflow logic in a running system.

## Overview

Strand replays every workflow activation from its checkpoint history. Replay
is only correct if the Swift code produces the same sequence of
`runActivity` / `sleep` / `waitForEvent` calls on every activation of the
same workflow instance. Changing that sequence mid-flight — deploying new code
while workflows are sleeping — can corrupt checkpoint mapping and cause replays
to resume at the wrong suspension point.

Three strategies address this. Choose the one that fits your workflow's
lifetime.

## Strategy 1 — Type-name versioning

Define a new workflow type (`OrderWorkflowV2`) alongside the original. Register
both on workers during the transition window so in-flight V1 instances can
drain while new enqueues already use V2.

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

Once all V1 instances reach a terminal state, remove `OrderWorkflowV1`, drop
the `typealias`, and stop registering the old type.

**Best for:** short-lived workflows where the old fleet drains within hours.

## Strategy 2 — Queue-name versioning

Old workers listen on `"orders-v1"`, new workers on `"orders-v2"`. Route new
tasks to the new queue at enqueue time.

```swift
try await client.startWorkflow(
    OrderWorkflow.self,
    options: WorkflowOptions(queue: "orders-v2"),
    input: order
)
```

In-flight instances on `"orders-v1"` drain naturally; old workers can be
retired once that queue is empty.

**Best for:** cases where many workflow types share a queue and a single rename
covers all of them.

## Strategy 3 — Inline patching with `context.version(changeID:)`

Add a named version gate inside the handler. New workflow instances take the
new code path. In-flight instances replay the value stored when they first
encountered that gate.

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

        // Deploying a fraud-check step. New and in-flight workflows that
        // reach this gate for the first time take the new path.
        if context.version(changeID: "add-fraud-check") {
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

> **Note:** `version(changeID:)` does not throw and does not `await`. It is
> a synchronous lookup against a named boolean stored in
> `strand.workflow_version_markers` — not a suspension point. Do not prefix
> calls with `try`.

**Best for:** long-running workflows that cannot be drained and restarted
within a reasonable window (days or weeks).

### How `version(changeID:)` works

``WorkflowContext/version(changeID:)`` stores its value in
`strand.workflow_version_markers`, keyed by `changeID` — not by position in
the activation sequence. This has two important consequences:

**It can be called anywhere.** Unlike `runActivity`, `sleep`, and
`waitForEvent`, `version(changeID:)` does not consume a sequence number. You
can call it conditionally, inside branches, or inside loops without affecting
the replay determinism of other operations.

```swift
// ✓ Fine — conditional placement does not shift downstream seq_nums.
if needsUpgrade {
    if context.version(changeID: "v2-payment") {
        // new path
    }
}
let result = try await context.runActivity(A.self, input: x)  // stable seqNum
```

**Replay is name-based.** At every activation start, Strand loads all version
markers for the task from `strand.workflow_version_markers` into an in-memory
cache. When `version(changeID:)` is called, it returns the cached value for
that `changeID`. The first-ever call (no row exists yet) writes `true` and
returns it.

### Deployment procedure

1. Add the `context.version(changeID:)` guard and the new code path inside it.
2. Deploy the updated binary.
3. Optionally pin specific in-flight workflows to the old path (see below).
4. Once all pre-deploy instances complete, remove the `else` branch and the
   version guard in a follow-up deploy.

### Pinning in-flight workflows to the old path

``StrandClient/markVersion(changeID:value:taskID:)`` writes a version marker
directly to `strand.workflow_version_markers`. On the workflow's next
activation the marker is loaded and `version(changeID:)` returns the stored
value.

```swift
// Pin each in-flight workflow to the pre-deploy code path:
for id in inFlightTaskIDs {
    try await client.markVersion(
        changeID: "add-fraud-check",
        value: false,    // false → old path; true → new path (default)
        taskID: id
    )
}
```

`markVersion` is an upsert — calling it multiple times is safe:

- **Same value:** idempotent. Calling `markVersion(value: false)` three times
  leaves the marker at `false` with an updated `markedAt` timestamp.
- **Different value:** last write wins. You can reverse a pinning decision by
  calling `markVersion(value: true)` — the workflow will take the new path on
  its next activation.
- **Timing:** `markVersion` can be called at any time. If the workflow has
  already passed the gate in its current activation, the new value takes
  effect on the following activation.

### Knowing when it is safe to remove the old branch

``StrandClient/migrationStatus(changeID:)`` returns a ``MigrationStatus`` that
tells you at a glance:

```swift
let status = try await client.migrationStatus(changeID: "add-fraud-check")

if status.isSafeToRemove {
    // Every in-flight workflow has passed the gate on the new path.
    // Safe to delete the else branch in the next deploy.
} else {
    print("\(status.pendingCount) workflows still on the old path")
    print("\(status.completedCount) workflows on the new path")
}
```

Once `isSafeToRemove` is `true`, the `else` branch is unreachable and can be
deleted.

## Multi-step migrations

For two successive breaking changes, use two independent `changeID` strings.
Each gate is independent — there is no ordering constraint between them.

```swift
let isV2 = context.version(changeID: "add-fraud-check")
let isV3 = context.version(changeID: "parallel-charge")

if isV3 {
    // current code path — both changes applied
    let fraud = try await context.runActivity(FraudCheckActivity.self, input: x)
    async let charge = context.runActivity(ChargeCardActivity.self, input: x)
    async let ship   = context.runActivity(ShipOrderActivity.self,   input: x)
    _ = try await (charge, ship)
} else if isV2 {
    // intermediate path — only fraud-check applied
    let fraud  = try await context.runActivity(FraudCheckActivity.self, input: x)
    let charge = try await context.runActivity(ChargeCardActivity.self, input: x)
    _          = try await context.runActivity(ShipOrderActivity.self,  input: x)
} else {
    // original path
    let charge = try await context.runActivity(ChargeCardActivity.self, input: x)
    _          = try await context.runActivity(ShipOrderActivity.self,  input: x)
}
```

To pin a workflow to the original path, call `markVersion` for both gates:

```swift
try await client.markVersion(changeID: "add-fraud-check", value: false, taskID: id)
try await client.markVersion(changeID: "parallel-charge", value: false, taskID: id)
```

Each call is an independent upsert — order does not matter.

## Build-ID-based worker routing — not needed

Some workflow engines route task-queue polls to workers that advertise a
specific build ID, maintaining a version-sets graph per queue in a coordination
service that makes the routing decision at dispatch time.

Strand has no separate coordination service. Equivalent routing would require
embedding a version graph into the PostgreSQL claim query — significant
operational complexity for a problem that Strategy 2 already solves at enqueue
time. When you write `WorkflowOptions(queue: "orders-v2")`, the routing
decision is stored durably in `strand.tasks.queue` and requires no in-flight
state in any server process.

## Choosing a strategy

| Situation | Recommended strategy |
|---|---|
| Workflow completes in < 1 hour | 1 — type-name or 2 — queue-name |
| Many workflow types share a queue | 2 — queue-name |
| Workflow can run for days or weeks | 3 — inline patching |
| Breaking change touches only one of N workflow types on a queue | 3 — inline patching |
| You need an audit trail of which code path each instance took | 3 — version markers visible in the Loom dashboard |

## Topics

### Versioning API
- ``WorkflowContext/version(changeID:)``
- ``StrandClient/markVersion(changeID:value:taskID:)``
- ``StrandClient/migrationStatus(changeID:)``
- ``MigrationStatus``
