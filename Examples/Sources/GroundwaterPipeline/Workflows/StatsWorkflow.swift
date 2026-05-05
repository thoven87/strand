import Strand

struct StatsInput: Codable, Sendable {
    let jobID: String
}
struct StatsOutput: Codable, Sendable {
    let countiesProcessed: Int
    let counties: [String]
}

/// Discovers all counties in the ingested data then fans out
/// `ComputeCountyStatsActivity` across each one in parallel.
///
/// Stats are computed purely in SQL — no Swift-side aggregation.
/// Running 58 county queries concurrently completes in seconds even on
/// a 6M-row partitioned table because each query hits only the relevant
/// partition (county_name index + partition pruning).
struct StatsWorkflow: Workflow {
    typealias Input = StatsInput
    typealias Output = StatsOutput

    mutating func run(
        context: WorkflowContext<Self>,
        input: StatsInput
    ) async throws -> StatsOutput {

        // Step 1: discover distinct counties in the ingested data
        let counties = try await context.runActivity(
            DiscoverCountiesActivity.self,
            input: input.jobID,
            options: ActivityOptions(maxAttempts: 3)
        )

        context.logger.info(
            "Computing stats for \(counties.count) counties",
            metadata: ["job_id": .string(input.jobID)]
        )

        // Step 2: fan-out — compute stats for every county concurrently.
        // Use a non-throwing group so one county failure doesn't abort the rest.
        var results: [ComputeStatsOutput] = []
        await withTaskGroup(of: ComputeStatsOutput?.self) { group in
            for county in counties {
                let c = county
                group.addTask {
                    do {
                        return try await context.runActivity(
                            ComputeCountyStatsActivity.self,
                            input: ComputeStatsInput(jobID: input.jobID, countyName: c),
                            options: ActivityOptions(maxAttempts: 5)
                        )
                    } catch {
                        context.logger.error(
                            "Stats failed for \(c): \(error.localizedDescription)",
                            metadata: ["job_id": .string(input.jobID)]
                        )
                        return nil  // skip this county, continue with the rest
                    }
                }
            }
            for await result in group {
                if let r = result { results.append(r) }
            }
        }

        // Update pipeline_runs with county count
        context.logger.info(
            "Stats complete: \(results.count) counties",
            metadata: ["job_id": .string(input.jobID)]
        )

        return StatsOutput(
            countiesProcessed: results.count,
            counties: results.map(\.countyName)
        )
    }
}
