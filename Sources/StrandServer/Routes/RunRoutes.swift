import Hummingbird
import Logging
import PostgresNIO
import Strand

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct RunRoutes {
    let postgres: PostgresClient
    let logger: Logger

    func register(on router: some RouterMethods<StrandRequestContext>) {

        router.get("queues/:queue/tasks/:taskID/runs") { req, ctx -> [RunResponse] in
            let taskID = try ctx.parameters.require("taskID", as: UUID.self)
            let rows = try await ManagementQueries.listRuns(
                on: self.postgres, namespaceID: ctx.namespaceID, taskID: taskID,
                logger: self.logger)
            return rows.map(RunResponse.init)
        }

        router.get("queues/:queue/tasks/:taskID/runs/:runID/checkpoints") {
            _, ctx -> [CheckpointResponse] in
            let runID = try ctx.parameters.require("runID", as: UUID.self)
            let rows = try await ManagementQueries.listCheckpoints(
                on: self.postgres, runID: runID, logger: self.logger)
            return rows.map(CheckpointResponse.init)
        }
    }
}
