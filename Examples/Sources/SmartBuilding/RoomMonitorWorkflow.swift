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
@Workflow
struct RoomMonitorWorkflow {

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
    @WorkflowSignal
    mutating func updateThresholds(_ update: ThresholdUpdate) {
        thresholds = update.newThresholds
        print("  Thresholds updated: \(update.reason)")
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
                BuildingActivities.ReadSensors.self,
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
                    try await context.runActivity(
                        BuildingActivities.SendAlert.self,
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
