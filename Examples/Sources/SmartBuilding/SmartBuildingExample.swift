import Logging
import PostgresNIO
import ServiceLifecycle
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Smart Building Monitor — Strand public IoT example
///
/// Demonstrates:
///   • Per-entity child workflows running in parallel (one `RoomMonitorWorkflow` per room)
///   • `context.sleep(for:)` between sensor polling cycles (durable — survives restarts)
///   • Signals to update workflow state in-flight (ops team raises the server-room
///     temperature ceiling after a thermal spike, mid-session)
///   • Activities that simulate realistic sensor variance across rooms
///   • Durability — kill the process mid-cycle and restart; each room monitor
///     resumes from its last completed cycle, not from the start
///
/// Run:
///   cd Examples && swift run SmartBuilding
///
/// Prerequisites:
///   • Postgres running at localhost:5499 (see docker-compose.yml at the repo root)
///   • Schema applied once: psql "postgresql://strand:strand@localhost:5499/strand_dev" -f ../strand.sql
@main struct SmartBuildingExample {
    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput(label:))
        let logger = Logger(label: "smart-building")
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
            queue: "iot-building",
            namespace: "iot-demo",
            options: StrandOptions(logger: logger)
        )

        let worker = StrandWorker(
            postgres: postgres,
            options: WorkerOptions(
                queue: "iot-building",
                namespace: "iot-demo",
                workflowConcurrency: 8,
                activityConcurrency: 16,
                pollInterval: .milliseconds(100)
            ),
            workflows: [
                BuildingMonitorWorkflow.self,
                RoomMonitorWorkflow.self,
            ],
            activities: [
                ReadSensorsActivity(),
                SendAlertActivity(),
            ],
            logger: logger
        )

        Task {
            do {
                try await Task.sleep(for: .milliseconds(500))

                let normalThresholds = RoomThresholds(
                    maxTemperatureCelsius: 28.0,
                    maxCO2PPM: 1_000.0,
                    minHumidityPercent: 30.0
                )
                let serverThresholds = RoomThresholds(
                    maxTemperatureCelsius: 40.0,  // servers run hot
                    maxCO2PPM: 800.0,
                    minHumidityPercent: 35.0
                )

                let input = BuildingInput(
                    buildingName: "Strand HQ",
                    rooms: [
                        RoomConfig(roomId: "lobby", displayName: "Lobby", thresholds: normalThresholds, cycles: 5),
                        RoomConfig(roomId: "open-office", displayName: "Open Office", thresholds: normalThresholds, cycles: 5),
                        RoomConfig(roomId: "server-room", displayName: "Server Room", thresholds: serverThresholds, cycles: 5),
                        RoomConfig(roomId: "conference-room", displayName: "Conference Room", thresholds: normalThresholds, cycles: 5),
                    ]
                )

                let handle = try await client.startWorkflow(
                    BuildingMonitorWorkflow.self,
                    input: input
                )

                // Ops team signal: after the server-room thermal spike on cycle 3,
                // raise the temperature ceiling to acknowledge the incident and
                // suppress further alerts while HVAC repair is in progress.
                //
                // We signal the parent BuildingMonitorWorkflow handle here because
                // child workflow handles are not directly accessible from the client
                // without an explicit idempotency key. In production you would obtain
                // the server-room child's handle via:
                //
                //   let roomHandle = try await client.workflow(
                //       id: "<taskID>:<seqNum>",
                //       as: RoomMonitorWorkflow.self)
                //   try await roomHandle.signal(RoomMonitorWorkflow.UpdateThresholds.self,
                //       payload: ThresholdUpdate(...))
                //
                // Here we use the untyped signal API so the parent can receive and
                // record the update in its own durable state. The signal name is
                // derived from the `WorkflowSignalDefinition` type name ("updatethresholds").
                Task {
                    // Cycle 3 starts around t=8 s (2 s sleep × 2 prior cycles + activity time).
                    // Wait until after the spike has been detected.
                    try await Task.sleep(for: .seconds(9))
                    print(
                        "\nOps team: raising server-room temp ceiling"
                            + " after spike investigation"
                    )
                    try await handle.signal(
                        name: RoomMonitorWorkflow.UpdateThresholds.signalName,
                        payload: ThresholdUpdate(
                            newThresholds: RoomThresholds(
                                maxTemperatureCelsius: 90.0,  // raised ceiling
                                maxCO2PPM: 800.0,
                                minHumidityPercent: 35.0
                            ),
                            reason: "post-incident: raised temp ceiling pending HVAC repair"
                        )
                    )
                }

                let report: BuildingReport = try await handle.result(timeout: .seconds(90))
                print("\nFinal: \(report.totalAlerts) total alert(s) across \(report.rooms.count) rooms")

                try await Task.sleep(for: .milliseconds(300))
            } catch {
                print("Error:", error)
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
