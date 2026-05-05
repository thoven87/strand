import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Top-level pipeline orchestrator. Three sequential stages, each implemented
/// as a child workflow so they run on dedicated queues with independent workers.
///
/// Stage 1 — INGESTION  (gw-ingestion)
///   Fan-out to N × IngestChunkWorkflow, one per 50k-row chunk.
///   125 chunks × 50k rows = 6.2M rows total.
///   20 concurrent workers download, parse, and insert in parallel.
///
/// Stage 2 — STATS  (gw-analytics)
///   StatsWorkflow discovers all counties then fans out SQL aggregates.
///   58 counties × 1 SQL query each → cnra.county_stats table.
///
/// Stage 3 — AI  (gw-ai)
///   AIAnalysisWorkflow fans out Ollama (qwen3) to every county.
///   Classifies trend (DECLINING/STABLE/RECOVERING) + writes narrative.
///   Rate-limited to 5 concurrent requests so Ollama isn't overwhelmed.
///
/// Crash recovery:
///   Each stage is a child workflow. If the orchestrator process crashes
///   mid-pipeline, Strand replays from the last completed stage boundary.
///   Inside Stage 1, individual chunk workflows are independently retried.
struct GroundwaterPipelineWorkflow: Workflow {
    typealias Input = PipelineInput
    typealias Output = PipelineResult

    mutating func run(
        context: WorkflowContext<Self>,
        input: PipelineInput
    ) async throws -> PipelineResult {

        // taskCreatedAt extracts the 48-bit unix-ms timestamp embedded in the
        // UUIDv7 task ID — identical on every activation, no stored state needed.
        let startTime = context.taskCreatedAt ?? context.activationTime

        context.logger.info(
            "🌊 Groundwater pipeline starting",
            metadata: [
                "job_id": .string(input.jobID),
                "chunk_size": .string("\(input.chunkSize)"),
                "run_ai": .string("\(input.runAI)"),
            ]
        )

        // ── Stage 1: Discover total rows ───────────────────────────────────────
        let discovery = try await context.runActivity(
            DiscoverActivity.self,
            input: DiscoverInput(jobID: input.jobID),
            options: ActivityOptions(maxAttempts: 3)
        )
        let totalRows = discovery.totalRows

        let rawChunkCount = (totalRows + input.chunkSize - 1) / input.chunkSize
        let chunkCount = input.maxChunks.map { min($0, rawChunkCount) } ?? rawChunkCount

        context.logger.info(
            "Dispatching \(chunkCount) of \(rawChunkCount) chunks (\(totalRows) rows total)",
            metadata: ["job_id": .string(input.jobID)]
        )

        // ── Stage 2: Ingest all chunks in parallel ─────────────────────────────
        var ingestionResults: [IngestChunkOutput] = []
        try await withThrowingTaskGroup(of: IngestChunkOutput.self) { group in
            for i in 0..<chunkCount {
                let offset = i * input.chunkSize
                let limit = min(input.chunkSize, totalRows - offset)
                let chunkInput = IngestChunkInput(
                    jobID: input.jobID,
                    offset: offset,
                    limit: limit
                )
                group.addTask {
                    try await context.runChildWorkflow(
                        IngestChunkWorkflow.self,
                        options: .init(queue: "gw-ingestion"),
                        input: chunkInput
                    )
                }
            }
            for try await result in group { ingestionResults.append(result) }
        }

        let totalInserted = ingestionResults.reduce(0) { $0 + $1.rowsInserted }
        context.logger.info(
            "Ingestion complete: \(totalInserted) rows in \(chunkCount) chunks",
            metadata: ["job_id": .string(input.jobID)]
        )

        // ── Stage 3: Compute per-county statistics ─────────────────────────────
        let statsResult = try await context.runChildWorkflow(
            StatsWorkflow.self,
            options: .init(queue: "gw-analytics"),
            input: StatsInput(jobID: input.jobID)
        )
        context.logger.info(
            "Stats complete: \(statsResult.countiesProcessed) counties",
            metadata: ["job_id": .string(input.jobID)]
        )

        // ── Stage 4: AI trend analysis (optional) ──────────────────────────────
        var aiResult: AIAnalysisOutput?
        if input.runAI && !statsResult.counties.isEmpty {
            let ai = try await context.runChildWorkflow(
                AIAnalysisWorkflow.self,
                options: .init(queue: "gw-ai"),
                input: AIAnalysisInput(
                    jobID: input.jobID,
                    counties: statsResult.counties
                )
            )
            aiResult = ai
            context.logger.info(
                "AI complete: \(ai.declining.count) dec / \(ai.stable.count) stable / \(ai.recovering.count) rec",
                metadata: ["job_id": .string(input.jobID)]
            )
        }

        // ── Finalise pipeline_runs record ──────────────────────────────────────
        let durationSecs = context.activationTime.timeIntervalSince(startTime)

        return PipelineResult(
            jobID: input.jobID,
            totalRows: totalRows,
            chunksIngested: chunkCount,
            rowsInserted: totalInserted,
            countiesAnalyzed: aiResult?.countiesAnalyzed ?? statsResult.countiesProcessed,
            durationSeconds: durationSecs
        )
    }
}
