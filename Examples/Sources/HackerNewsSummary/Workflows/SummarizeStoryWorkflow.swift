import Strand

/// Child workflow: fetches one HN story then summarises it with Ollama.
/// Runs on the `hn-summarizer` queue so concurrency is controlled at the
/// worker level — set `activityConcurrency` on that worker to limit
/// simultaneous Ollama calls.
struct SummarizeStoryWorkflow: Workflow {
    typealias Input = Int  // HN story ID
    typealias Output = StorySummary

    mutating func run(
        context: WorkflowContext<Self>,
        input: Int
    ) async throws -> StorySummary {
        // Step 1 — fetch story metadata from HN API
        let story = try await context.runActivity(
            FetchStoryActivity.self,
            input: .init(storyID: input),
            options: ActivityOptions(maxAttempts: 3)
        )

        // Step 2 — build the content string for the summariser
        let content: String
        if let text = story.text, !text.isEmpty {
            // Self-post (Ask HN / Show HN) — the body IS the content
            content = String(text.prefix(1_500))
        } else if let url = story.url {
            // Link post — summarise from title + URL since we have no browser
            content = "Link: \(url)"
        } else {
            content = "(No content available)"
        }

        // Step 3 — summarise with Ollama
        let summary = try await context.runActivity(
            OllamaSummarizeActivity.self,
            input: .init(title: story.title, content: content),
            options: ActivityOptions(
                maxAttempts: 2,
                retryStrategy: .backoff(initial: .seconds(5), multiplier: 2, cap: .seconds(30))
            )
        )

        return StorySummary(
            id: story.id,
            title: story.title,
            url: story.url ?? "https://news.ycombinator.com/item?id=\(story.id)",
            score: story.score,
            author: story.by,
            comments: story.descendants ?? 0,
            summary: summary
        )
    }
}
