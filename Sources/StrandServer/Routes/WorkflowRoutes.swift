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
        /// Raw serialised input (JSON when using the default ``JSONCodec``).
        /// Transformed through the configured codec before storage so that
        /// custom codecs (AES, compression) apply transparently.
        let input: String
        /// Optional human-readable description stored as `"strand-description"` in headers.
        let description: String?
    }

    private struct EnqueueActivityBody: Decodable {
        let activityName: String
        let queue: String?
        /// Raw serialised input — see `TriggerBody.input`.
        let input: String
        /// Optional human-readable description stored as `"strand-description"` in headers.
        let description: String?
    }

    func register(on router: some RouterMethods<StrandRequestContext>) {

        // POST /api/:namespace/workflows/run
        // Body: { "workflowName": "MyWorkflow", "queue": "orders", "input": "{...}" }
        // `input` must be a valid JSON string (e.g. `"{}"` for void params).
        router.post("workflows/run") { req, ctx -> EnqueueResultResponse in
            let body = try await req.decode(as: TriggerBody.self, context: ctx)
            let targetQueue = body.queue ?? "default"
            let result = try await self.client.enqueueRaw(
                queue: targetQueue,
                namespaceID: ctx.namespaceID,
                taskName: body.workflowName,
                paramsBuffer: ByteBuffer(string: body.input),
                description: body.description
            )
            return EnqueueResultResponse(from: result)
        }

        // POST /api/:namespace/activities/enqueue
        // Body: { "activityName": "ChargeCardActivity", "queue": "orders", "input": "{...}" }
        // Enqueues a standalone activity (kind = ACTIVITY) without a parent workflow.
        router.post("activities/enqueue") { req, ctx -> EnqueueResultResponse in
            let body = try await req.decode(as: EnqueueActivityBody.self, context: ctx)
            let targetQueue = body.queue ?? "default"
            let inputBuffer = ByteBuffer(string: body.input)

            let result = try await self.client.enqueueRaw(
                queue: targetQueue,
                namespaceID: ctx.namespaceID,
                taskName: body.activityName,
                paramsBuffer: inputBuffer,
                kind: .activity,
                description: body.description
            )
            return EnqueueResultResponse(from: result)
        }
    }
}
