import Strand

// MARK: - Podcast transcription pipeline types
//
// Diamond workflow shape:
//
//       [DownloadEpisode]
//      /       |        \
//   [T0]     [T1]  …  [TN]    ← N parallel TranscribeSegment activities
//      \       |        /
//       [MergeTranscript]       ← fan-in: all N segments joined
//              |
//       [GenerateChapters]

struct PodcastEpisodeInput: Codable, Sendable {
    let showName: String
    let episodeTitle: String
    /// Total episode duration — determines how many segments to fan out to.
    let durationMinutes: Int
}

/// Output of DownloadEpisodeActivity.
struct DownloadedEpisode: Codable, Sendable {
    let episodeID: String
    let audioPath: String
    /// Number of ~15-minute segments this episode is split into (2–8).
    let segments: Int
    let durationMinutes: Int
}

/// Input/output for a single segment transcription.
struct SegmentInput: Codable, Sendable {
    let episodeID: String
    let segmentIndex: Int
    let totalSegments: Int
}

struct SegmentTranscript: Codable, Sendable {
    let segmentIndex: Int
    let text: String
    let wordCount: Int
}

/// Input for the fan-in merge step.
struct MergeInput: Codable, Sendable {
    let episodeID: String
    /// All segment transcripts, in any order — merge sorts by segmentIndex.
    let segments: [SegmentTranscript]
}

struct FullTranscript: Codable, Sendable {
    let episodeID: String
    let text: String
    let wordCount: Int
}

struct ChapterInput: Codable, Sendable {
    let episodeID: String
    /// Full merged transcript text (simulated; short in dev).
    let transcript: String
    let durationMinutes: Int
}

struct ChaptersResult: Codable, Sendable {
    let chaptersGenerated: Int
}

struct PodcastResult: Codable, Sendable {
    let episodeID: String
    let showName: String
    let episodeTitle: String
    let wordCount: Int
    let chaptersGenerated: Int
    let transcriptPath: String
}
