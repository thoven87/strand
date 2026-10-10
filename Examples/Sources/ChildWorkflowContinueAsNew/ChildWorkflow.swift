import Strand

// MARK: - ChildWorkflow

/// A workflow that processes work across multiple `continueAsNew` runs.
///
/// Each run increments `totalCount` and decrements `remainingRuns`. When
/// `remainingRuns` reaches zero the workflow returns its final result.
/// All intermediate runs are invisible to the parent — the parent's
/// `runChildWorkflow` call blocks until the *entire chain* completes.
///
/// ## Why continueAsNew here?
///
/// Without `continueAsNew`, a long-running child would accumulate one
/// activity-history entry per run, causing `loadCompletedChildActivities`
/// to grow unboundedly on every re-activation. `continueAsNew` resets the
/// child's history to zero on each hop, keeping per-activation cost O(1)
/// regardless of how many iterations the child has processed.
///
@Workflow
struct ChildWorkflow {
    typealias Input = ChildInput
    typealias Output = String

    mutating func run(
        context: WorkflowContext<Self>,
        input: ChildInput
    ) async throws -> String {

        guard input.remainingRuns > 0 else {
            context.logger.error(
                "Invalid remainingRuns — must be > 0",
                metadata: ["remainingRuns": "\(input.remainingRuns)"]
            )
            throw ChildWorkflowError.invalidRunCount
        }

        let newTotal = input.totalCount + 1
        let newRemaining = input.remainingRuns - 1

        if newRemaining == 0 {
            // Final run — return result to the parent.
            let result = "Child workflow execution completed after \(newTotal) runs"
            context.logger.info(
                "Child completed",
                metadata: ["total_count": "\(newTotal)", "result": .string(result)]
            )
            return result
        }

        // More runs to go — continue as new so this run's history stays small.
        // The parent does NOT wake up; it continues waiting for the final result.
        context.logger.info(
            "Child continuing as new",
            metadata: [
                "total_count": "\(newTotal)",
                "remaining_runs": "\(newRemaining)",
            ]
        )
        try context.continueAsNew(
            input: ChildInput(totalCount: newTotal, remainingRuns: newRemaining)
        )
    }
}

// MARK: - I/O

struct ChildInput: Codable, Sendable {
    /// Number of runs completed so far across the entire chain.
    let totalCount: Int
    /// Number of runs still needed (including this one).
    let remainingRuns: Int
}

// MARK: - Errors

enum ChildWorkflowError: Error {
    case invalidRunCount
}
