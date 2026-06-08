import PostgresNIO
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct CalculateInvoiceActivity: Activity {
    struct Input: Codable, Sendable {
        let userID: Int
    }
    typealias Output = InvoiceData

    /// Postgres client for writing to `demo.billing_reviews` when manual review is required.
    let postgres: PostgresClient

    /// Invoices over $200 require manual billing review.
    static let manualReviewThresholdCents: Int = 20_000

    func run(input: Input, context: ActivityContext) async throws -> InvoiceData {
        try await Task.sleep(for: .milliseconds(Int64.random(in: 800...2_000)))
        let invoiceID = "INV-\(input.userID)-\(Int(Date().timeIntervalSince1970) % 100_000)"
        let rawAmount = Double.random(in: 49.99...499.99)
        let amount = (rawAmount * 100).rounded() / 100
        let requiresManualReview = Int(amount * 100) > Self.manualReviewThresholdCents
        context.logger.info(
            "Calculated invoice",
            metadata: [
                "invoiceID": .string(invoiceID),
                "amount": .stringConvertible(amount),
                "requiresManualReview": .stringConvertible(requiresManualReview),
            ]
        )

        if requiresManualReview {
            // Insert into the business table; BillingReviewService polls it.
            // ON CONFLICT is idempotent across activity retries.
            for try await _ in try await postgres.query(
                """
                INSERT INTO demo.billing_reviews (invoice_id, user_id, amount)
                VALUES (\(invoiceID), \(input.userID), \(amount))
                ON CONFLICT (invoice_id) DO NOTHING
                """,
                logger: context.logger
            ) {}
            context.logger.info(
                "Billing review requested",
                metadata: ["invoiceID": .string(invoiceID)]
            )
        }

        return InvoiceData(invoiceID: invoiceID, amount: amount, requiresManualReview: requiresManualReview)
    }
}
