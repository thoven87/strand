import Strand

struct IngestTextCorpusActivity: ActivityDefinition {
    struct Input: Codable, Sendable {
        let country: String
        let partition: Int
    }
    typealias Output = CorpusData

    func run(input: Input, context: ActivityContext) async throws -> CorpusData {
        try await Task.sleep(for: .milliseconds(Int64.random(in: 1_500...3_000)))
        let rowCount = Int.random(in: 80_000...500_000)
        context.logger.info(
            "Ingested text corpus",
            metadata: [
                "country": .string(input.country),
                "partition": .stringConvertible(input.partition),
                "rowCount": .stringConvertible(rowCount),
            ]
        )
        return CorpusData(country: input.country, partition: input.partition, rowCount: rowCount)
    }
}
