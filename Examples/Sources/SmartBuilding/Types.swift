#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum SensorType: String, Codable, Sendable {
    case temperature  // °C
    case co2  // ppm
    case humidity  // %
}

struct SensorReading: Codable, Sendable {
    let sensorType: SensorType
    let value: Double
    let unit: String
}

struct RoomThresholds: Codable, Sendable {
    let maxTemperatureCelsius: Double
    let maxCO2PPM: Double
    let minHumidityPercent: Double
}

struct RoomConfig: Codable, Sendable {
    let roomId: String
    let displayName: String
    let thresholds: RoomThresholds
    let cycles: Int  // how many monitoring cycles to run
}

struct CycleResult: Codable, Sendable {
    let cycle: Int
    let readings: [SensorReading]
    let alerts: [String]  // descriptions of any threshold breaches
}

struct RoomReport: Codable, Sendable {
    let roomId: String
    let displayName: String
    let cyclesCompleted: Int
    let totalAlerts: Int
}

struct BuildingReport: Codable, Sendable {
    let rooms: [RoomReport]
    let totalAlerts: Int
}

struct BuildingInput: Codable, Sendable {
    let buildingName: String
    let rooms: [RoomConfig]
}

struct ThresholdUpdate: Codable, Sendable {
    let newThresholds: RoomThresholds
    let reason: String
}
