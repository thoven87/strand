import Strand

/// Simulates a monthly billing pipeline:
///
/// 1. CalculateInvoice — compute the invoice amount
/// 2. ChargeCreditCard — process the payment
/// 3. GeneratePDF      — produce a PDF receipt
/// 4. SendEmail (fan-out) — notify the user (60 % transient fail rate) and
///    admin (10 % transient fail rate) in parallel
struct MonthlyBillingWorkflow: Workflow {
    typealias Input = BillingInput
    typealias Output = BillingResult

    mutating func run(
        context: WorkflowContext<Self>,
        input: BillingInput
    ) async throws -> BillingResult {
        // Step 1 — calculate invoice
        let invoice = try await context.runActivity(
            CalculateInvoiceActivity.self,
            input: .init(userID: input.userID),
            options: ActivityOptions(maxAttempts: 3)
        )

        // Step 2 — charge card
        let charge = try await context.runActivity(
            ChargeCreditCardActivity.self,
            input: .init(invoiceID: invoice.invoiceID, amount: invoice.amount),
            options: ActivityOptions(maxAttempts: 3)
        )

        // Step 3 — generate PDF
        let pdfPath = try await context.runActivity(
            GeneratePDFActivity.self,
            input: .init(invoiceID: invoice.invoiceID, chargeID: charge.chargeID),
            options: ActivityOptions(maxAttempts: 3)
        )

        // Step 4 — fan-out: send emails in parallel
        try await withThrowingTaskGroup(of: StrandVoid.self) { group in
            // User email — high failure rate (60 %) to show retries in the dashboard
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
                        retryStrategy: .backoff(
                            initial: .milliseconds(300),
                            multiplier: 2.0,
                            cap: .seconds(4)
                        )
                    )
                )
            }
            // Admin notification — low failure rate (10 %)
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
