import Foundation
import Strand

/// Top-level orchestrator: counts records, divides them into partitions,
/// and runs N `SlidingWindowWorkflow` children in parallel.
@Workflow
struct BatchWorkflow {
    typealias Input = BatchInput
    typealias Output = BatchOutput

    mutating func run(
        context: WorkflowContext<Self>,
        input: BatchInput
    ) async throws -> BatchOutput {
        context.logger.info(
            "BatchWorkflow starting",
            metadata: [
                "total_records": "\(input.totalRecords)",
                "window_size": "\(input.windowSize)",
                "partitions": "\(input.partitions)",
                "page_size": "\(input.pageSize)",
            ]
        )

        // ── Count records
        let total = try await context.runActivity(
            BatchActivities.GetRecordCount.self,
            input: GetRecordCountInput(),
            options: ActivityOptions(timeout: .seconds(5), maxAttempts: 3)
        )

        guard total > 0 else {
            context.logger.info("No records to process")
            return BatchOutput(processed: 0)
        }

        // ── Divide into partitions ────────────────────────────────────────────
        let partitionSizes = divide(total, into: input.partitions)
        let windowSizes = divide(input.windowSize, into: input.partitions)

        context.logger.info(
            "Launching partitions",
            metadata: [
                "partition_sizes": "\(partitionSizes)",
                "window_sizes": "\(windowSizes)",
            ]
        )

        // ── Fan out to sliding-window child workflows ──────────────────────────
        var totalProcessed = 0
        var offset = 0
        var partitionInputs: [(idx: Int, partInput: SlidingWindowInput)] = []

        for i in 0..<input.partitions {
            let pOffset = offset
            let pMaxOffset = min(offset + partitionSizes[i], total)
            let pWindow = max(1, windowSizes[i])
            partitionInputs.append(
                (
                    idx: i,
                    partInput: SlidingWindowInput(
                        offset: pOffset,
                        maxOffset: pMaxOffset,
                        windowSize: pWindow,
                        pageSize: input.pageSize,
                        activeRecords: [],
                        progress: 0
                    )
                )
            )
            offset += partitionSizes[i]
        }

        try await withThrowingTaskGroup(of: SlidingWindowOutput.self) { group in
            for entry in partitionInputs {
                group.addTask {
                    try await context.runChildWorkflow(
                        SlidingWindowWorkflow.self,
                        options: ChildWorkflowOptions(id: "partition-\(entry.idx)"),
                        input: entry.partInput
                    )
                }
            }
            for try await result in group {
                totalProcessed += result.processed
            }
        }

        context.logger.info("🏁 Batch complete", metadata: ["total": "\(totalProcessed)"])
        return BatchOutput(processed: totalProcessed)
    }
}

/// Divides `n` into `k` roughly equal parts (first parts get +1 when remainder > 0).
private func divide(_ n: Int, into k: Int) -> [Int] {
    guard k > 0 else { return [] }
    let base = n / k
    let rem = n % k
    return (0..<k).map { i in base + (i < rem ? 1 : 0) }
}
