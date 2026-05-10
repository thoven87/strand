import Strand

struct GenerateVoiceModelActivity: ActivityDefinition {
    struct Input: Codable, Sendable {
        let country: String
        let analysisPaths: [String]
    }
    typealias Output = VoiceModel

    func run(input: Input, context: ActivityContext) async throws -> VoiceModel {
        try await Task.sleep(for: .milliseconds(Int64.random(in: 1_500...3_000)))
        let modelPath = "/models/\(input.country)/voice_v1.bin"
        context.logger.info(
            "Generated voice model",
            metadata: [
                "country": .string(input.country),
                "analysisCount": .stringConvertible(input.analysisPaths.count),
                "modelPath": .string(modelPath),
            ]
        )
        return VoiceModel(country: input.country, modelPath: modelPath)
    }
}
