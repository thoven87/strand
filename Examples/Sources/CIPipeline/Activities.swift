import Logging
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// ── Stage 1: Checkout ──────────────────────────────────────────────────────

struct CheckoutActivity: ActivityDefinition {
    typealias Input = PipelineInput
    typealias Output = StageResult
    static let name = "ci.checkout"

    func run(input: PipelineInput, context: ActivityContext) async throws -> StageResult {
        print("  Fetching \(input.repo) (branch: \(input.branch))")
        try await Task.sleep(for: .milliseconds(900))
        print("  ✅  9 files, 12,847 lines checked out")
        return StageResult(
            name: "Checkout",
            passed: true,
            durationMs: 900,
            summary: "Cloned \(input.repo)@\(input.sha)"
        )
    }
}

// ── Stage 2a: Lint ─────────────────────────────────────────────────────────

struct LintActivity: ActivityDefinition {
    typealias Input = PipelineInput
    typealias Output = StageResult
    static let name = "ci.lint"

    func run(input: PipelineInput, context: ActivityContext) async throws -> StageResult {
        print("  Running swift-format lint...")
        try await Task.sleep(for: .seconds(2))
        print("  ✅  Lint: 0 errors, 0 warnings")
        return StageResult(
            name: "Lint",
            passed: true,
            durationMs: 2_000,
            summary: "0 issues"
        )
    }
}

// ── Stage 2b: Unit tests (fails on attempt 1 → retries → passes) ───────────
//
// Demonstrates Strand's automatic retry: the first attempt throws, the worker
// retries after 2 s, and the second attempt succeeds. The workflow never
// sees the failure — it just waits for the activity to eventually succeed.
// Kill the process during the retry window and restart: Strand will resume
// from exactly this stage.

struct UnitTestActivity: ActivityDefinition {
    typealias Input = PipelineInput
    typealias Output = StageResult
    static let name = "ci.unit-tests"

    // Allow up to 3 total attempts (1 failure + 1 retry = demonstration complete).
    static var defaultMaxAttempts: Int? { 3 }

    func run(input: PipelineInput, context: ActivityContext) async throws -> StageResult {
        print("  swift test (attempt \(context.attempt))...")
        try await Task.sleep(for: .seconds(3))
        if context.attempt == 1 {
            print("  ❌  2 failures: testResumeAfterCrash, testSignalDelivery")
            throw StageFailure("2 unit test failures on attempt 1 — will retry")
        }
        print("  ✅  247 passed, 0 failed, 0 skipped")
        return StageResult(
            name: "Tests",
            passed: true,
            durationMs: 3_000,
            summary: "247 passed (auto-retried once)"
        )
    }
}

// ── Stage 2c: Security scan ────────────────────────────────────────────────

struct SecurityScanActivity: ActivityDefinition {
    typealias Input = PipelineInput
    typealias Output = StageResult
    static let name = "ci.security-scan"

    func run(input: PipelineInput, context: ActivityContext) async throws -> StageResult {
        print("  Scanning dependencies for CVEs...")
        try await Task.sleep(for: .milliseconds(2_500))
        print("  ✅  No known vulnerabilities in 23 dependencies")
        return StageResult(
            name: "Security",
            passed: true,
            durationMs: 2_500,
            summary: "0 CVEs, 23 deps scanned"
        )
    }
}

// ── Stage 3: Build ─────────────────────────────────────────────────────────

struct BuildActivity: ActivityDefinition {
    typealias Input = PipelineInput
    typealias Output = StageResult
    static let name = "ci.build"

    func run(input: PipelineInput, context: ActivityContext) async throws -> StageResult {
        print("  swift build -c release")
        try await Task.sleep(for: .seconds(4))
        print("  ✅  Artifact: strand-server (18.4 MB)")
        return StageResult(
            name: "Build",
            passed: true,
            durationMs: 4_000,
            summary: "strand-server 18.4 MB"
        )
    }
}

// ── Stage 5: Deploy ────────────────────────────────────────────────────────

struct DeployActivity: ActivityDefinition {
    typealias Input = PipelineInput
    typealias Output = StageResult
    static let name = "ci.deploy"

    func run(input: PipelineInput, context: ActivityContext) async throws -> StageResult {
        for i in 1...3 {
            print("  Rolling update: \(i)/3 instances...")
            try await Task.sleep(for: .milliseconds(600))
        }
        print("  ✅  All 3 instances healthy")
        return StageResult(
            name: "Deploy",
            passed: true,
            durationMs: 1_800,
            summary: "3/3 instances updated"
        )
    }
}
