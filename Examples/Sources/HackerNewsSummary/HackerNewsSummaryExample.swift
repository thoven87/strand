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
///   swift run --package-path Examples HackerNewsSummary
///
/// Prerequisites:
///   • Postgres running at localhost:5499 (see docker-compose)
///   • `ollama serve` running with `qwen3:latest` pulled
///
/// Two queues run inside StrandService:
///   • `hn-orchestrator` — runs HackerNewsSummaryWorkflow (top-level)
///   • `hn-summarizer`   — runs SummarizeStoryWorkflow children;
///     workflowConcurrency: 3 so Ollama is not overwhelmed
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

        var strand = StrandService(
            postgres: postgres,
            options: .init(
                queues: [
                    // Orchestrator — top-level workflow + story fetch
                    .init(
                        name: "hn-orchestrator",
                        namespace: "hn-summary",
                        workflows: [HackerNewsSummaryWorkflow.self],
                        activities: [FetchTopStoriesActivity()],
                        workflowConcurrency: 4,
                        activityConcurrency: 8
                    ),
                    // Summariser — child workflows; cap Ollama concurrency at 3
                    .init(
                        name: "hn-summarizer",
                        namespace: "hn-summary",
                        workflows: [SummarizeStoryWorkflow.self],
                        activities: [FetchStoryActivity(), OllamaSummarizeActivity()],
                        workflowConcurrency: 3,
                        activityConcurrency: 3
                    ),
                ],
                scheduler: .init(
                    options: .init(sleepCap: .seconds(30)),
                    queue: "hn-orchestrator",
                    namespace: "hn-summary"
                ),
                logger: logger
            )
        )

        // ── Daily schedule ───────────────────────────────────────────────────
        var estCal = Calendar(identifier: .gregorian)
        estCal.timeZone = TimeZone(identifier: "America/New_York")!
        let may1est = estCal.date(
            from: DateComponents(year: 2026, month: 5, day: 1, hour: 0, minute: 0, second: 0)
        )!

        strand.addSchedule(
            .workflow(
                "hn-daily-briefing",
                pattern: .cron("0 9 * * 1-5", timezone: TimeZone(identifier: "America/New_York")!),
                workflowType: HackerNewsSummaryWorkflow.self,
                input: HNInput(storyCount: 5, jobID: "daily"),
                startsAt: may1est,
                options: ScheduleOptions(accuracy: .last(3))
            )
        )
        print("✅ hn-daily-briefing  cron 0 9 * * 1-5 EST  (09:00 ET weekdays, from 2026-05-01)")

        // ── Optional: trigger an immediate run ───────────────────────────────
        // let client = strand.client(queue: "hn-orchestrator", namespace: "hn-summary")
        // Task {
        //     try await Task.sleep(for: .milliseconds(600))
        //     let result = try await client.startWorkflow(
        //         HackerNewsSummaryWorkflow.self,
        //         input: HNInput(storyCount: 5, jobID: "hn-\(Int(Date().timeIntervalSince1970))"))
        //     print("🚀 Triggered:", result.workflowID)
        // }

        let group = ServiceGroup(
            services: [postgres, strand],
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: logger
        )
        try await group.run()
    }
}
