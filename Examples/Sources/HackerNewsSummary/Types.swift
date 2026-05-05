import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Input / Output types

struct HNInput: Codable, Sendable {
    /// Number of top stories to fetch and summarise. Default: 5.
    var storyCount: Int
    /// Namespace for the run (used to avoid collisions between runs).
    var jobID: String
}

struct HNStory: Codable, Sendable {
    let id: Int
    let title: String
    /// External URL (nil for Ask HN / Show HN posts whose text is the content).
    let url: String?
    /// Self-post body text (Ask HN, Show HN).
    let text: String?
    let score: Int
    let by: String
    let descendants: Int?  // comment count
}

struct StorySummary: Codable, Sendable {
    let id: Int
    let title: String
    let url: String  // direct link or HN item URL as fallback
    let score: Int
    let author: String
    let comments: Int
    let summary: String
}

struct HNDailySummary: Codable, Sendable {
    let jobID: String
    let stories: [StorySummary]
    let generatedAt: Date
}
