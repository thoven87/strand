import Strand

/// Transcribes a podcast episode using a diamond fan-out / fan-in pattern.
///
/// ```
///        [DownloadEpisode]          ← one activity
///       /       |         \
///    [T0]     [T1]  …   [TN]       ← N parallel TranscribeSegment (diamond wide)
///       \       |         /
///        [MergeTranscript]          ← fan-in (diamond point)
///               |
///        [GenerateChapters]         ← one final activity
/// ```
///
/// N scales with `durationMinutes / 15` (capped 2–8) so longer episodes
/// exercise wider fan-outs and generate more activity completions per cycle.
struct PodcastTranscriptionWorkflow: Workflow {
    typealias Input = PodcastEpisodeInput
    typealias Output = PodcastResult

    mutating func run(
        context: WorkflowContext<Self>,
        input: PodcastEpisodeInput
    ) async throws -> PodcastResult {

        // ── Step 1: Download ──────────────────────────────────────────────────
        let episode = try await context.runActivity(
            DownloadEpisodeActivity.self,
            input: .init(
                showName: input.showName,
                episodeTitle: input.episodeTitle,
                durationMinutes: input.durationMinutes
            ),
            options: ActivityOptions(maxAttempts: 3)
        )

        // ── Step 2: Fan-out — transcribe all segments in parallel ─────────────
        // Each segment runs as an independent activity; they form the wide part
        // of the diamond. The workflow is WAITING while all are in-flight.
        var transcripts: [SegmentTranscript] = []
        try await withThrowingTaskGroup(of: SegmentTranscript.self) { group in
            for i in 0..<episode.segments {
                group.addTask {
                    try await context.runActivity(
                        TranscribeSegmentActivity.self,
                        input: SegmentInput(
                            episodeID: episode.episodeID,
                            segmentIndex: i,
                            totalSegments: episode.segments
                        ),
                        options: ActivityOptions(maxAttempts: 3)
                    )
                }
            }
            for try await t in group { transcripts.append(t) }
        }

        // ── Step 3: Fan-in — merge (diamond converge point) ───────────────────
        let merged = try await context.runActivity(
            MergeTranscriptActivity.self,
            input: MergeInput(episodeID: episode.episodeID, segments: transcripts),
            options: ActivityOptions(maxAttempts: 3)
        )

        // ── Step 4: Generate chapter markers from the merged transcript ────────
        let chapters = try await context.runActivity(
            GenerateChaptersActivity.self,
            input: ChapterInput(
                episodeID: episode.episodeID,
                transcript: merged.text,
                durationMinutes: episode.durationMinutes
            ),
            options: ActivityOptions(maxAttempts: 3)
        )

        return PodcastResult(
            episodeID: episode.episodeID,
            showName: input.showName,
            episodeTitle: input.episodeTitle,
            wordCount: merged.wordCount,
            chaptersGenerated: chapters.chaptersGenerated,
            transcriptPath: "/transcripts/\(episode.episodeID)/transcript.txt"
        )
    }
}
