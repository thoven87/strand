import Foundation
import Strand

/// Fetches a single HN story from the Firebase REST API.
struct FetchStoryActivity: ActivityDefinition {
    struct Input: Codable, Sendable { let storyID: Int }
    typealias Output = HNStory

    func run(input: Input, context: ActivityContext) async throws -> HNStory {
        let url = URL(string: "https://hacker-news.firebaseio.com/v0/item/\(input.storyID).json")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(HNStory.self, from: data)
    }
}
