#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// MARK: - ScheduleAccuracy

/// Controls how a ``StrandScheduler`` behaves when it starts up and finds
/// that one or more schedule slots were missed (e.g. the scheduler was offline).
public enum ScheduleAccuracy: Sendable, Codable, Equatable {
    /// Fire only the single most-recent elapsed slot and skip older ones.
    /// This is the default — it avoids flooding the queue with stale work
    /// when the scheduler restarts after a long outage.
    case latest
    /// Fire every missed slot in chronological order.
    /// Use this when every execution must happen (e.g. financial reconciliation).
    case all
    /// Fire only the last `n` missed slots in chronological order.
    /// Useful for controlled back-fill: e.g. `.last(3)` after a week-long
    /// outage fires the three most-recent slots and skips the rest.
    case last(Int)

    // MARK: - Codable (stored as plain string: "latest", "all", "last:3")

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(dbString: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(dbString)
    }

    // MARK: - DB string representation

    /// Initialise from the TEXT value stored in `strand.schedules.accuracy`.
    /// Unknown / malformed values fall back to `.latest` so old rows are safe.
    init(dbString: String) {
        switch dbString {
        case "all": self = .all
        case "latest": self = .latest
        default:
            if dbString.hasPrefix("last:"),
                let n = Int(dbString.dropFirst(5)), n > 0
            {
                self = .last(n)
            } else {
                self = .latest
            }
        }
    }

    /// The TEXT value written to `strand.schedules.accuracy`.
    var dbString: String {
        switch self {
        case .latest: return "latest"
        case .all: return "all"
        case .last(let n): return "last:\(n)"
        }
    }
}

// MARK: - ScheduleOptions

/// Task-level options applied to each run fired by a ``StrandScheduler``.
public struct ScheduleOptions: Sendable {
    public var maxAttempts: Int?
    public var retryStrategy: RetryStrategy?
    public var cancellation: CancellationPolicy?
    /// Extra headers injected into every fired task.
    /// Strand adds its own `$strand:*` scheduling headers automatically.
    public var headers: [String: String]
    /// How to handle missed schedule slots on catch-up. Defaults to `.latest`.
    public var accuracy: ScheduleAccuracy

    public init(
        maxAttempts: Int? = nil,
        retryStrategy: RetryStrategy? = nil,
        cancellation: CancellationPolicy? = nil,
        headers: [String: String] = [:],
        accuracy: ScheduleAccuracy = .latest
    ) {
        self.maxAttempts = maxAttempts
        self.retryStrategy = retryStrategy
        self.cancellation = cancellation
        self.headers = headers
        self.accuracy = accuracy
    }
}

// MARK: - ScheduleSummary

/// Read model returned by ``StrandClient/listSchedules(queue:)``.
public struct ScheduleSummary: Sendable, Codable {
    public let id: UUID
    public let name: String
    public let queue: String
    public let taskName: String
    public let pattern: SchedulePattern
    public let isActive: Bool
    /// First eligible fire date — schedule will not fire before this.
    /// A past date enables missed-run recovery: Strand fires the most recent
    /// elapsed slot on the next poll rather than starting fresh.
    /// `nil` means active from creation.
    public let startsAt: Date?
    /// Last eligible fire date — schedule is deactivated once no future slots
    /// remain within this window. `nil` means runs indefinitely.
    public let endsAt: Date?
    public let nextRunAt: Date?
    public let lastRunAt: Date?
    public let lastTaskID: UUID?
    public let runCount: Int
    public let accuracy: ScheduleAccuracy
    public let kind: TaskKind  // 'WORKFLOW' or 'ACTIVITY'
    public let createdAt: Date
}

// MARK: - SchedulerOptions

/// Configuration for a ``StrandScheduler`` instance.
public struct SchedulerOptions: Sendable {
    /// Maximum time the scheduler will sleep between checks.
    ///
    /// The scheduler sleeps precisely until the next known fire time, but
    /// wakes at least this often to detect newly-added schedules and handle
    /// DB updates. Defaults to 60 seconds.
    ///
    /// For schedules with intervals shorter than this cap, the scheduler
    /// wakes exactly on time (not at cap). The cap only matters when there
    /// are no imminent fires or when a new schedule is added at runtime.
    public var sleepCap: Duration

    /// Maximum number of missed slots fired in a single `fire()` invocation
    /// when `accuracy` is `.all` or `.last(n)`.
    ///
    /// After `maxCatchupSlots` slots have been enqueued, `markScheduleFired`
    /// advances `next_run_at` to the slot immediately after the last one fired.
    /// The remaining overdue slots are picked up on the next poll cycle.
    ///
    /// This bounds the latency of a single `fire()` call regardless of backlog
    /// size.  Defaults to 1 000; set lower for very high-frequency schedules or
    /// resource-constrained environments.
    public var maxCatchupSlots: Int

    /// Maximum number of due schedules claimed per poll cycle.
    ///
    /// When more than `pollLimit` schedules fire simultaneously (e.g. after an
    /// outage), the remainder are left for the next poll cycle.  Increasing
    /// this value reduces catch-up time at the cost of a wider burst of
    /// concurrent `fire()` invocations per poll.  Defaults to 100.
    public var pollLimit: Int

    public init(
        sleepCap: Duration = .seconds(60),
        maxCatchupSlots: Int = 1_000,
        pollLimit: Int = 100
    ) {
        self.sleepCap = sleepCap
        self.maxCatchupSlots = maxCatchupSlots
        self.pollLimit = pollLimit
    }
}

// MARK: - Month

/// A calendar month for use with `.yearly` schedule patterns.
///
/// Raw values are 1-indexed (January = 1) matching `Calendar.Component.month`.
///
/// ```swift
/// .yearly(month: .march, day: 15, hour: 10)  // March 15th at 10:00 UTC every year
/// ```
public enum Month: Int, Sendable, Comparable, CaseIterable {
    case january = 1
    case february = 2
    case march = 3
    case april = 4
    case may = 5
    case june = 6
    case july = 7
    case august = 8
    case september = 9
    case october = 10
    case november = 11
    case december = 12

    public static func < (lhs: Month, rhs: Month) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Weekday

/// A day of the week for use with `.weekly` schedule patterns.
///
/// The raw value encodes the internal P{n}D ISO 8601 duration offset:
/// `.saturday` = `P0D`, `.sunday` = `P1D`, `.monday` = `P2D`, etc.
///
/// ```swift
/// .weekly(on: .monday, hour: 9)        // every Monday at 09:00 UTC
/// .weekly(on: .friday, hour: 17, minute: 30)  // every Friday at 17:30 UTC
/// ```
public enum Weekday: Int, Sendable, CaseIterable {
    /// P0D — the internal epoch origin for weekly schedules.
    case saturday = 0
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
}
