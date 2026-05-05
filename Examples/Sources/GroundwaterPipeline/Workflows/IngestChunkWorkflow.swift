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
            // 3 retries with exponential backoff — handles transient CNRA API hiccups.
            // startToCloseTimeout mirrors the activity's own URLSession timeout (600s).
            options: ActivityOptions(
                maxAttempts: 3,
                retryStrategy: .backoff(initial: .seconds(10), multiplier: 2, cap: .seconds(120))
            )
        )
    }
}
