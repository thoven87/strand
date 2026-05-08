import Logging
import PostgresNIO
import ServiceLifecycle
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// HN Summary — Hacker News daily briefing powered by Ollama.
///
/// Fetches the top-N stories from the HN Firebase REST API, summarises each
/// one with a locally running Ollama model, and prints the results.
///
/// Usage:
///   swift run HackerNewsSummary
///
/// Prerequisites:
///   • Postgres running at localhost:5499 (see docker-compose)
///   • `ollama serve` running with `qwen3:latest` pulled
///
/// Two workers run side-by-side:
///   • `hn-orchestrator` — runs the top-level HackerNewsSummaryWorkflow
///   • `hn-summarizer`   — runs SummarizeStoryWorkflow children; keep
///     activityConcurrency ≤ 5 so Ollama is not overwhelmed
@main struct HackerNewsSummaryExample {
    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput(label:))
        let logger = Logger(label: "hn-summary")

        print("🗞  HN Daily Summary — powered by Ollama")
        print(String(repeating: "═", count: 55))

        let postgres = PostgresClient(
            configuration: .init(
                host: "localhost",
                port: 5499,
                username: "strand",
                password: "strand",
                database: "strand_dev",
                tls: .disable
            ),
            backgroundLogger: logger
        )

        let client = StrandClient(
            postgres: postgres,
            queue: "hn-orchestrator",
            namespace: "hn-summary",
            options: StrandOptions(logger: logger)
        )

        // Orchestrator worker — runs the top-level workflow
        let orchestratorWorker = StrandWorker(
            postgres: postgres,
            options: WorkerOptions(
                queue: "hn-orchestrator",
                namespace: "hn-summary",
                workflowConcurrency: 4,
                activityConcurrency: 8
            ),
            workflows: [HackerNewsSummaryWorkflow.self],
            activities: [FetchTopStoriesActivity()],
            logger: logger
        )

        // Summariser worker — runs child workflows; limit Ollama concurrency to 3
        let summarizerWorker = StrandWorker(
            postgres: postgres,
            options: WorkerOptions(
                queue: "hn-summarizer",
                namespace: "hn-summary",
                workflowConcurrency: 3,  // max 3 simultaneous Ollama calls
                activityConcurrency: 3
            ),
            workflows: [SummarizeStoryWorkflow.self],
            activities: [FetchStoryActivity(), OllamaSummarizeActivity()],
            logger: logger
        )

        var estCal = Calendar(identifier: .gregorian)
        estCal.timeZone = TimeZone(identifier: "America/New_York")!
        let may1est = estCal.date(
            from: DateComponents(
                year: 2026,
                month: 5,
                day: 1,
                hour: 0,
                minute: 0,
                second: 0
            )
        )!

        let scheduler = StrandScheduler(
            client: client,
            options: SchedulerOptions(sleepCap: .seconds(30)),
            schedules: [
                .workflow(
                    "hn-daily-briefing",
                    pattern: .cron(
                        "0 9 * * 1-5",
                        timezone: TimeZone(identifier: "America/New_York")!
                    ),
                    workflowType: HackerNewsSummaryWorkflow.self,
                    input: HNInput(storyCount: 5, jobID: "daily"),
                    startsAt: may1est,
                    options: ScheduleOptions(accuracy: .last(3))
                )
            ]
        )
        print("✅ hn-daily-briefing  cron 0 9 * * 1-5 EST  (09:00 ET weekdays, from 2026-05-01)")

        // Trigger an immediate run for demo purposes
        // Task {
        //     do {
        //         try await Task.sleep(for: .milliseconds(600))
        //         let result = try await client.startWorkflow(
        //             HackerNewsSummaryWorkflow.self,
        //             input: HNInput(
        //                 storyCount: 5,
        //                 jobID: "hn-\(Int(Date().timeIntervalSince1970))"))
        //         print("🚀 Triggered immediate run:", result.workflowID)
        //         print("⏳ Waiting for Ollama summarisation…\n")
        //     } catch { print("Trigger error:", error) }
        // }

        let group = ServiceGroup(
            configuration: .init(
                services: [
                    .init(service: postgres),
                    .init(service: orchestratorWorker),
                    .init(service: summarizerWorker),
                    .init(service: scheduler),
                ],
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: logger
            )
        )
        try await group.run()
    }
}
