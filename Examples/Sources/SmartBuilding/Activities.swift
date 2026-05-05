import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct ReadSensorsInput: Codable, Sendable {
    let roomId: String
    let displayName: String
    let cycle: Int
}

/// Simulates reading all sensors in a room.
/// The server room (roomId == "server-room") has a temperature spike on cycle 3.
struct ReadSensorsActivity: ActivityDefinition {
    typealias Input = ReadSensorsInput
    typealias Output = [SensorReading]
    static let name = "iot.read-sensors"

    func run(input: Input, context: ActivityContext) async throws -> Output {
        // Simulate sensor polling latency
        try await Task.sleep(for: .milliseconds(400))

        let c = Double(input.cycle)

        // Temperature: server room runs hot; spikes on cycle 3
        let baseTemp: Double = input.roomId == "server-room" ? 34.0 : 21.0
        let temp: Double
        if input.roomId == "server-room" && input.cycle == 3 {
            temp = 87.0  // 🔥 thermal incident
        } else {
            temp = baseTemp + sin(c * 0.8) * 1.5
        }

        // CO2: conference room fills up with people
        let baseCO2: Double = input.roomId == "conference-room" ? 780.0 : 410.0
        let co2 = baseCO2 + c * 18.0 + sin(c * 0.4) * 20.0

        // Humidity: mild variance across rooms
        let humidity = 44.0 + sin(c * 0.6 + Double(input.roomId.count)) * 4.0

        return [
            SensorReading(sensorType: .temperature, value: temp, unit: "°C"),
            SensorReading(sensorType: .co2, value: co2, unit: "ppm"),
            SensorReading(sensorType: .humidity, value: humidity, unit: "%"),
        ]
    }
}

struct AlertInput: Codable, Sendable {
    let roomId: String
    let displayName: String
    let sensor: SensorType
    let value: Double
    let threshold: Double
    let cycle: Int
}

/// Handles a sensor threshold breach — in production this would page on-call,
/// trigger HVAC adjustments, etc. Here it logs the alert clearly.
struct SendAlertActivity: ActivityDefinition {
    typealias Input = AlertInput
    typealias Output = String  // alert description
    static let name = "iot.send-alert"

    func run(input: Input, context: ActivityContext) async throws -> Output {
        try await Task.sleep(for: .milliseconds(200))
        let unit = input.sensor == .temperature ? "°C" : input.sensor == .co2 ? " ppm" : "%"
        let desc =
            "[\(input.displayName)] \(input.sensor.rawValue.uppercased()) "
            + "\(String(format: "%.1f", input.value))\(unit) "
            + "exceeds threshold \(String(format: "%.0f", input.threshold)) (cycle \(input.cycle))"
        print("  ALERT: \(desc)")
        return desc
    }
}
