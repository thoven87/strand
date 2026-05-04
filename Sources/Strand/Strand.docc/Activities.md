# Defining activities

Activities are the leaf units of work — the only place where I/O, network
calls, and database writes live.

## Protocol-based definition

Implement ``ActivityDefinition`` to define a dependency-injected, independently
retried unit of work:

```swift
struct FetchWeatherActivity: ActivityDefinition {
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

All `ActivityOptions` fields are optional — omit any you don't need and the
worker default applies.

Control retry behaviour per call-site via ``ActivityOptions``:

```swift
let weather = try await context.runActivity(
    FetchWeatherActivity.self,
    input: .init(city: "Paris"),
    options: ActivityOptions(
        maxAttempts: 5,
        retryStrategy: .backoff(initial: .seconds(1), multiplier: 2, cap: .seconds(30))
    )
)
```

Set defaults on the activity type itself to avoid repeating options at every call-site:

```swift
struct FetchWeatherActivity: ActivityDefinition {
    static var defaultMaxAttempts: Int? { 5 }
    static var defaultTimeout: Duration? { .seconds(10) }
    // ...
}
```

## Long-running activities — heartbeats

For activities that take more than `claimTimeout` to complete, call
`context.heartbeat()` periodically. Each heartbeat extends the Postgres lease
(`lease_expires_at`) so the lease expiry sweep doesn't re-queue the task while
it's still running:

```swift
func run(input: ProcessInput, context: ActivityContext) async throws -> ProcessResult {
    for chunk in largeDataset.chunked(by: 1000) {
        try await process(chunk)
        try await context.heartbeat()   // push lease forward
    }
    return ProcessResult(count: largeDataset.count)
}
```

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
struct SendEmailActivity: ActivityDefinition {
    typealias Input  = EmailInput
    typealias Output = StrandVoid

    func run(input: EmailInput, context: ActivityContext) async throws -> StrandVoid {
        try await smtp.send(to: input.address, body: input.body)
        return .done
    }
}
```
