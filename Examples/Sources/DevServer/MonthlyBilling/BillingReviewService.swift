import Foundation
import Logging
import PostgresNIO
import ServiceLifecycle
import Strand

/// Polls `demo.billing_reviews` every 2 seconds and processes pending reviews.
///
/// Approval decision is data-driven: invoices under the auto-approve threshold
/// are approved immediately; others are deferred so the workflow's 35-second
/// SLA fires instead.
struct BillingReviewService: Service {
    let postgres: PostgresClient
    let client: StrandClient
    let logger: Logger

    /// Invoices below this amount are auto-approved by the review bot.
    /// Those at or above are deferred to the 35-second SLA timeout.
    static let autoApproveThreshold: Double = 300.0

    func run() async throws {
        logger.info("[billing-reviewer] starting")
        defer { logger.info("[billing-reviewer] stopped") }

        while !Task.isShuttingDownGracefully && !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(2)) } catch { break }
            guard !Task.isShuttingDownGracefully else { break }

            do {
                let pending = try await pendingReviews()
                for review in pending {
                    if review.autoApprove {
                        try await approve(review)
                    } else {
                        try await defer_(review)
                    }
                }
            } catch {
                logger.warning("[billing-reviewer] poll error: \(error)")
            }
        }
    }

    // MARK: - Domain actions

    private func approve(_ review: PendingReview) async throws {
        _ = try await postgres.query(
            """
            UPDATE demo.billing_reviews
            SET    status = 'APPROVED', reviewer = 'billing_review_service', reviewed_at = NOW()
            WHERE  invoice_id = \(review.invoiceID) AND status = 'PENDING'
            """,
            logger: logger
        )
        try await client.emit(
            BillingApprovedEvent.self,
            payload: BillingApprovalPayload(
                userID: review.userID,
                approved: true,
                reviewer: "billing_review_service",
                ticketID: review.invoiceID
            )
        )
        logger.info(
            "[billing-reviewer] ✅  approved",
            metadata: [
                "invoiceID": .string(review.invoiceID),
                "amount": .stringConvertible(review.amount),
            ]
        )
    }

    private func defer_(_ review: PendingReview) async throws {
        _ = try await postgres.query(
            """
            UPDATE demo.billing_reviews
            SET    status = 'DEFERRED', reviewer = 'billing_review_service', reviewed_at = NOW()
            WHERE  invoice_id = \(review.invoiceID) AND status = 'PENDING'
            """,
            logger: logger
        )
        logger.info(
            "[billing-reviewer] ⏱  deferred — SLA timeout will fire",
            metadata: [
                "invoiceID": .string(review.invoiceID),
                "amount": .stringConvertible(review.amount),
            ]
        )
    }

    // MARK: - DB query

    private struct PendingReview {
        let invoiceID: String
        let userID: Int
        let amount: Double
        /// Derived from amount in the query
        let autoApprove: Bool
    }

    private func pendingReviews() async throws -> [PendingReview] {
        let threshold = Self.autoApproveThreshold
        let stream = try await postgres.query(
            """
            SELECT invoice_id, user_id, amount,
                   amount < \(threshold) AS auto_approve
            FROM   demo.billing_reviews
            WHERE  status = 'PENDING'
            ORDER  BY created_at
            """,
            logger: logger
        )
        var reviews: [PendingReview] = []
        for try await row in stream {
            var col = row.makeIterator()
            let invoiceID = try col.next()!.decode(String.self, context: .default)
            let userID = try col.next()!.decode(Int.self, context: .default)
            let amount = try col.next()!.decode(Double.self, context: .default)
            let autoApprove = try col.next()!.decode(Bool.self, context: .default)
            reviews.append(PendingReview(invoiceID: invoiceID, userID: userID, amount: amount, autoApprove: autoApprove))
        }
        return reviews
    }
}
