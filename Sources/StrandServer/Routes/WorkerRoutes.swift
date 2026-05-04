import Hummingbird
import PostgresNIO
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct WorkerResponse: Codable, Sendable {
    let workerID: String
    let runningTasks: Int
    let completedRecently: Int
    let lastSeenAt: Date?
    let leaseExpiresAt: Date?
    let isHealthy: Bool  // true if leaseExpiresAt is in the future

    init(from row: WorkerRow) {
        workerID = row.workerID
        runningTasks = row.runningTasks
        completedRecently = row.completedRecently
        lastSeenAt = row.lastSeenAt
        leaseExpiresAt = row.leaseExpiresAt
        isHealthy = row.leaseExpiresAt.map { $0 > Date.now } ?? false
    }
}
extension WorkerResponse: ResponseCodable {}

struct WorkerRoutes {
    let postgres: PostgresClient
    let logger: Logger

    func register(on router: some RouterMethods<StrandRequestContext>) {
        // GET /api/:namespace/workers
        router.get("workers") { _, ctx -> [WorkerResponse] in
            let rows = try await ManagementQueries.listWorkers(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                logger: self.logger
            )
            return rows.map(WorkerResponse.init)
        }

        // GET /api/:namespace/workers/:workerID
        // workerID is URL-encoded (e.g. "host%3Apid" for "host:pid").
        // Returns nil (200 null) rather than 404 when the worker is no longer
        // active — consistent with WorkflowStateResponse? and other optional
        // routes in Strand. Workers can disappear between list and detail.
        router.get("workers/:workerID") { _, ctx -> WorkerDetailResponse? in
            // ctx.parameters returns the raw path segment — percent-encoded.
            // Decode so "host%3Apid" becomes the actual DB value "host:pid".
            let rawWorkerID = try ctx.parameters.require("workerID")
            let workerID = rawWorkerID.removingPercentEncoding ?? rawWorkerID
            let (summary, tasks) = try await ManagementQueries.getWorkerDetail(
                on: self.postgres,
                namespaceID: ctx.namespaceID,
                workerID: workerID,
                logger: self.logger
            )
            guard let s = summary else { return nil }
            return WorkerDetailResponse(
                workerID: s.workerID,
                runningTasks: s.runningTasks,
                completedRecently: s.completedRecently,
                lastSeenAt: s.lastSeenAt,
                leaseExpiresAt: s.leaseExpiresAt,
                isHealthy: s.leaseExpiresAt.map { $0 > Date.now } ?? false,
                recentTasks: tasks.map(WorkerTaskResponse.init)
            )
        }
    }
}
