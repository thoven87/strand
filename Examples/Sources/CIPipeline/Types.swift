#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Input for the CI pipeline — identifies the repo and commit.
struct PipelineInput: Codable, Sendable {
    let repo: String  // e.g. "thoven87/strand"
    let branch: String  // e.g. "main"
    let sha: String  // short commit SHA, e.g. "a3f8e2c"
}

/// Result of a single pipeline stage.
struct StageResult: Codable, Sendable {
    let name: String
    let passed: Bool
    let durationMs: Int
    let summary: String
}

/// Final output of the whole pipeline.
struct PipelineOutput: Codable, Sendable {
    let repo: String
    let sha: String
    let stages: [StageResult]
    let deployed: Bool
}

/// Payload carried by the "approve" signal.
struct ApprovalDecision: Codable, Sendable {
    let approved: Bool
    let approver: String  // e.g. "ci-bot" or a GitHub username
}

/// Thrown by activities that simulate stage failures.
struct StageFailure: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { description = msg }
}
