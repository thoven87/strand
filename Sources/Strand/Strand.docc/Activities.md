# Defining activities

Activities are the leaf units of work — the only place where I/O, network
calls, and database writes live.

## Protocol-based definition

Implement ``Activity`` to define a dependency-injected, independently
retried unit of work:

```swift
struct FetchWeatherActivity: Activity {
    typealias Input  = WeatherInput
    typealias Output = WeatherResult

    struct WeatherInput:  Codable, Sendable { let city: String }
    struct WeatherResult: Codable, Sendable { let tempC: Double; let conditions: String }

    func run(input: WeatherInput, context: ActivityContext) async throws -> WeatherResult {
        let response = try await weatherAPI.fetch(city: input.city)
        return WeatherResult(tempC: response.temperature, conditions: response.conditions)
    }
}
```

The type system enforces that `Input` and `Output` are `Codable` and `Sendable`.
Strand serialises them as BYTEA JSON blobs in Postgres.

## Registering activities on a worker

Pass activity instances in the `activities:` array when constructing ``StrandWorker``:

```swift
let worker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(queue: "default"),
    workflows: [OrderWorkflow.self],
    activities: [
        FetchWeatherActivity(),
        ChargeCardActivity(stripe: stripeClient),
        ShipOrderActivity(fulfillment: fulfillmentClient),
    ]
)
```

Activities that share dependencies can be grouped via ``ActivityContainerProtocol``:

```swift
struct PaymentActivities: ActivityContainerProtocol {
    let stripe: StripeClient

    var activities: [any ActivityBox] {
        [ChargeCardActivity(stripe: stripe),
         RefundCardActivity(stripe: stripe)]
    }
}

let worker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(queue: "default"),
    activityContainers: [PaymentActivities(stripe: stripe)]
)
```

## Retries and timeouts

All `ActivityOptions` fields are optional — omit any you don’t need and the
worker default applies.

Control retry behaviour per call-site via ``ActivityOptions``:

```swift
let weather = try await context.runActivity(
    FetchWeatherActivity.self,
    input: .init(city: "Paris"),
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

Set defaults on the activity type itself to avoid repeating options at every call-site:

```swift
struct FetchWeatherActivity: Activity {
    static var defaultMaxAttempts: Int? { 5 }
    static var defaultTimeout: Duration? { .seconds(10) }
    // ...
}
```

## Long-running activities — heartbeats

### Liveness heartbeat

For activities that take more than `claimTimeout` to complete, call
`context.heartbeat()` periodically. Each call extends the Postgres lease
(`lease_expires_at`) so the expiry sweep doesn’t re-queue the task while
it is still running:

```swift
func run(input: ProcessInput, context: ActivityContext) async throws -> ProcessResult {
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
struct IngestFileActivity: Activity {
    typealias Input  = FileInput
    typealias Output = StrandVoid

    func run(input: FileInput, context: ActivityContext) async throws -> StrandVoid {
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
        return .done
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
    SendEmailActivity.self,
    input: .init(to: "alice@example.com", subject: "Welcome!")
)
// result.taskID lets you poll for completion later
```

## No-output activities

Use ``StrandVoid`` as the `Output` type when the activity performs a side effect
and returns no meaningful value:

```swift
struct SendEmailActivity: Activity {
    typealias Input  = EmailInput
    typealias Output = StrandVoid

    func run(input: EmailInput, context: ActivityContext) async throws -> StrandVoid {
        try await smtp.send(to: input.address, body: input.body)
        return .done
    }
}
```
