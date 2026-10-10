import Strand

// MARK: - ParentWorkflow

/// Orchestrator that spawns a single `ChildWorkflow` and waits for it.
///
/// From the parent's perspective the child is one atomic operation: it
/// schedules `ChildWorkflow`, blocks, and eventually receives a single
/// result string. The child's internal `continueAsNew` hops are completely
/// transparent — the parent is never re-activated for them.
///
@Workflow
struct ParentWorkflow {
    typealias Input = ParentInput
    typealias Output = String

    mutating func run(
        context: WorkflowContext<Self>,
        input: ParentInput
    ) async throws -> String {

        context.logger.info(
            "Parent starting — spawning child",
            metadata: [
                "total_runs_requested": "\(input.totalRuns)"
            ]
        )

        // runChildWorkflow blocks until the *full chain* completes.
        // The parent is re-activated exactly once: when the final child run
        // calls `return result` instead of `continueAsNew`.
        //
        // Note: ChildWorkflowOptions.id is a *display label* in the Loom UI,
        // not a deduplication key. The idempotency key is always auto-generated
        // as "<parentTaskUUID>:<seqNum>" so loadCompletedChildActivities can
        // route the result back to the correct continuation on replay.
        let result = try await context.runChildWorkflow(
            ChildWorkflow.self,
            options: ChildWorkflowOptions(id: "child-continue-as-new"),  // display label
            input: ChildInput(totalCount: 0, remainingRuns: input.totalRuns)
        )

        context.logger.info("Parent completed", metadata: ["result": .string(result)])
        return result
    }
}

// MARK: - I/O

struct ParentInput: Codable, Sendable {
    /// How many child runs to execute before the child returns its result.
    let totalRuns: Int
}
