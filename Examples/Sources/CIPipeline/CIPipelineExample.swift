import Logging
import PostgresNIO
import ServiceLifecycle
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// CI/CD Pipeline — Strand public example
///
/// Demonstrates:
///   • Parallel activity fan-out (lint + tests + security run simultaneously)
///   • Automatic retry     (unit tests fail on attempt 1, pass on attempt 2)
///   • Signal-based approval gate (deployment waits for an explicit signal)
///   • Durability          (kill the process at any stage; restart resumes from there)
///
/// Run:
///   cd Examples && swift run CIPipeline
///
/// Prerequisites:
///   • Postgres running at localhost:5499 (see docker-compose.yml)
///   • strand.sql applied once: psql "postgresql://strand:strand@localhost:5499/strand_dev" -f ../strand.sql
@main struct CIPipelineExample {
    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput(label:))
        let logger = Logger(label: "ci-pipeline")
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

        let client = StrandClient(
            postgres: postgres,
            queue: "ci-pipeline",
            namespace: "ci-pipeline-demo",
            options: StrandOptions(logger: logger)
        )

        let worker = StrandWorker(
            postgres: postgres,
            options: WorkerOptions(
                queue: "ci-pipeline",
                namespace: "ci-pipeline-demo",
                workflowConcurrency: 4,
                activityConcurrency: 8,
                pollInterval: .milliseconds(100)
            ),
            workflows: [CIPipelineWorkflow.self],
            activities: [
                CheckoutActivity(),
                LintActivity(),
                UnitTestActivity(),
                SecurityScanActivity(),
                BuildActivity(),
                DeployActivity(),
            ],
            logger: logger
        )

        Task {
            do {
                try await Task.sleep(for: .milliseconds(500))

                let input = PipelineInput(
                    repo: "thoven87/strand",
                    branch: "main",
                    sha: "a3f8e2c"
                )

                print(
                    """
                    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    CI Pipeline: \(input.repo)@\(input.sha)
                        Branch: \(input.branch)
                    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    """
                )

                let handle = try await client.startWorkflow(
                    CIPipelineWorkflow.self,
                    input: input
                )

                // Simulate a CI bot approving the deployment automatically
                // after enough time for all pipeline stages to complete.
                //
                // In production this would be a human reviewing the build
                // artifacts and sending the signal via the Loom dashboard or
                // their own tooling:
                //
                //   let handle = client.workflowHandle(id: taskID)
                //   try await handle.signal(CIPipelineWorkflow.Approve.self,
                //                           payload: ApprovalDecision(approved: true, approver: "alice"))
                Task {
                    // Wait long enough for checkout + parallel gates + build
                    // (roughly 4 s checkout/lint/security + 6 s tests-with-retry + 4 s build = ~14 s)
                    try await Task.sleep(for: .seconds(18))
                    print("\nCI bot: all stages passed — auto-approving deployment")
                    try await handle.signal(
                        CIPipelineWorkflow.Approve.self,
                        payload: ApprovalDecision(approved: true, approver: "strand-bot")
                    )
                }

                let result: PipelineOutput = try await handle.result(timeout: .seconds(60))

                if result.deployed {
                    print("\(result.sha) is live on production")
                } else {
                    print("Pipeline finished without deploying")
                }

                // Let the final log lines flush before shutdown.
                try await Task.sleep(for: .milliseconds(200))
                try await client.cancelTask(id: handle.taskID)  // clean up
            } catch {
                print("Pipeline error:", error)
            }
        }

        let group = ServiceGroup(
            configuration: .init(
                services: [
                    .init(service: postgres),
                    .init(service: worker),
                ],
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: logger
            )
        )
        try await group.run()
    }
}
