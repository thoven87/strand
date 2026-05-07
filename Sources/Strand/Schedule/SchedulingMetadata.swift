import NIOCore
import PostgresNIO

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

// MARK: - PostgresCodable

/// Stores and retrieves `SchedulingMetadata` as a BYTEA JSON blob.
///
/// Strand's convention is plain BYTEA (no JSONB version-byte prefix), so we
/// provide a custom conformance rather than relying on PostgresNIO's default
/// `Codable` extension which targets `.jsonb`.
///
/// On the decode side PostgresNIO calls `context.jsonDecoder.decode(_:from:)`,
/// which dispatches to `JSONDecoder.decode(_:from:ByteBuffer)` (from
/// NIOFoundationCompat) and uses `byteTransferStrategy: .noCopy` internally —
/// zero extra Data allocation.
extension SchedulingMetadata: PostgresCodable {
    static var psqlType: PostgresDataType { .bytea }
    static var psqlFormat: PostgresFormat { .binary }

    func encode<JSONEncoder: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<JSONEncoder>
    ) throws {
        try context.jsonEncoder.encode(self, into: &byteBuffer)
    }

    init<JSONDecoder: PostgresJSONDecoder>(
        from buffer: inout ByteBuffer,
        type: PostgresDataType,
        format: PostgresFormat,
        context: PostgresDecodingContext<JSONDecoder>
    ) throws {
        guard case (.binary, .bytea) = (format, type) else {
            throw PostgresDecodingError.Code.typeMismatch
        }
        self = try context.jsonDecoder.decode(SchedulingMetadata.self, from: buffer)
    }
}
