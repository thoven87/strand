import Strand

/// Top-level voice-assistant training job.
///
/// Fans out one ``TrainCountryModelWorkflow`` child per country partition
/// (ID/JP/PN) in parallel, then publishes all generated models once every
/// country has completed.
///
/// ```
/// ┌──────────────┬──────────────┬──────────────┐
/// TrainCountry   TrainCountry   TrainCountry
///    (ID)           (JP)           (PN)
///       └──────────────┴──────────────┘
///                      │
///               PublishModels
/// ```
struct TrainVoiceAssistantWorkflow: Workflow {
    typealias Input = TrainingJobInput
    typealias Output = TrainingJobResult

    mutating func run(
        context: WorkflowContext<Self>,
        input: TrainingJobInput
    ) async throws -> TrainingJobResult {
        // Fan-out: one child workflow per country partition, all in parallel
        var countryResults: [CountryModelResult] = []
        try await withThrowingTaskGroup(of: CountryModelResult.self) { group in
            for partition in input.partitions {
                group.addTask {
                    try await context.runChildWorkflow(
                        TrainCountryModelWorkflow.self,
                        input: partition
                    )
                }
            }
            for try await result in group {
                countryResults.append(result)
            }
        }

        // Publish all generated models
        let published = try await context.runActivity(
            PublishModelsActivity.self,
            input: .init(
                jobName: input.jobName,
                modelPaths: countryResults.map(\.modelPath)
            ),
            options: ActivityOptions(maxAttempts: 3)
        )

        context.logger.info(
            "Voice training job complete",
            metadata: [
                "jobName": .string(input.jobName),
                "modelsPublished": .stringConvertible(published.modelsPublished),
                "registry": .string(published.registry),
            ]
        )

        return TrainingJobResult(
            jobName: input.jobName,
            modelsPublished: published.modelsPublished,
            countries: countryResults.map(\.country)
        )
    }
}
