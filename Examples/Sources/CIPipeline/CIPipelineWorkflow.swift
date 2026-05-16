import Strand

/// Durable CI/CD pipeline workflow.
///
/// Stages (in order):
///   1. Checkout          — clone the repo
///   2. Quality gates     — lint + unit tests + security scan (parallel)
///   3. Build             — compile release artifact
///   4. Approval gate     — wait for a human (or bot) to send the "approve" signal
///   5. Deploy            — rolling update across instances
///
/// **Durability demo:** kill the process at any point and restart — the
/// workflow resumes from the last completed stage. Try killing during the
/// Build stage; on restart it will re-run Build and continue to Approval.
@Workflow
struct CIPipelineWorkflow {
    typealias Input = PipelineInput
    typealias Output = PipelineOutput

    // ── Mutable state ────────────────────────────────────────────────────────

    var approvalDecision: ApprovalDecision? = nil

    // ── Signals ──────────────────────────────────────────────────────────────

    /// Approve or reject the deployment.
    ///
    /// ```swift
    /// try await handle.signal(CIPipelineWorkflow.Approve.self,
    ///                         payload: ApprovalDecision(approved: true, approver: "alice"))
    /// ```
    ///
    /// `@Workflow` synthesises the `Approve` nested struct and the
    /// `handleSignal` dispatcher — no boilerplate needed.
    @WorkflowSignal
    mutating func approve(_ decision: ApprovalDecision) {
        approvalDecision = decision
        let verdict = decision.approved ? "✅  approved" : "❌  rejected"
        print("  Signal received: \(verdict) by \(decision.approver)")
    }

    // ── Orchestration ─────────────────────────────────────────────────────────

    mutating func run(
        context: WorkflowContext<Self>,
        input: PipelineInput
    ) async throws -> PipelineOutput {

        var stages: [StageResult] = []

        // ── Stage 1: Checkout ──────────────────────────────────────────────
        print("\n[ 1/5 ] Checkout")
        let checkout = try await context.runActivity(CheckoutActivity.self, input: input)
        stages.append(checkout)

        // ── Stage 2: Quality gates (parallel) ─────────────────────────────
        // All three run concurrently. Strand releases the worker slot between
        // activations, so parallel activities genuinely overlap.
        print("\n[ 2/5 ] Quality Gates  (parallel — all three run simultaneously)")
        async let lintFuture = context.runActivity(LintActivity.self, input: input)
        async let testsFuture = context.runActivity(
            UnitTestActivity.self,
            input: input,
            // Constant 2-second backoff between the two attempts.
            options: ActivityOptions(retryStrategy: .constant(.seconds(2)))
        )
        async let securityFuture = context.runActivity(SecurityScanActivity.self, input: input)
        let (lint, tests, security) = try await (lintFuture, testsFuture, securityFuture)
        stages += [lint, tests, security]

        guard lint.passed, tests.passed, security.passed else {
            print("\n❌  Quality gates failed — pipeline blocked")
            return PipelineOutput(
                repo: input.repo,
                sha: input.sha,
                stages: stages,
                deployed: false
            )
        }
        print("  ✅  All quality gates passed")

        // ── Stage 3: Build ─────────────────────────────────────────────────
        print("\n[ 3/5 ] Build")
        let build = try await context.runActivity(BuildActivity.self, input: input)
        stages.append(build)

        // ── Stage 4: Approval gate ─────────────────────────────────────────
        print(
            """

            [ 4/5 ] Deployment Approval
              ⏳  Waiting for approval signal (timeout: 24 h)

              In production, send:
                try await handle.signal(CIPipelineWorkflow.Approve.self,
                                        payload: ApprovalDecision(approved: true, approver: "alice"))
              Or use the Loom dashboard → task detail → Send Signal.

              This workflow is durable: stop and restart the process right now —
              it will resume here, still waiting for the approval signal.
            """
        )

        // Suspend until the Approve signal arrives (or 24 h elapses).
        try await context.condition({ $0.approvalDecision != nil }, timeout: .hours(24))

        guard let decision = approvalDecision, decision.approved else {
            print("  Deployment rejected — pipeline stopped")
            return PipelineOutput(
                repo: input.repo,
                sha: input.sha,
                stages: stages,
                deployed: false
            )
        }

        // ── Stage 5: Deploy ────────────────────────────────────────────────
        print("\n[ 5/5 ] Deploy")
        let deploy = try await context.runActivity(DeployActivity.self, input: input)
        stages.append(deploy)

        // ── Summary ────────────────────────────────────────────────────────
        let passed = stages.filter(\.passed).count
        print(
            """

            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            ✅  Pipeline complete

              Repo:     \(input.repo)
              Branch:   \(input.branch)
              SHA:      \(input.sha)
              Stages:   \(passed)/\(stages.count) passed
              Approved: \(decision.approver)
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            """
        )

        return PipelineOutput(
            repo: input.repo,
            sha: input.sha,
            stages: stages,
            deployed: true
        )
    }
}
