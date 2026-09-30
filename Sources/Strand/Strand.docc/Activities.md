# Defining activities

Activities are the leaf units of work — the only place where I/O, network
calls, and database writes live.

## Defining activities with `@ActivityContainer`

Group related activities inside a struct annotated with `@ActivityContainer`.
Each method annotated with `@Activity` becomes a standalone, independently
retried unit of work. Dependencies (clients, DB connections) are stored as
properties on the container and shared across all methods:

```swift
@ActivityContainer
struct PaymentActivities {
    let stripe: StripeClient

    @Activity
    func chargeCard(input: ChargeInput, context: ActivityContext) async throws -> ChargeResult {
        let charge = try await stripe.charges.create(
            amount: input.amountCents,
            currency: "usd",
            customer: input.customerID,
            idempotencyKey: context.taskID.uuidString  // stable across retries
        )
        return ChargeResult(chargeID: charge.id)
    }

    @Activity
    func refund(input: RefundInput, context: ActivityContext) async throws -> RefundResult {
        let refund = try await stripe.refunds.create(chargeID: input.chargeID)
        return RefundResult(refundID: refund.id)
    }
}
```

The generated types are accessed as nested types on the container —
`PaymentActivities.ChargeCard` and `PaymentActivities.Refund` — and
registered with the worker via `activityContainers:`:

```swift
let worker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(queue: "default"),
    workflows: [OrderWorkflow.self],
    activityContainers: [
        PaymentActivities(stripe: stripeClient),
        ShippingActivities(fulfillment: fulfillmentClient),
    ]
)
```

Activities with no return value omit the return type:

```swift
@ActivityContainer
struct EmailActivities {
    let smtp: SMTPClient

    @Activity
    func send(input: EmailInput, context: ActivityContext) async throws {
        try await smtp.send(to: input.address, body: input.body)
        // no return statement needed
    }
}
```

## Retries and timeouts

All `ActivityOptions` fields are optional — omit any you don't need and the
worker default applies.

Control retry behaviour per call-site via ``ActivityOptions``:

```swift
let result = try await context.runActivity(
    PaymentActivities.ChargeCard.self,
    input: .init(amountCents: 1000, customerID: id),
    options: ActivityOptions(
        timeout: .seconds(30),           // max time per attempt
        maxAttempts: 5,
        retryStrategy: .backoff(initial: .seconds(1), multiplier: 2, cap: .seconds(30)),
        heartbeatTimeout: .seconds(10)   // re-queue if no heartbeat within 10 s
    )
)
```

`heartbeatTimeout` lets you detect a stuck activity quickly without needing a
very short `claimTimeout`. For example, `timeout: .hours(2), heartbeatTimeout: .seconds(30)`
gives the activity two hours to complete per attempt but re-queues it within 30 s
if it stops heartbeating — useful for catching infinite loops or blocked I/O long
before the StartToClose deadline would fire.

## Idempotency — activities run at least once

Strand guarantees that the **result** of an activity is applied to the parent
workflow exactly once. But the `run(input:context:)` body itself can execute
more than once.

If a worker runs your activity code, the external call succeeds, and then the
worker crashes before the Postgres completion transaction commits — the run is
re-queued and a second worker calls `run` again with the same input. From
Strand's perspective the first execution never happened.

```
Worker A:  run() → charges Stripe → CRASH (before completeRun commits)
Strand:    lease expires → re-queue → Worker B claims same run
Worker B:  run() → charges Stripe again  ← duplicate charge
```

This is the standard model for all durable workflow engines: the state machine
advances exactly once, but the handler body runs at least once. **Activities
must be idempotent** or must use one of the patterns below to detect and skip
duplicate executions.

### Pattern 1 — idempotency key via `context.taskID`

`ActivityContext.taskID` is a stable UUID that is the same on every retry of
the same activity. Use it as the idempotency key when calling external APIs
that support one:

```swift
@Activity
func chargeCard(input: ChargeInput, context: ActivityContext) async throws -> ChargeResult {
    // Stripe deduplicates by idempotency key within 24 h.
    // Using taskID means retries never create duplicate charges.
    let charge = try await stripe.charges.create(
        amount: input.amountCents,
        currency: "usd",
        customer: input.customerID,
        idempotencyKey: context.taskID.uuidString   // ← stable across retries
    )
    return ChargeResult(chargeID: charge.id)
}
```

### Pattern 2 — check-then-act

When the external system doesn't support idempotency keys, query whether the
work was already done before performing it:

