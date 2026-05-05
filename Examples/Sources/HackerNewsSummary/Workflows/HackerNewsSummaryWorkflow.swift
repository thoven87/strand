import Strand

/// Top-level orchestrator.
///
/// 1. Fetches the top-N story IDs from the HN Firebase REST API.
/// 2. Fans out to N × ``SummarizeStoryWorkflow`` child workflows in parallel.
///    Each child fetches the story details and runs Ollama summarisation.
///    The `hn-summarizer` queue worker controls concurrency so Ollama
///    is never overwhelmed.
/// 3. Sorts results by HN score and returns the final summary.
///
/// Crash recovery: if the process dies after some stories are summarised,
/// the next activation replays completed child workflows from checkpoints
/// without re-running them.
struct HackerNewsSummaryWorkflow: Workflow {
    typealias Input = HNInput
    typealias Output = HNDailySummary

    mutating func run(
        context: WorkflowContext<Self>,
        input: HNInput
    ) async throws -> HNDailySummary {
        context.logger.info(
            "🗞  Fetching top \(input.storyCount) HN stories",
            metadata: ["job_id": .string(input.jobID)]
        )

        // Step 1 — fetch story IDs
        let storyIDs = try await context.runActivity(
            FetchTopStoriesActivity.self,
            input: .init(count: input.storyCount),
            options: ActivityOptions(maxAttempts: 3)
        )

        context.logger.info(
            "Fetched \(storyIDs.count) story IDs — fanning out",
            metadata: ["job_id": .string(input.jobID)]
        )

        // Step 2 — parallel fan-out: one child workflow per story
        var summaries: [StorySummary] = []
        try await withThrowingTaskGroup(of: StorySummary.self) { group in
            for id in storyIDs {
                group.addTask {
                    try await context.runChildWorkflow(
                        SummarizeStoryWorkflow.self,
                        // Route child workflows to a dedicated queue whose
                        // worker concurrency limits simultaneous Ollama calls.
                        options: .init(queue: "hn-summarizer"),
                        input: id
                    )
                }
            }
            for try await summary in group {
                summaries.append(summary)
            }
        }

        // Step 3 — sort by score, print, return
        let sorted = summaries.sorted { $0.score > $1.score }
        let result = HNDailySummary(
            jobID: input.jobID,
            stories: sorted,
            generatedAt: context.activationTime
        )

        context.logger.info(
            "✅ Summary complete — \(sorted.count) stories",
            metadata: ["job_id": .string(input.jobID)]
        )

        for story in sorted {
            context.logger.info(
                "[\(story.score)pts] \(story.title)",
                metadata: [
                    "url": .string(story.url),
                    "author": .string(story.author),
                    "summary": .string(story.summary),
                ]
            )
        }

        return result
    }
}
