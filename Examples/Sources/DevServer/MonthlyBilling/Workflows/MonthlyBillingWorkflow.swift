import Strand

/// Monthly billing pipeline with a manual-review gate.
///
/// ```
///  CalculateInvoice
///       ├─ requiresManualReview == false ──────────────────────────────┐
///       └─ requiresManualReview == true                                │
///              │  waitForEvent("billing_approved", timeout: 35 s)     │
///              ├─ signal received ──────────────────────────────────── ▼
///              └─ SLA timeout ───────────────────────────────── ChargeCreditCard
///                                                                  GeneratePDF
///                                                              ┌──────┴──────┐
///                                                          SendEmail    SendEmail
///                                                          (user)       (admin)
/// ```
struct MonthlyBillingWorkflow: Workflow {
    typealias Input = BillingInput
    typealias Output = BillingResult

    mutating func run(
        context: WorkflowContext<Self>,
        input: BillingInput
    ) async throws -> BillingResult {

        let invoice = try await context.runActivity(
            CalculateInvoiceActivity.self,
            input: .init(userID: input.userID),
            options: ActivityOptions(maxAttempts: 3)
        )

        // Approval gate: skip for low-value invoices; wait for signal or 35-second SLA.
        // The \.userID predicate routes each emission to exactly this workflow instance.
        if invoice.requiresManualReview {
            let approval = try await context.waitForEvent(
                BillingApprovedEvent.self,
                matching: \.userID == input.userID,
                timeout: .seconds(35)
            )
            if let approval {
                context.logger.info(
                    "billing approved",
                    metadata: [
                        "invoiceID": .string(invoice.invoiceID),
                        "reviewer": .string(approval.reviewer),
                    ]
                )
            } else {
                context.logger.info(
                    "billing review SLA elapsed — auto-approving",
                    metadata: ["invoiceID": .string(invoice.invoiceID)]
                )
            }
        }

        let charge = try await context.runActivity(
            ChargeCreditCardActivity.self,
            input: .init(invoiceID: invoice.invoiceID, amount: invoice.amount),
            options: ActivityOptions(maxAttempts: 3)
        )

        let pdfPath = try await context.runActivity(
            GeneratePDFActivity.self,
            input: .init(invoiceID: invoice.invoiceID, chargeID: charge.chargeID),
            options: ActivityOptions(maxAttempts: 3)
        )

        // Fan-out: user receipt (60 % transient failure rate) and admin notification in parallel.
        try await withThrowingTaskGroup(of: StrandVoid.self) { group in
            group.addTask {
                try await context.runActivity(
                    SendEmailActivity.self,
                    input: .init(
                        to: input.userEmail,
                        subject: "Your receipt for \(invoice.invoiceID)",
                        failureRate: 0.60
                    ),
                    options: ActivityOptions(
                        maxAttempts: 5,
                        retryStrategy: .backoff(initial: .milliseconds(300), multiplier: 2.0, cap: .seconds(4))
                    )
                )
            }
            group.addTask {
                try await context.runActivity(
                    SendEmailActivity.self,
                    input: .init(
                        to: input.adminEmail,
                        subject: "Billing notification: \(invoice.invoiceID)",
                        failureRate: 0.10
                    ),
                    options: ActivityOptions(maxAttempts: 3)
                )
            }
            try await group.waitForAll()
        }

        return BillingResult(
            invoiceID: invoice.invoiceID,
            chargeID: charge.chargeID,
            pdfPath: pdfPath
        )
    }
}
