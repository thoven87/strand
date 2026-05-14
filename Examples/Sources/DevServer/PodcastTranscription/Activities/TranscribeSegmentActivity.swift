import Strand

/// Simulates running speech-to-text on one ~15-minute audio segment.
/// Multiple instances of this activity run in parallel — they form the wide
/// part of the diamond fan-out.
struct TranscribeSegmentActivity: Activity {
    typealias Input = SegmentInput
    typealias Output = SegmentTranscript

    func run(input: Input, context: ActivityContext) async throws -> SegmentTranscript {
        // Transcription is CPU-heavy — each segment takes 0.8–1.8 s in sim
        try await Task.sleep(for: .milliseconds(Int64.random(in: 800...1_800)))
        let wordsPerSegment = Int.random(in: 1_800...2_400)
        let text =
            "Segment \(input.segmentIndex + 1)/\(input.totalSegments): "
            + "[simulated transcript — \(wordsPerSegment) words]"
        return SegmentTranscript(
            segmentIndex: input.segmentIndex,
            text: text,
            wordCount: wordsPerSegment
        )
    }
}
