import Foundation
import Strand

/// Sends an HN story to a locally running Ollama instance and returns a
/// 2–3 sentence summary.  Requires `ollama serve` to be running and a
/// model (e.g. `qwen3:latest`) to be pulled.
struct OllamaSummarizeActivity: Activity {
    struct Input: Codable, Sendable {
        let title: String
        let content: String  // url or self-post text, truncated to 1500 chars
    }
    typealias Output = String  // the generated summary

    func run(input: Input, context: ActivityContext) async throws -> String {
        struct OllamaRequest: Encodable {
            let model: String
            let prompt: String
            let stream: Bool
        }
        struct OllamaResponse: Decodable {
            let response: String
        }

        let prompt = """
            Summarise this Hacker News post in 2–3 concise sentences. \
            Focus on why it is interesting to a technical audience.

            Title: \(input.title)
            Content: \(input.content)

            Summary:
            """

        let body = OllamaRequest(model: "qwen3:latest", prompt: prompt, stream: false)
        var req = URLRequest(url: URL(string: "http://localhost:11434/api/generate")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        // Give Ollama up to 120 s — first request warms the model.
        req.timeoutInterval = 120

        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(OllamaResponse.self, from: data)
            .response
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
