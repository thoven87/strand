import Foundation
import Strand

struct TrainingJobInput: Codable, Sendable {
    let jobName: String
    let partitions: [CountryPartitionInput]
}

struct CountryPartitionInput: Codable, Sendable {
    let country: String
    let partition: Int
    let variants: Int
}

struct CorpusData: Codable, Sendable {
    let country: String
    let partition: Int
    let rowCount: Int
}

struct CorpusAnalysis: Codable, Sendable {
    let country: String
    let variant: Int
    let analysisPath: String
}

struct VoiceModel: Codable, Sendable {
    let country: String
    let modelPath: String
}

struct CountryModelResult: Codable, Sendable {
    let country: String
    let modelPath: String
    let variantsAnalyzed: Int
}

struct PublishInput: Codable, Sendable {
    let jobName: String
    let modelPaths: [String]
}

struct PublishResult: Codable, Sendable {
    let registry: String
    let modelsPublished: Int
}

struct TrainingJobResult: Codable, Sendable {
    let jobName: String
    let modelsPublished: Int
    let countries: [String]
}
