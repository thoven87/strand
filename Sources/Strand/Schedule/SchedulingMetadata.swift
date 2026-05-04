#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// Scheduling metadata injected into every task fired by ``StrandScheduler``.
///
/// Fields:
/// - `partitionTime`: the period boundary the task covers (e.g. midnight for a
///   daily job) — the offset has already been stripped.
/// - `scheduleOffset`: the raw ISO 8601 offset string from the pattern
///   (e.g. `"PT15M"` for `.daily(offset: "PT15M")`). `nil` when the offset
///   is zero (`"PT0M"` / `"PT0H"`).
/// - `executionTime`: when the scheduler actually fired the task (wall clock).
///
/// The relationship is: `executionTime ≈ partitionTime + scheduleOffset`.
/// Small gaps are possible due to scheduler poll latency.
public struct SchedulingMetadata: Codable, Sendable {
    /// Wall-clock time when the scheduler fired the task.
    public let executionTime: Date

    /// Period boundary this task covers.
    /// For `.daily(offset: "PT15M")` firing at 00:15 UTC: `partitionTime = 00:00 UTC`.
    /// For `.weekly(offset: "P6DT9H")` firing Friday 09:00: `partitionTime = Sunday 00:00`.
    /// For `.interval(90 min)` firing at 01:45: `partitionTime = 01:30`.
    public let partitionTime: Date?

    /// The schedule pattern's own offset, verbatim from the pattern.
    /// `nil` when the offset is zero ("PT0M" / "PT0H") — no shift was applied.
    /// Together with `partitionTime` this lets consumers reconstruct the exact
    /// fire time: `partitionTime + scheduleOffset ≈ executionTime`.
    public let scheduleOffset: String?

    /// UUID of the schedule that triggered this task.
    public let scheduleId: String?

    /// Human-readable name of the schedule.
    public let scheduledBy: String?

    /// Metadata format version.
    public let version: Int

    public init(
        executionTime: Date,
        partitionTime: Date? = nil,
        scheduleOffset: String? = nil,
        scheduleId: String? = nil,
        scheduledBy: String? = nil,
        version: Int = 1
    ) {
        self.executionTime = executionTime
        self.partitionTime = partitionTime
        self.scheduleOffset = scheduleOffset
        self.scheduleId = scheduleId
        self.scheduledBy = scheduledBy
        self.version = version
    }
}

extension SchedulingMetadata {
    /// The single header key under which the full ``SchedulingMetadata`` JSON is stored.
    ///
    /// ``StrandScheduler`` encodes the struct here; ``SchedulingMetadata/from(headers:)``
    /// decodes it. Having one key with a typed payload is safer than multiple
    /// individual string keys that can drift out of sync.
    package static let headerKey = "$strand:scheduling"

    /// Decodes the scheduling metadata written by ``StrandScheduler`` from the task
    /// headers. Returns `nil` when the task was enqueued directly (not via a schedule).
    ///
    /// Called once per activation in `_WorkflowActivation.init` and stored as a typed
    /// field — not re-parsed on every ``WorkflowContext/schedulingMetadata`` access.
    package static func from(headers: [String: String]) -> SchedulingMetadata? {
        guard let json = headers[headerKey] else { return nil }
        return try? JSONDecoder().decode(SchedulingMetadata.self, from: Data(json.utf8))
    }
}
