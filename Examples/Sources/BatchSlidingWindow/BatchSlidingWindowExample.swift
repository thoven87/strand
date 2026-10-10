import Logging
import PostgresNIO
import ServiceLifecycle
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Batch Sliding Window
///
/// Demonstrates **cross-workflow signals** using `context.signalExternalWorkflow`.
///
/// Run:
///   cd Examples && swift run BatchSlidingWindow
@main struct BatchSlidingWindowExample {
    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput(label:))
        let logger = Logger(label: "batch-sw")

        print(
            """
            ╔══════════════════════════════════════════════════════╗
            ║     Batch Sliding Window — Cross-Workflow Signals    ║
            ╠══════════════════════════════════════════════════════╣
            ║  12 records · 2 partitions · window 2 · page 4      ║
            ║                                                      ║
            ║  RecordProcessorWorkflow                             ║
            ║    context.signalExternalWorkflow(RecordCompleted)   ║
            ║      → SlidingWindowWorkflow @WorkflowSignal handler ║
            ╚══════════════════════════════════════════════════════╝
            """
        )

        let env = ProcessInfo.processInfo.environment
        let postgres = PostgresClient(
            configuration: .init(
                host: env["POSTGRES_HOST"] ?? "localhost",
                port: Int(env["POSTGRES_PORT"] ?? "5499") ?? 5499,
                username: env["POSTGRES_USER"] ?? "strand",
                password: env["POSTGRES_PASSWORD"] ?? "strand",
                database: env["POSTGRES_DB"] ?? "strand_dev",
                tls: .disable
            ),
            backgroundLogger: logger
        )

        // ── Activity container: pure config, no Strand clients ───────────────
        let activities = BatchActivities(totalRecords: 12)

        let strand = StrandService(
            postgres: postgres,
            options: .init(
                queues: [
                    .init(
                        name: "batch-sw",
                        namespace: "batch-sw-demo",
                        workflows: [
                            BatchWorkflow.self,
                            SlidingWindowWorkflow.self,
                            RecordProcessorWorkflow.self,
                        ],
                        activityContainers: [activities],
                        workflowConcurrency: 20,
                        activityConcurrency: 20,
                        pollInterval: .milliseconds(100)
                    )
                ],
                logger: logger
            )
        )

        let client = strand.client(queue: "batch-sw", namespace: "batch-sw-demo")

        Task {
            do {
                try await Task.sleep(for: .milliseconds(500))

                let input = BatchInput(
                    totalRecords: 12,
                    windowSize: 4,
                    partitions: 2,
                    pageSize: 4
                )
                print("Processing \(input.totalRecords) records\n")

                let handle = try await client.startWorkflow(BatchWorkflow.self, input: input)
                let output: BatchOutput = try await handle.result(timeout: .seconds(120))

                print(
                    """

                    Batch complete — processed \(output.processed) / \(input.totalRecords) records

                    Patterns demonstrated:
                      • context.signalExternalWorkflow — cross-workflow signal, no activity needed
                      • @WorkflowSignal handler updating mutable workflow state
                      • withThrowingTaskGroup bounded to windowSize concurrent children
                      • context.suggestContinueAsNew triggering continueAsNew between pages
                      • Pure activities (no StrandClient / PostgresClient inside containers)
                    """
                )
            } catch {
                print("❌  \(error)")
            }
        }

        let group = ServiceGroup(
            services: [postgres, strand],
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: logger
        )
        try await group.run()
    }
}
