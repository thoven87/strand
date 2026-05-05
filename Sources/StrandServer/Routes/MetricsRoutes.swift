import Hummingbird
import Logging
import PostgresNIO
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct MetricsResponse: Codable, Sendable {
    struct Bucket: Codable, Sendable {
        /// ISO 8601 hour string e.g. "2026-05-01T14:00:00Z"
        let hour: String
        let count: Int
    }
    let completed: Int
    let failed: Int
    let cancelled: Int
    let pending: Int
    let running: Int
    let avgDurationMs: Int?
    /// Completed tasks per hour for the last 24 h.
    let throughputPerHour: [Bucket]
    /// Failed tasks per hour for the last 24 h.
    let errorRatePerHour: [Bucket]
}
extension MetricsResponse: ResponseCodable {}

struct MetricsRoutes {
    let postgres: PostgresClient
    let defaultNamespaceID: String
    let logger: Logger

    func register(on router: some RouterMethods<StrandRequestContext>) {

        // GET /api/:namespace/metrics
        router.get("metrics") { _, ctx -> MetricsResponse in
            let ns = ctx.namespaceID

            // ── Summary counts (last 24 h) ────────────────────────────────────
            let summaryStream = try await self.postgres.query(
                """
                SELECT
                  COALESCE(SUM(CASE WHEN state = 'COMPLETED' THEN 1 ELSE 0 END), 0) AS completed,
                  COALESCE(SUM(CASE WHEN state = 'FAILED'    THEN 1 ELSE 0 END), 0) AS failed,
                  COALESCE(SUM(CASE WHEN state = 'CANCELLED' THEN 1 ELSE 0 END), 0) AS cancelled,
                  COALESCE(SUM(CASE WHEN state = 'PENDING'   THEN 1 ELSE 0 END), 0) AS pending,
                  COALESCE(SUM(CASE WHEN state IN ('RUNNING','SLEEPING','WAITING') THEN 1 ELSE 0 END), 0) AS running,
                  AVG(EXTRACT(EPOCH FROM (completed_at - created_at)) * 1000)::bigint AS avg_ms
                FROM strand.tasks
                WHERE namespace_id = \(ns)
                  AND created_at >= NOW() - INTERVAL '24 hours'
                """,
                logger: self.logger
            )

            var completed = 0
            var failed = 0
            var cancelled = 0
            var pending = 0
            var running = 0
            var avgDurationMs: Int? = nil
            if let row = try await summaryStream.first(where: { _ in true }) {
                var col = row.makeIterator()
                completed = try col.next()!.decode(Int.self, context: .default)
                failed = try col.next()!.decode(Int.self, context: .default)
                cancelled = try col.next()!.decode(Int.self, context: .default)
                pending = try col.next()!.decode(Int.self, context: .default)
                running = try col.next()!.decode(Int.self, context: .default)
                avgDurationMs = try col.next()!.decode(Int?.self, context: .default)
            }

            // ── Hourly throughput (completed tasks) ───────────────────────────
            let throughputStream = try await self.postgres.query(
                """
                SELECT
                  date_trunc('hour', created_at) AS hour,
                  COUNT(*) AS cnt
                FROM strand.tasks
                WHERE namespace_id = \(ns)
                  AND state = 'COMPLETED'
                  AND created_at >= NOW() - INTERVAL '24 hours'
                GROUP BY 1
                ORDER BY 1
                """,
                logger: self.logger
            )
            var throughput: [MetricsResponse.Bucket] = []
            for try await row in throughputStream {
                var col = row.makeIterator()
                let hour = try col.next()!.decode(Date.self, context: .default)
                let cnt = try col.next()!.decode(Int.self, context: .default)
                throughput.append(.init(hour: hour.ISO8601Format(), count: cnt))
            }

            // ── Hourly error rate (failed tasks) ──────────────────────────────
            let errorStream = try await self.postgres.query(
                """
                SELECT
                  date_trunc('hour', created_at) AS hour,
                  COUNT(*) AS cnt
                FROM strand.tasks
                WHERE namespace_id = \(ns)
                  AND state = 'FAILED'
                  AND created_at >= NOW() - INTERVAL '24 hours'
                GROUP BY 1
                ORDER BY 1
                """,
                logger: self.logger
            )
            var errors: [MetricsResponse.Bucket] = []
            for try await row in errorStream {
                var col = row.makeIterator()
                let hour = try col.next()!.decode(Date.self, context: .default)
                let cnt = try col.next()!.decode(Int.self, context: .default)
                errors.append(.init(hour: hour.ISO8601Format(), count: cnt))
            }

            return MetricsResponse(
                completed: completed,
                failed: failed,
                cancelled: cancelled,
                pending: pending,
                running: running,
                avgDurationMs: avgDurationMs,
                throughputPerHour: throughput,
                errorRatePerHour: errors
            )
        }
    }
}
