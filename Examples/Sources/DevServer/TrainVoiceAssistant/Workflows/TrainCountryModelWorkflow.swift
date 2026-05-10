import Strand

/// Per-country child workflow used by ``TrainVoiceAssistantWorkflow``.
///
/// Pipeline for a single country/partition:
/// 1. IngestTextCorpus  — download & store the raw corpus
/// 2. AnalyzeTextCorpus — run N variant analyses in parallel (fan-out)
/// 3. GenerateVoiceModel — train the model from all analysis artefacts
struct TrainCountryModelWorkflow: Workflow {
    typealias Input = CountryPartitionInput
    typealias Output = CountryModelResult

    mutating func run(
        context: WorkflowContext<Self>,
        input: CountryPartitionInput
    ) async throws -> CountryModelResult {
        // Step 1: ingest corpus for this country/partition
        let corpus = try await context.runActivity(
            IngestTextCorpusActivity.self,
            input: .init(country: input.country, partition: input.partition),
            options: ActivityOptions(maxAttempts: 3)
        )

        // Step 2: parallel analysis — one task per variant
        var analyses: [CorpusAnalysis] = []
        try await withThrowingTaskGroup(of: CorpusAnalysis.self) { group in
            for variant in 0..<input.variants {
                group.addTask {
                    try await context.runActivity(
                        AnalyzeTextCorpusActivity.self,
                        input: .init(
                            country: input.country,
                            variant: variant,
                            partition: input.partition,
                            corpusSize: corpus.rowCount
                        ),
                        options: ActivityOptions(maxAttempts: 3)
                    )
                }
            }
            for try await analysis in group {
                analyses.append(analysis)
            }
        }

        // Step 3: generate voice model from all analyses
        let model = try await context.runActivity(
            GenerateVoiceModelActivity.self,
            input: .init(
                country: input.country,
                analysisPaths: analyses.map(\.analysisPath)
            ),
            options: ActivityOptions(maxAttempts: 3)
        )

        return CountryModelResult(
            country: input.country,
            modelPath: model.modelPath,
            variantsAnalyzed: analyses.count
        )
    }
}
