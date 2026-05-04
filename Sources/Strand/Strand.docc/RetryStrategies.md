# Retry strategies

Control how Strand retries failed activities and workflows.

## Default behaviour

The default strategy retries up to 5 times with exponential back-off starting
at 2 seconds, doubling each attempt, capped at 5 minutes:

```
attempt 1 failed → wait 2s  → attempt 2
attempt 2 failed → wait 4s  → attempt 3
attempt 3 failed → wait 8s  → attempt 4
attempt 4 failed → wait 16s → attempt 5
attempt 5 failed → task marked FAILED
```

## All options are optional

Every field on ``ActivityOptions`` and ``EnqueueOptions`` is optional. Omitting
a field uses the worker's default (set via ``StrandOptions``):

```swift
// Uses worker defaults for everything:
try await context.runActivity(MyActivity.self, input: data)

// Override only what you need:
try await context.runActivity(MyActivity.self, input: data,
    options: ActivityOptions(maxAttempts: 3))
```

The worker default is 5 attempts with exponential back-off (2 s initial, doubles
each attempt, capped at 5 min). Override the default for all tasks on a worker
via ``StrandOptions/defaultRetryStrategy`` and ``StrandOptions/defaultMaxAttempts``.

## Custom strategies

``RetryStrategy`` has three factory methods:

```swift
// Exponential back-off with a tighter cap
ActivityOptions(
    retryStrategy: .backoff(initial: .seconds(1), multiplier: 2, cap: .seconds(30))
)

// Constant 10-second delay
ActivityOptions(
    retryStrategy: .constant(.seconds(10))
)

// Retry without any delay (e.g. for idempotent fast operations)
ActivityOptions(
    retryStrategy: .immediate()
)
```

## Non-retryable errors

Register error types that should fail permanently without retrying:

```swift
var strategy = RetryStrategy.backoff()
strategy.doNotRetry(ValidationError.self)   // bad input — no point retrying
strategy.doNotRetry(NotFoundError.self)     // resource gone — retrying won't help
```

Or with the builder pattern:

```swift
let strategy = RetryStrategy.backoff()
    .nonRetryable(ValidationError.self)
    .nonRetryable(NotFoundError.self)
```

Apply it per call-site:

```swift
try await context.runActivity(
    PaymentActivity.self,
    input: charge,
    options: ActivityOptions(
        maxAttempts: 3,
        retryStrategy: RetryStrategy.backoff(
            initial: .seconds(5), multiplier: 1.5, cap: .seconds(60)
        ).nonRetryable(CardDeclinedError.self)
    )
)
```

## Total time budget — maxDuration

Cap the total wall-clock time across ALL retry attempts:

```swift
options: ActivityOptions(
    maxAttempts: 10,
    retryStrategy: .backoff(),
    maxDuration: .hours(1)   // give up after 1 hour regardless of attempts remaining
)
```

Both `maxAttempts` and `maxDuration` are hard limits — whichever fires first
permanently fails the task.

## Per-attempt timeout

Limit how long a single attempt may run, independently of the overall retry budget:

```swift
options: ActivityOptions(
    timeout: .seconds(30),          // each attempt must finish within 30s
    maxAttempts: 5,
    maxDuration: .minutes(10)   // total budget across all attempts
)
```

## Worker-level defaults

Set defaults applied to every task claimed by a worker via ``StrandOptions``:

```swift
let client = StrandClient(
    postgres: postgres,
    queue: "default",
    options: StrandOptions(
        defaultMaxAttempts: 3,
        defaultRetryStrategy: .backoff(initial: .seconds(2), multiplier: 2, cap: .minutes(5))
    )
)
```
