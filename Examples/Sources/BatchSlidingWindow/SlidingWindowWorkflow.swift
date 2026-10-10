import Foundation
import Strand

/// Processes a contiguous partition of records using a bounded sliding window.
///
/// ## Concurrency model
///
/// Up to `windowSize` `RecordProcessorWorkflow` children run in parallel via
/// `context.startChildWorkflow` (fire-and-forget). A `context.condition` gates
/// dispatch so the window never exceeds `windowSize` in-flight records.
///
/// ## Cross-workflow signals
///
/// Each `RecordProcessorWorkflow` sends a `RecordCompleted` signal via
/// `context.signalExternalWorkflow` when it finishes. The `@WorkflowSignal`
/// handler on this workflow updates `activeRecords` and `progress`, which
/// unblocks any waiting `condition` call.
///
/// ## continueAsNew
///
/// After dispatching a full page, this workflow calls `continueAsNew` (when
/// more records remain). Children use `parentClosePolicy: .abandon` so they
/// survive the transition. The in-flight record IDs are carried across via
/// `SlidingWindowInput.activeRecords`, restoring the Go sample's semantics:
/// `continueAsNew` fires while children are still running.
@Workflow
struct SlidingWindowWorkflow {
    typealias Input = SlidingWindowInput
    typealias Output = SlidingWindowOutput

    // ── Mutable state ─────────────────────────────────────────────────────────

    /// Record IDs currently being processed by child RecordProcessorWorkflows.
    /// Populated as children are dispatched; cleared as RecordCompleted signals arrive.
    /// Restored from `input.activeRecords` at the start of each continueAsNew hop.
    var activeRecords: Set<Int> = []

    /// Total records completed so far across all continueAsNew hops.
    var progress: Int = 0

    // ── Signal handler ────────────────────────────────────────────────────────

    /// Receives completion notifications from RecordProcessorWorkflow instances.
    ///
    /// Sent via `context.signalExternalWorkflow(SlidingWindowWorkflow.RecordCompleted, …)`
    /// in RecordProcessorWorkflow
    @WorkflowSignal
    mutating func recordCompleted(_ recordID: Int) {
        if activeRecords.remove(recordID) != nil {
            progress += 1
        }
        // Duplicate signals (at-least-once delivery) are ignored via the guard above.
    }

    // ── Orchestration ─────────────────────────────────────────────────────────

    mutating func run(
        context: WorkflowContext<Self>,
        input: SlidingWindowInput
    ) async throws -> SlidingWindowOutput {
        // Restore state from the previous continueAsNew hop.
        // activeRecords may be non-empty when children dispatched in the prior run
        // are still in-flight; their RecordCompleted signals will drain the set.
        activeRecords = Set(input.activeRecords)
        progress = input.progress

        context.logger.info(
            "SlidingWindowWorkflow",
            metadata: [
                "offset": "\(input.offset)",
                "max_offset": "\(input.maxOffset)",
                "window_size": "\(input.windowSize)",
                "active_records": "\(activeRecords.count)",
                "progress": "\(progress)",
                "history_events": "\(context.historyEventCount)",
            ]
        )

        // ── Load page of records ──────────────────────────────────────────────
        let page = try await context.runActivity(
            BatchActivities.GetRecords.self,
            input: GetRecordsInput(
                offset: input.offset,
                maxOffset: input.maxOffset,
                pageSize: input.pageSize
            ),
            options: ActivityOptions(timeout: .seconds(10), maxAttempts: 3)
        )

        guard !page.records.isEmpty else {
            context.logger.info("No more records in partition")
            return SlidingWindowOutput(processed: progress)
        }

        // Stable task UUID for this SlidingWindowWorkflow instance.
        // Preserved across continueAsNew because this is a child workflow.
        let myTaskID = context.workflowID
        let windowSize = input.windowSize

        // ── Sliding window via startChildWorkflow ─────────────────────────────
        for record in page.records {
            // Block until there is a free slot in the window.
            try await context.condition { w in w.activeRecords.count < windowSize }

            activeRecords.insert(record.id)

            // Fire-and-forget: returns immediately, child runs independently.
            // parentClosePolicy: .abandon ensures the child survives continueAsNew.
            _ = try context.startChildWorkflow(
                RecordProcessorWorkflow.self,
                options: .init(
                    id: "record-\(record.id)",
                    parentClosePolicy: .abandon
                ),
                input: RecordProcessorInput(
                    recordID: record.id,
                    parentTaskID: myTaskID,
                    processingMs: Int.random(in: 200...600)
                )
            )
        }

        let nextOffset = input.offset + page.records.count
        let hasMore = nextOffset < input.maxOffset

        // ── continueAsNew between pages ───────────────────────────────────────
        if hasMore {
            // Wait for at least one free slot before crossing the continueAsNew
            // boundary so the new run can start dispatching immediately.
            try await context.condition { w in w.activeRecords.count < windowSize }

            context.logger.info(
                "continueAsNew — passing in-flight records to next run",
                metadata: [
                    "next_offset": "\(nextOffset)",
                    "active_records": "\(activeRecords.count)",
                    "progress": "\(progress)",
                    "history_events": "\(context.historyEventCount)",
                ]
            )
            try context.continueAsNew(
                input: SlidingWindowInput(
                    offset: nextOffset,
                    maxOffset: input.maxOffset,
                    windowSize: input.windowSize,
                    pageSize: input.pageSize,
                    activeRecords: Array(activeRecords),
                    progress: progress
                )
            )
        }

        // Last page: wait for all in-flight children to complete via RecordCompleted signals.
        try await context.condition { w in w.activeRecords.isEmpty }
        context.logger.info("Partition done", metadata: ["progress": "\(progress)"])
        return SlidingWindowOutput(processed: progress)
    }
}