```swift
@Activity
func provisionDatabase(input: ProvisionInput, context: ActivityContext) async throws -> ProvisionResult {
    // Safe to call on retry: returns the existing DB if already provisioned.
    if let existing = try await cloud.databases.find(name: input.dbName) {
        return ProvisionResult(host: existing.host)
    }
    let db = try await cloud.databases.create(name: input.dbName, tier: input.tier)
    return ProvisionResult(host: db.host)
}
```

### Pattern 3 — progress heartbeat to skip completed steps

For activities with multiple stages, persist a cursor via `context.heartbeat(_:)`
after each stage. On retry, `context.heartbeatDetails(as:)` returns the last
checkpoint so already-completed stages are skipped entirely:

```swift
@Activity
func migrateData(input: MigrationInput, context: ActivityContext) async throws -> MigrationResult {
    // Pick up from the last committed batch on retry.
    var cursor = context.heartbeatDetails(as: String.self) ?? input.startCursor
    var totalMigrated = 0

    while let page = try await db.fetchPage(after: cursor, limit: 500) {
        try await db.writePage(page)   // idempotent upsert
        cursor = page.nextCursor
        totalMigrated += page.rows.count
        try await context.heartbeat(cursor)  // checkpoint: retry resumes here
    }
    return MigrationResult(totalMigrated: totalMigrated)
}
```

### Pattern 4 — non-retryable errors for validation failures

If an activity can determine early that retrying will never succeed (e.g. the
input is structurally invalid), throw a `NonRetryableError` to stop the retry
loop immediately without waiting for `maxAttempts` to exhaust:

```swift
enum ValidationError: Error, Codable, NonRetryableError {
    case invalidCurrency(String)
    case amountBelowMinimum(Int)
}

@Activity
func chargeCard(input: ChargeInput, context: ActivityContext) async throws -> ChargeResult {
    guard input.amountCents >= 50 else {
        throw ValidationError.amountBelowMinimum(input.amountCents)
        // Strand marks this failed immediately — no retries attempted.
    }
    // ...
}
```

### What is and isn't guaranteed

| Guarantee | Status |
|---|---|
| Activity result applied to workflow exactly once | ✅ `version` CAS + `task_completions ON CONFLICT DO UPDATE` |
| Activity `run()` body executes exactly once | ❌ At-least-once — use idempotency keys or check-then-act |
| `maxAttempts` is respected | ✅ Attempts counter incremented only on explicit failure, not lease expiry |
| Lease expiry does not count as a failed attempt | ✅ `sweepExpiredLeases` re-queues as PENDING at the same attempt number |
| 2× `claimTimeout` watchdog counts as a failed attempt | ✅ `ClaimTimeoutError` goes through `failRun`, increments attempt counter |

## Long-running activities — heartbeats

### Liveness heartbeat

For activities that take more than `claimTimeout` to complete, call
`context.heartbeat()` periodically. Each call extends the Postgres lease
(`lease_expires_at`) so the expiry sweep doesn't re-queue the task while
it is still running:

```swift
@Activity
func processLargeDataset(input: ProcessInput, context: ActivityContext) async throws -> ProcessResult {
    for chunk in largeDataset.chunked(by: 1000) {
        try await process(chunk)
        try await context.heartbeat()   // extend lease; no progress stored
    }
    return ProcessResult(count: largeDataset.count)
}
```

### Progress heartbeat — resume exactly where you left off

Pass a `Codable` value to `context.heartbeat(_:)` to persist progress alongside
the lease extension. On the next retry attempt, `context.heartbeatDetails(as:)`
returns that value so the activity can resume mid-stream instead of restarting
from the beginning:

```swift
@Activity
func ingestFile(input: FileInput, context: ActivityContext) async throws {
    // Pick up from the last checkpoint on retry; start at 0 on the first attempt.
    let startLine = context.heartbeatDetails(as: Int.self) ?? 0

    for (index, line) in file.lines.dropFirst(startLine).enumerated() {
        let lineNumber = startLine + index + 1
        try parseLine(line)

        // Every 500 lines: extend the lease AND store progress.
        if lineNumber.isMultiple(of: 500) {
            try await context.heartbeat(lineNumber)
        }
    }
}
```

Heartbeat details are carried forward automatically on every retry — including
automatic retries (`failRun`) and manual dashboard retries where `resetHistory`
is `false`. A `resetHistory: true` re-run starts fresh with `nil` details.

`context.heartbeatDetails(as:)` returns `nil` on the first attempt or if the
previous attempt never reached a heartbeat call. Always provide a sensible
default (typically `0` or an empty cursor) to handle the first-attempt case.

## Fire-and-forget from the client

Enqueue an activity directly without wrapping it in a workflow:

```swift
let result = try await client.enqueueActivity(
    EmailActivities.Send.self,
    input: .init(to: "alice@example.com", subject: "Welcome!")
)
// result.taskID lets you poll for completion later
```
