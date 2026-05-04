# Getting started

Add Strand to a Swift server project in three steps.

## 1. Add the package

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/thoven87/strand", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Strand", package: "strand"),
    ]),
]
```

## 2. Apply the schema

```bash
psql "postgresql://user:pass@localhost:5432/mydb" -f strand.sql
```

The schema creates the `strand` Postgres schema with all required tables.

## 3. Define an activity, a workflow, and a worker

```swift
import Strand
import ServiceLifecycle

// ── Activity: does the actual I/O ───────────────────────────────────────────

struct SendEmailActivity: ActivityDefinition {
    typealias Input  = EmailInput
    typealias Output = EmailResult

    struct EmailInput:  Codable, Sendable { let to: String; let subject: String }
    struct EmailResult: Codable, Sendable { let messageID: String }

    func run(input: EmailInput, context: ActivityContext) async throws -> EmailResult {
        let id = try await smtp.send(to: input.to, subject: input.subject)
        return EmailResult(messageID: id)
    }
}

// ── Workflow: orchestrates activities ────────────────────────────────────────

struct WelcomeWorkflow: Workflow {
    typealias Input  = String   // email address
    typealias Output = String   // message ID

    mutating func run(context: WorkflowContext<Self>, input: String) async throws -> String {
        let result = try await context.runActivity(
            SendEmailActivity.self,
            input: .init(to: input, subject: "Welcome!")
        )
        return result.messageID
    }
}

// ── Worker + client ──────────────────────────────────────────────────────────

let postgres = PostgresClient(configuration: .init(
    host: "localhost", port: 5432,
    username: "user", password: "pass", database: "mydb",
    tls: .disable
))
let client = StrandClient(postgres: postgres, queue: "default")
let worker = StrandWorker(
    postgres: postgres,
    options: WorkerOptions(queue: "default"),
    workflows: [WelcomeWorkflow.self],
    activities: [SendEmailActivity()]
)
let group = ServiceGroup(
    configuration: .init(
        services: [.init(service: postgres), .init(service: worker)],
        gracefulShutdownSignals: [.sigterm, .sigint]
    )
)

// Enqueue a workflow — returns a handle you can poll for the result:
let handle = try await client.startWorkflow(
    WelcomeWorkflow.self,
    input: "alice@example.com"
)

// Optionally await the result:
let messageID = try await handle.result(timeout: .seconds(30))

try await group.run()
```

## Next steps

- <doc:Concepts> — understand the execution model
- <doc:Activities> — define activities with retries and timeouts
- <doc:Workflows> — write durable orchestration logic
- <doc:TestingWorkflows> — test without a persistent test database
