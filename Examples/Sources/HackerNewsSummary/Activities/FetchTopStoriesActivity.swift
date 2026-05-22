import Foundation
import Strand

/// Calls the HN Firebase REST API and returns the top-N story IDs.
/// No browser or Puppeteer required — the HN API returns JSON directly.
struct FetchTopStoriesActivity: Activity {
    struct Input: Codable, Sendable { let count: Int }
    typealias Output = [Int]

    private static let decoder = JSONDecoder()

    func run(input: Input, context: ActivityContext) async throws -> [Int] {
        let url = URL(string: "https://hacker-news.firebaseio.com/v0/topstories.json")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let allIDs = try Self.decoder.decode([Int].self, from: data)
        return Array(allIDs.prefix(input.count))
    }
}
