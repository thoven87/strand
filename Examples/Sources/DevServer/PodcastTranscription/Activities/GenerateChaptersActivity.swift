import Strand

/// Simulates an LLM pass over the full transcript to extract chapter markers.
struct GenerateChaptersActivity: ActivityDefinition {
    typealias Input = ChapterInput
    typealias Output = ChaptersResult

    func run(input: Input, context: ActivityContext) async throws -> ChaptersResult {
        try await Task.sleep(for: .milliseconds(Int64.random(in: 800...1_600)))
        // Roughly one chapter per 15 minutes; at least 1
        let chapters = max(1, input.durationMinutes / 15)
        context.logger.info(
            "chapters generated",
            metadata: [
                "episode_id": .string(input.episodeID),
                "chapters": .stringConvertible(chapters),
            ]
        )
        return ChaptersResult(chaptersGenerated: chapters)
    }
}
