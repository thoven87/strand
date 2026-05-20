import Strand

/// Processes a single chunk of the CNRA dataset: download → parse → insert.
///
/// Each chunk is a separate Strand workflow on the `gw-ingestion` queue,
/// giving independent crash recovery. If a worker dies mid-download, only
/// that 50k-row chunk is retried — not the entire 6M-row dataset.
///
/// `DownloadAndInsertActivity` handles:
///   - Streaming download via URLSession.bytes
///   - Line-by-line CSV parsing
///   - Batched bulk insert (200 rows/transaction)
///   - heartbeat() every 1 000 rows to keep the lease alive
///
/// Rate limiting: `CNRA.cnraDownloadRPS` (default 5/s) controls how quickly
/// the 125-chunk fan-out is released to the worker pool.  This prevents
/// flooding the public CNRA API regardless of how many workers are running.
struct IngestChunkWorkflow: Workflow {
    typealias Input = IngestChunkInput
    typealias Output = IngestChunkOutput

    mutating func run(
        context: WorkflowContext<Self>,
        input: IngestChunkInput
    ) async throws -> IngestChunkOutput {
        try await context.runActivity(
            DownloadAndInsertActivity.self,
            input: input,
            options: ActivityOptions(
                maxAttempts: 3,
                retryStrategy: .backoff(initial: .seconds(10), multiplier: 2, cap: .seconds(120)),
                // Rate-limit CNRA API calls.  `available_at` is staggered by
                // Strand's slot allocator so at most `cnraDownloadRPS` new
                // downloads enter the claimable pool each second — even when
                // 125 chunks are enqueued simultaneously.  The global key (nil)
                // means ALL chunk downloads share one bucket across every worker.
                rateLimit: .init(limit: CNRA.cnraDownloadRPS, period: .seconds(1))
            )
        )
    }
}
