import Hummingbird
import Logging
import NIOCore
import PostgresNIO
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct WorkflowRoutes {
    let client: StrandClient
    // Convenience accessors — kept for clarity in route handlers.
    var postgres: PostgresClient { client.postgres }
    var logger: Logger { client.logger }
    var namespaceID: String { client.namespaceID }

    private struct TriggerBody: Decodable {
        let workflowName: String
        let queue: String?
        /// Raw JSON string forwarded verbatim as the task's `params` column.
        let input: String
    }

    func register(on router: some RouterMethods<StrandRequestContext>) {

        // POST /api/:namespace/workflows/run
        // Body: { "workflowName": "MyWorkflow", "queue": "orders", "input": "{...}" }
        // `input` must be a valid JSON string (e.g. `"{}"` for void params).
        router.post("workflows/run") { req, ctx -> EnqueueResultResponse in
            let body = try await req.decode(as: TriggerBody.self, context: ctx)
            let targetQueue = body.queue ?? "default"
            let inputBuffer = ByteBuffer(string: body.input)

            let result = try await self.client.enqueueRaw(
                queue: targetQueue,
                namespaceID: ctx.namespaceID,
                taskName: body.workflowName,
                paramsBuffer: inputBuffer
            )
            return EnqueueResultResponse(from: result)
        }
    }
}
