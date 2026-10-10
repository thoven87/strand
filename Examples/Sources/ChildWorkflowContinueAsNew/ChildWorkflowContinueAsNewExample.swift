import Logging
import PostgresNIO
import ServiceLifecycle
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Child Workflow Continue-As-New — Strand public example
///
/// Demonstrates that when a child workflow calls `continueAsNew` the parent
/// is not notified of intermediate runs — it receives a single completion
/// signal only when the full chain finishes.
///
/// What you will see:
///   1. The parent workflow starts and spawns one child.
///   2. The child calls `continueAsNew` four times (runs 1–4).
///   3. On the fifth run the child returns a result.
///   4. The parent wakes once, logs the result, and completes.
///
/// In the Loom dashboard you can watch the child chain live:
///   • The parent task stays RUNNING / WAITING throughout.
///   • The child task shows CONTINUED_AS_NEW four times, then COMPLETED.
///   • The parent's Chain tab links all five child runs.
///
///
/// Run:
///   cd Examples && swift run ChildWorkflowContinueAsNew
///
/// Prerequisites:
///   • Postgres running at localhost:5499 (see docker-compose.yml in the root)
///   • strand.sql applied once:
///       psql "postgresql://strand:strand@localhost:5499/strand_dev" -f ../strand.sql
@main struct ChildWorkflowContinueAsNewExample {
    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput(label:))
        let logger = Logger(label: "cw-cas")

        print(
            """
            ╔══════════════════════════════════════════════════════╗
            ║      Child Workflow — Continue As New Example        ║
            ╠══════════════════════════════════════════════════════╣
            ║  Parent spawns one child.                            ║
            ║  Child calls continueAsNew 4 times (runs 1–4).       ║
            ║  Parent wakes exactly once when run 5 completes.     ║
            ╚══════════════════════════════════════════════════════╝
            """
        )

        // ── Postgres ────────────────────────────────────────────────────────
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

        // ── Worker ──────────────────────────────────────────────────────────
        let strand = StrandService(
            postgres: postgres,
            options: .init(
                queues: [
                    .init(
                        name: "cw-cas",
                        namespace: "cw-cas-demo",
                        workflows: [
                            ParentWorkflow.self,
                            ChildWorkflow.self,
                        ],
                        workflowConcurrency: 4,
                        activityConcurrency: 4,
                        pollInterval: .milliseconds(100)
                    )
                ],
                logger: logger
            )
        )

        // ── Trigger ─────────────────────────────────────────────────────────
        Task {
            do {
                // Give the worker a moment to register before enqueueing.
                try await Task.sleep(for: .milliseconds(400))

                let client = strand.client(queue: "cw-cas", namespace: "cw-cas-demo")

                print("Starting parent workflow (child will run 5 times via continueAsNew)\n")

                let handle = try await client.startWorkflow(
                    ParentWorkflow.self,
                    input: ParentInput(totalRuns: 5)
                )

                print("    Parent task ID : \(handle.taskID)")
                print("    Watch in Loom  : http://localhost:5173\n")

                // Wait for the parent — it unblocks only when the entire
                // child chain has completed.
                let result = try await handle.result(timeout: .seconds(30))

                print(
                    """

                    - Parent received result:
                        "\(result)"

                        The parent was re-activated exactly once.
                        The child's 4 intermediate continueAsNew hops
                        were invisible to the parent.
                    """
                )

            } catch {
                print("❌  Error: \(error)")
            }
        }

        // ── Run until interrupted ───────────────────────────────────────────
        let group = ServiceGroup(
            services: [postgres, strand],
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: logger
        )
        try await group.run()
    }
}
