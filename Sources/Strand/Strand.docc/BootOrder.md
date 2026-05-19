# Registering schedules

How to wire recurring schedules so they are always registered before the
scheduler starts polling.

## Boot-time schedules

Call `addSchedule(_:)` on `StrandService` before handing it to `ServiceGroup`.
Internally, `StrandService.run()` applies every registered schedule **after**
its first successful Postgres interaction — in the same window as queue
creation and schema verification — so the scheduler never polls before its
schedules exist.

```swift
var strand = StrandService(
    postgres: postgres,
    options: .init(
        queues: [
            .init(
                name: "default",
                workflows: [NightlySyncWorkflow.self]
            )
        ],
        scheduler: .init()   // enable the built-in scheduler
    )
)

// Register as many schedules as needed before run().
strand.addSchedule(.workflow(
    "nightly-sync",
    pattern: .cron("0 2 * * *"),   // 02:00 UTC every day
    workflowType: NightlySyncWorkflow.self,
    input: SyncInput(dataset: "prod")
))

strand.addSchedule(.workflow(
    "weekly-report",
    pattern: .weekly(weekday: .monday, offset: "PT9H"),
    workflowType: WeeklyReportWorkflow.self,
    input: ReportInput()
))

let group = ServiceGroup(
    services: [postgres, strand],
    gracefulShutdownSignals: [.sigterm, .sigint],
    logger: logger
)
try await group.run()
```

The `ServiceGroup` itself only needs `postgres` and `strand` — `StrandService`
manages the worker, scheduler, notifier, metrics loop, and pruner internally.

## Runtime schedule creation

Use `client.schedule(...)` when a schedule is created or modified **at runtime**
— from an HTTP handler, a workflow, or any other call site where Postgres is
already reachable:

```swift
// e.g. POST /api/pipelines/:id/schedule
func createScheduleHandler(req: Request, ctx: RequestContext) async throws -> Response {
    try await client.schedule(
        name: "pipeline-\(try req.parameters.require("id"))",
        pattern: .cron(req.body.cron),
        workflowType: DataPipelineWorkflow.self,
        input: PipelineInput(config: req.body.config)
    )
    return .ok
}
```

Runtime creation is correct here — the client is warm, Postgres is reachable,
and the schedule is being defined by a user action, not at application startup.

## See also

- <doc:Scheduling> — full scheduler reference, patterns, and accuracy modes
- <doc:GettingStarted> — complete bootstrap example using `StrandService`
