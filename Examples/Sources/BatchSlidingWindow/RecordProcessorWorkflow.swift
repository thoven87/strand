import Foundation
import Strand

/// Processes a single record, then signals the parent SlidingWindowWorkflow.
///
/// ## Cross-workflow signal
///
/// After simulating work with the `ProcessRecord` activity, this workflow calls
/// `context.signalExternalWorkflow` to notify the parent without going through
/// an activity or external client.
///
/// ```swift
/// try context.signalExternalWorkflow(
///     SlidingWindowWorkflow.RecordCompleted.self,
///     taskID: input.parentTaskID,
///     payload: input.recordID
/// )
/// ```
///
/// `input.parentTaskID` is the SlidingWindowWorkflow's `context.workflowID` — stable
/// across `continueAsNew` because SlidingWindowWorkflow is a child workflow and its
/// task UUID is preserved by `continueChildWorkflowAsNew`.
@Workflow
struct RecordProcessorWorkflow {
    typealias Input = RecordProcessorInput
    typealias Output = Int  // returns the processed recordID as confirmation

    mutating func run(
        context: WorkflowContext<Self>,
        input: RecordProcessorInput
    ) async throws -> Int {
        context.logger.info(
            "Processing record",
            metadata: [
                "record_id": "\(input.recordID)",
                "parent_id": "\(input.parentTaskID)",
                "processing": "\(input.processingMs)ms",
            ]
        )

        try await context.runActivity(
            BatchActivities.ProcessRecord.self,
            input: ProcessRecordInput(
                recordID: input.recordID,
                processingMs: input.processingMs
            ),
            options: ActivityOptions(
                timeout: .seconds(30),
                maxAttempts: 3
            )
        )

        // ── Cross-workflow signal (the key demo) ──────────────────────────────
        // Notify the parent SlidingWindowWorkflow that this record is done.
        try context.signalExternalWorkflow(
            SlidingWindowWorkflow.RecordCompleted.self,
            taskID: input.parentTaskID,
            payload: input.recordID
        )

        context.logger.info(
            "Record completed and parent notified",
            metadata: ["record_id": "\(input.recordID)"]
        )

        return input.recordID
    }
}
