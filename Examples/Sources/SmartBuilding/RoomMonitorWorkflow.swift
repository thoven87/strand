import NIOCore
import Strand

/// Monitors a single room for N cycles.
///
/// Each cycle:
///   1. Read all sensors (activity)
///   2. Compare against thresholds
///   3. Fire an alert activity for each breach
///   4. Sleep before the next cycle
///
/// Durability: kill the process during any cycle and restart —
/// the workflow resumes from the last completed cycle, not from the start.
/// Thresholds can be updated in-flight via the `UpdateThresholds` signal.
struct RoomMonitorWorkflow: Workflow {
    typealias Input = RoomConfig
    typealias Output = RoomReport

    // ── Mutable state ─────────────────────────────────────────────────────
    var thresholds: RoomThresholds? = nil  // nil = use input thresholds

    // ── Signal: update thresholds without restarting the workflow ─────────

    /// Sent by ops to raise or lower a room's sensor thresholds in-flight,
    /// without cancelling the monitoring session or losing cycle history.
    ///
    /// ```swift
    /// try await roomHandle.signal(
    ///     RoomMonitorWorkflow.UpdateThresholds.self,
    ///     payload: ThresholdUpdate(newThresholds: adjusted, reason: "post-incident"))
    /// ```
    struct UpdateThresholds: WorkflowSignalDefinition {
        typealias W = RoomMonitorWorkflow
        typealias Input = ThresholdUpdate
        static func apply(to w: inout RoomMonitorWorkflow, input: ThresholdUpdate) {
            w.thresholds = input.newThresholds
            print("  Thresholds updated: \(input.reason)")
        }
    }

    mutating func handleSignal(name: String, payload: ByteBuffer?) throws {
        if name == UpdateThresholds.signalName,
            let update = try? decodeSignalPayload(ThresholdUpdate.self, from: payload)
        {
            UpdateThresholds.apply(to: &self, input: update)
        }
    }

    // ── Orchestration ──────────────────────────────────────────────────────

    mutating func run(
        context: WorkflowContext<Self>,
        input: RoomConfig
    ) async throws -> RoomReport {

        var totalAlerts = 0

        print("  [\(input.displayName)] monitoring started (\(input.cycles) cycles)")

        for cycle in 1...input.cycles {
            // Read all sensors for this room and cycle
            let readings = try await context.runActivity(
                ReadSensorsActivity.self,
                input: ReadSensorsInput(
                    roomId: input.roomId,
                    displayName: input.displayName,
                    cycle: cycle
                )
            )

            // Use signal-updated thresholds when available, otherwise use room config
            let limits = thresholds ?? input.thresholds

            // Format a one-line status line
            let tempReading = readings.first { $0.sensorType == .temperature }
            let co2Reading = readings.first { $0.sensorType == .co2 }
            let humidReading = readings.first { $0.sensorType == .humidity }

            let tempStr = tempReading.map { String(format: "%.1f°C", $0.value) } ?? "—"
            let co2Str = co2Reading.map { String(format: "%.0fppm", $0.value) } ?? "—"
            let humidStr = humidReading.map { String(format: "%.0f%%", $0.value) } ?? "—"

            print(
                "  [\(input.displayName)] cycle \(cycle)/\(input.cycles)"
                    + " — temp:\(tempStr) co2:\(co2Str) humidity:\(humidStr)"
            )

            // Check thresholds and fire an alert activity for each breach
            for reading in readings {
                let (breached, threshold): (Bool, Double) =
                    switch reading.sensorType {
                    case .temperature: (reading.value > limits.maxTemperatureCelsius, limits.maxTemperatureCelsius)
                    case .co2: (reading.value > limits.maxCO2PPM, limits.maxCO2PPM)
                    case .humidity: (reading.value < limits.minHumidityPercent, limits.minHumidityPercent)
                    }

                if breached {
                    _ = try await context.runActivity(
                        SendAlertActivity.self,
                        input: AlertInput(
                            roomId: input.roomId,
                            displayName: input.displayName,
                            sensor: reading.sensorType,
                            value: reading.value,
                            threshold: threshold,
                            cycle: cycle
                        )
                    )
                    totalAlerts += 1
                }
            }

            // Sleep between cycles (skip after the last one)
            if cycle < input.cycles {
                try await context.sleep(for: .seconds(2))
            }
        }

        let icon = totalAlerts == 0 ? "✅" : "⚠️"
        print("  \(icon)  [\(input.displayName)] monitoring complete — \(totalAlerts) alert(s)")

        return RoomReport(
            roomId: input.roomId,
            displayName: input.displayName,
            cyclesCompleted: input.cycles,
            totalAlerts: totalAlerts
        )
    }
}
