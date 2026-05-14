import Strand

struct AnalyzeTextCorpusActivity: Activity {
    struct Input: Codable, Sendable {
        let country: String
        let variant: Int
        let partition: Int
        let corpusSize: Int
    }
    typealias Output = CorpusAnalysis

    func run(input: Input, context: ActivityContext) async throws -> CorpusAnalysis {
        try await Task.sleep(for: .milliseconds(Int64.random(in: 500...1_500)))
        let analysisPath = "/analysis/\(input.country)/v\(input.variant)/features.bin"
        context.logger.info(
            "Analyzed text corpus",
            metadata: [
                "country": .string(input.country),
                "variant": .stringConvertible(input.variant),
                "corpusSize": .stringConvertible(input.corpusSize),
                "analysisPath": .string(analysisPath),
            ]
        )
        return CorpusAnalysis(
            country: input.country,
            variant: input.variant,
            analysisPath: analysisPath
        )
    }
}
