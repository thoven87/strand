import PostgresNIO
import Strand

struct AIAnalysisInput: Codable, Sendable {
    let jobID: String
    let counties: [String]
}
struct AIAnalysisOutput: Codable, Sendable {
    let countiesAnalyzed: Int
    let declining: [String]
    let stable: [String]
    let recovering: [String]
}

/// Fans out Ollama trend analysis to every county from StatsWorkflow.
///
/// Each county gets one `OllamaTrendActivity` call (model: qwen3).
/// The model receives SQL-computed stats and returns:
///   - trend classification: DECLINING | STABLE | RECOVERING | UNKNOWN
///   - 2-sentence narrative for non-technical stakeholders
///
/// Rate limiting: the `gw-ai` queue has lower concurrency (5 workflows)
/// so Ollama isn't overwhelmed with 58 simultaneous requests.
struct AIAnalysisWorkflow: Workflow {
    typealias Input = AIAnalysisInput
    typealias Output = AIAnalysisOutput

    mutating func run(
        context: WorkflowContext<Self>,
        input: AIAnalysisInput
    ) async throws -> AIAnalysisOutput {
        context.logger.info(
            "Starting AI analysis for \(input.counties.count) counties",
            metadata: ["job_id": .string(input.jobID)]
        )

        var results: [OllamaTrendOutput] = []

        try await withThrowingTaskGroup(of: OllamaTrendOutput.self) { group in
            for county in input.counties {
                // Fetch the stats row computed by StatsWorkflow
                let statsActivity = FetchCountyStatsActivity.self
                let statsInput = FetchStatsInput(jobID: input.jobID, countyName: county)
                group.addTask {
                    let stats = try await context.runActivity(
                        statsActivity,
                        input: statsInput,
                        options: ActivityOptions(maxAttempts: 2)
                    )
                    return try await context.runActivity(
                        OllamaTrendActivity.self,
                        input: OllamaTrendInput(
                            countyName: county,
                            measurementCount: stats.measurementCount,
                            avgDepthFt: stats.avgDepthFt,
                            minDepthFt: stats.minDepthFt,
                            maxDepthFt: stats.maxDepthFt,
                            trendDeltaFt: stats.trendDeltaFt,
                            earliestMsmt: stats.earliestMsmt,
                            latestMsmt: stats.latestMsmt
                        ),
                        options: ActivityOptions(maxAttempts: 2)
                    )
                }
            }
            for try await result in group { results.append(result) }
        }

        let declining = results.filter { $0.trend == "DECLINING" }.map(\.countyName)
        let stable = results.filter { $0.trend == "STABLE" }.map(\.countyName)
        let recovering = results.filter { $0.trend == "RECOVERING" }.map(\.countyName)

        context.logger.info(
            "AI done: \(declining.count) declining / \(stable.count) stable / \(recovering.count) recovering",
            metadata: ["job_id": .string(input.jobID)]
        )

        return AIAnalysisOutput(
            countiesAnalyzed: results.count,
            declining: declining,
            stable: stable,
            recovering: recovering
        )
    }
}

// MARK: - Fetch county stats from DB (after ComputeCountyStatsActivity)

struct FetchStatsInput: Codable, Sendable {
    let jobID: String
    let countyName: String
}

struct FetchStatsOutput: Codable, Sendable {
    let countyName: String
    let measurementCount: Int
    let avgDepthFt: Double?
    let minDepthFt: Double?
    let maxDepthFt: Double?
    let trendDeltaFt: Double?
    let earliestMsmt: String?
    let latestMsmt: String?
}

struct FetchCountyStatsActivity: Activity {
    typealias Input = FetchStatsInput
    typealias Output = FetchStatsOutput

    let postgres: PostgresClient

    func run(input: Input, context: ActivityContext) async throws -> Output {
        let stream = try await postgres.query(
            """
            SELECT county_name, measurement_count::int8,
                   avg_depth_ft::float8, min_depth_ft::float8,
                   max_depth_ft::float8, trend_delta_ft::float8,
                   earliest_msmt::text, latest_msmt::text
            FROM cnra.county_stats
            WHERE county_name = \(input.countyName)
            """,
            logger: context.logger
        )
        guard let row = try await stream.first(where: { _ in true }) else {
            return FetchStatsOutput(
                countyName: input.countyName,
                measurementCount: 0,
                avgDepthFt: nil,
                minDepthFt: nil,
                maxDepthFt: nil,
                trendDeltaFt: nil,
                earliestMsmt: nil,
                latestMsmt: nil
            )
        }
        var col = row.makeIterator()
        let county = try col.next()!.decode(String.self, context: .default)
        let cnt = try col.next()!.decode(Int.self, context: .default)
        let avg = try col.next()!.decode(Double?.self, context: .default)
        let mn = try col.next()!.decode(Double?.self, context: .default)
        let mx = try col.next()!.decode(Double?.self, context: .default)
        let delta = try col.next()!.decode(Double?.self, context: .default)
        let earliest = try col.next()!.decode(String?.self, context: .default)
        let latest = try col.next()!.decode(String?.self, context: .default)
        return FetchStatsOutput(
            countyName: county,
            measurementCount: cnt,
            avgDepthFt: avg,
            minDepthFt: mn,
            maxDepthFt: mx,
            trendDeltaFt: delta,
            earliestMsmt: earliest,
            latestMsmt: latest
        )
    }
}
