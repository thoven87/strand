import Strand

struct PublishModelsActivity: ActivityDefinition {
    typealias Input = PublishInput
    typealias Output = PublishResult

    func run(input: Input, context: ActivityContext) async throws -> PublishResult {
        try await Task.sleep(for: .milliseconds(Int64.random(in: 800...1_500)))
        let registry = "registry.strand.dev"
        context.logger.info(
            "Published voice models",
            metadata: [
                "jobName": .string(input.jobName),
                "registry": .string(registry),
                "modelsPublished": .stringConvertible(input.modelPaths.count),
            ]
        )
        return PublishResult(registry: registry, modelsPublished: input.modelPaths.count)
    }
}
