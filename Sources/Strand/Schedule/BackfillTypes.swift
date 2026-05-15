import Logging
import NIOCore
import PostgresNIO

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// MARK: - BackfillOptions

/// Options controlling how a backfill is executed.
public struct BackfillOptions: Sendable {
    /// Maximum number of slots executing concurrently during the backfill.
    /// Does not affect normally-scheduled executions.
    public var concurrency: Int

    /// Whether to re-run slots that already have a completed task with the
    /// same idempotency key. When `false` (default) those slots are skipped.
    public var allowOverwrite: Bool

    /// Human-readable note explaining why this backfill was created.
    public var description: String?

    public init(
        concurrency: Int = 1,
        allowOverwrite: Bool = false,
        description: String? = nil
    ) {
        self.concurrency = max(1, concurrency)
        self.allowOverwrite = allowOverwrite
        self.description = description
    }
}

// MARK: - BackfillHandle

/// A reference to a running backfill. Returned by `StrandClient.createBackfill`.
public struct BackfillHandle: Sendable {
    /// Stable identifier for this backfill.
    public let id: UUID

    private let postgres: PostgresClient
    private let namespaceID: String
    private let logger: Logger

    init(id: UUID, postgres: PostgresClient, namespaceID: String, logger: Logger) {
        self.id = id
        self.postgres = postgres
        self.namespaceID = namespaceID
        self.logger = logger
    }

    /// Stop enqueueing new slots and cancel any PENDING (not-yet-started)
    /// slots that were already enqueued.
    ///
    /// Tasks that are currently RUNNING are left to complete — they have
    /// already started work. Only slots that have not yet been claimed by a
    /// worker (state = PENDING) are cancelled, preventing them from being
    /// picked up after the halt.
    public func halt() async throws {
        try await BackfillQueries.halt(
            on: postgres,
            backfillID: id,
            namespaceID: namespaceID,
            logger: logger
        )
    }

    /// Resume a halted backfill.
    public func resume() async throws {
        try await BackfillQueries.resume(
            on: postgres,
            backfillID: id,
            namespaceID: namespaceID,
            logger: logger
        )
    }

    /// Change the maximum concurrency in-flight. Takes effect on the next
    /// `StrandScheduler` poll cycle.
    public func setConcurrency(_ n: Int) async throws {
        try await BackfillQueries.setConcurrency(
            on: postgres,
            backfillID: id,
            concurrency: n,
            namespaceID: namespaceID,
            logger: logger
        )
    }

    /// Returns the current status snapshot.
    public func status() async throws -> BackfillStatus {
        guard
            let row = try await BackfillQueries.get(
                on: postgres,
                backfillID: id,
                namespaceID: namespaceID,
                logger: logger
            )
        else {
            throw StrandError.database(underlying: QueryError("backfill not found"))
        }
        return BackfillStatus(from: row)
    }
}

// MARK: - BackfillStatus

public struct BackfillStatus: Sendable {
    public let id: UUID
    public let state: BackfillState
    public let totalSlots: Int
    public let completedSlots: Int
    public let concurrency: Int
    public let nextSlotTime: Date
    public let createdAt: Date
    public let completedAt: Date?

    public var progressFraction: Double {
        guard totalSlots > 0 else { return 0 }
        return Double(completedSlots) / Double(totalSlots)
    }

    init(from row: BackfillQueries.BackfillRow) {
        id = row.id
        state = BackfillState(raw: row.status)
        totalSlots = row.totalSlots
        completedSlots = row.completedSlots
        concurrency = row.concurrency
        nextSlotTime = row.nextSlotTime
        createdAt = row.createdAt
        completedAt = row.completedAt
    }
}

// MARK: - BackfillState

public enum BackfillState: Sendable {
    case running
    case halted
    case completed
    case failed

    init(raw: BackfillQueries.BackfillStatus) {
        switch raw {
        case .running: self = .running
        case .halted: self = .halted
        case .completed: self = .completed
        case .failed: self = .failed
        }
    }
}
