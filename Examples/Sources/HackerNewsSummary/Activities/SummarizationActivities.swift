import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Input types (used by SummarizeStoryWorkflow)

struct FetchStoryInput: Codable, Sendable {
    let storyID: Int
}

struct SummarizeInput: Codable, Sendable {
    let title: String
    /// URL or self-post body text, truncated to 1 500 chars.
    let content: String
}

// MARK: - SummarizationActivities

/// Groups the two activities used by `SummarizeStoryWorkflow`.
///
/// Both activities share the Ollama connection details (base URL + model),
/// so they are registered together as a container rather than as standalone
/// instances.  Register an instance on the `hn-summarizer` worker:
///
/// ```swift
/// activityContainers: [SummarizationActivities(
///     ollamaBaseURL: URL(string: "http://localhost:11434")!,
///     model: "qwen3:latest"
/// )]
/// ```
@ActivityContainer
struct SummarizationActivities {
    /// Base URL of the locally running Ollama server.
    let ollamaBaseURL: URL
    /// Ollama model name, e.g. `"qwen3:latest"`.
    let model: String

    // MARK: - Private Codable helpers

    private struct _OllamaRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
    }

    private struct _OllamaResponse: Decodable {
        let response: String
    }

    // MARK: - Activities

    /// Fetches a single HN story from the Firebase REST API.
    @Activity
    func fetchStory(input: FetchStoryInput, context: ActivityContext) async throws -> HNStory {
        let url = URL(string: "https://hacker-news.firebaseio.com/v0/item/\(input.storyID).json")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(HNStory.self, from: data)
    }

    /// Sends an HN story to Ollama and returns a 2–3 sentence summary.
    ///
    /// Uses `self.ollamaBaseURL` and `self.model` injected at container
    /// construction time — no hardcoded endpoints or model names.
    @Activity
    func summarize(input: SummarizeInput, context: ActivityContext) async throws -> String {
        let prompt = """
            Summarise this Hacker News post in 2–3 concise sentences. \
            Focus on why it is interesting to a technical audience.

            Title: \(input.title)
            Content: \(input.content)

            Summary:
            """

        var req = URLRequest(url: ollamaBaseURL.appending(path: "/api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            _OllamaRequest(model: model, prompt: prompt, stream: false)
        )
        // Give Ollama up to 120 s — first request warms the model.
        req.timeoutInterval = 120

        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(_OllamaResponse.self, from: data)
            .response
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
