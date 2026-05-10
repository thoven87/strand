import Foundation
import Strand

/// Simulates fetching a podcast audio file from a CDN.
/// Returns the episode ID and the number of ~15-minute segments the
/// workflow will fan out to (capped at 8 so dev runs stay snappy).
struct DownloadEpisodeActivity: ActivityDefinition {
    struct Input: Codable, Sendable {
        let showName: String
        let episodeTitle: String
        let durationMinutes: Int
    }
    typealias Output = DownloadedEpisode

    func run(input: Input, context: ActivityContext) async throws -> DownloadedEpisode {
        try await Task.sleep(for: .milliseconds(Int64.random(in: 500...1_200)))
        let slug = input.showName.lowercased().replacingOccurrences(of: " ", with: "-")
        let episodeID = "\(slug)-\(Int(Date().timeIntervalSince1970) % 100_000)"
        // One segment per 15 minutes, minimum 2, maximum 8
        let segments = max(2, min(8, input.durationMinutes / 15))
        context.logger.info(
            "episode downloaded",
            metadata: [
                "episode_id": .string(episodeID),
                "segments": .stringConvertible(segments),
            ]
        )
        return DownloadedEpisode(
            episodeID: episodeID,
            audioPath: "/audio/\(episodeID).mp3",
            segments: segments,
            durationMinutes: input.durationMinutes
        )
    }
}
