import Strand

/// Joins all parallel segment transcripts into one document.
/// This is the bottom point of the diamond — N parallel results converge here.
struct MergeTranscriptActivity: Activity {
    typealias Input = MergeInput
    typealias Output = FullTranscript

    func run(input: Input, context: ActivityContext) async throws -> FullTranscript {
        try await Task.sleep(for: .milliseconds(Int64.random(in: 300...700)))
        let ordered = input.segments.sorted { $0.segmentIndex < $1.segmentIndex }
        let merged = ordered.map(\.text).joined(separator: "\n\n")
        let totalWords = ordered.reduce(0) { $0 + $1.wordCount }
        return FullTranscript(
            episodeID: input.episodeID,
            text: merged,
            wordCount: totalWords
        )
    }
}
