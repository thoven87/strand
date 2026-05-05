#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// MARK: - Partition Offset Configuration

public struct PartitionOffsetConfig: Codable, Sendable {
    /// The ISO 8601 duration to subtract from execution time to get partition time
    public let offset: ISO8601Duration

    /// Whether to use default offsets for well-known schedules
    public let useDefaultOffsets: Bool

    /// Custom timezone for partition calculations (defaults to UTC)
    public let timezone: TimeZone

    public init(
        offset: ISO8601Duration,
        useDefaultOffsets: Bool = true,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) {
        self.offset = offset
        self.useDefaultOffsets = useDefaultOffsets
        self.timezone = timezone
    }

    /// Create with ISO 8601 duration string
    public init(
        offset: String,
        useDefaultOffsets: Bool = true,
        timezone: TimeZone = TimeZone(identifier: "UTC")!
    ) throws {
        self.offset = try ISO8601Duration(offset)
        self.useDefaultOffsets = useDefaultOffsets
        self.timezone = timezone
    }

    /// Create with ISO 8601 duration string and timezone
    public init(offset: String, timezone: TimeZone) throws {
        self.offset = try ISO8601Duration(offset)
        self.useDefaultOffsets = true
        self.timezone = timezone
    }
}
