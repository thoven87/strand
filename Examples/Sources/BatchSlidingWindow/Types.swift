import Foundation
import Strand

// ── BatchWorkflow ──────────────────────────────────────────────────────────────

struct BatchInput: Codable, Sendable {
    let totalRecords: Int
    let windowSize: Int  // max concurrent RecordProcessorWorkflows per partition
    let partitions: Int
    let pageSize: Int  // records per SlidingWindowWorkflow run before continueAsNew
}

struct BatchOutput: Codable, Sendable {
    let processed: Int
}

// ── SlidingWindowWorkflow ──────────────────────────────────────────────────────

struct SlidingWindowInput: Codable, Sendable {
    let offset: Int  // inclusive
    let maxOffset: Int  // exclusive
    let windowSize: Int
    let pageSize: Int
    /// In-flight record IDs when `continueAsNew` fires.
    ///
    /// Non-empty when `continueAsNew` is called while `RecordProcessorWorkflow`
    /// children are still running (fire-and-forget via `startChildWorkflow`).
    /// The new run restores this set and waits for the matching `RecordCompleted`
    /// signals before considering the window drained.
    var activeRecords: [Int]
    /// Cumulative completed count — survives all `continueAsNew` hops.
    var progress: Int
}

struct SlidingWindowOutput: Codable, Sendable {
    let processed: Int
}

// ── RecordProcessorWorkflow ────────────────────────────────────────────────────

struct RecordProcessorInput: Codable, Sendable {
    let recordID: Int
    /// SlidingWindowWorkflow task UUID — stable across continueAsNew hops because
    /// SlidingWindowWorkflow is a child workflow (continueChildWorkflowAsNew preserves its task ID).
    let parentTaskID: UUID
    let processingMs: Int
}

// ── Activities ─────────────────────────────────────────────────────────────────

/// Empty input for `getRecordCount` — the total is stored on `BatchActivities` itself.
struct GetRecordCountInput: Codable, Sendable {}

struct GetRecordsInput: Codable, Sendable {
    let offset: Int
    let maxOffset: Int
    let pageSize: Int
}

struct GetRecordsOutput: Codable, Sendable {
    struct Record: Codable, Sendable { let id: Int }
    let records: [Record]
}

struct ProcessRecordInput: Codable, Sendable {
    let recordID: Int
    let processingMs: Int
}
