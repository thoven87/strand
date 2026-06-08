import Foundation
import Strand

struct BillingInput: Codable, Sendable {
    let userID: Int
    let userEmail: String
    let adminEmail: String
}

struct InvoiceData: Codable, Sendable {
    let invoiceID: String
    let amount: Double
    /// True when the invoice exceeds the auto-approval threshold and a human must sign off.
    let requiresManualReview: Bool
}

struct ChargeData: Codable, Sendable {
    let chargeID: String
    let invoiceID: String
}

struct BillingResult: Codable, Sendable {
    let invoiceID: String
    let chargeID: String
    let pdfPath: String
}

/// Payload for the `billing_approved` event emitted by `BillingReviewService`.
struct BillingApprovalPayload: Codable, Sendable {
    /// Instance-scoping key — the `matching: \.userID == input.userID` predicate
    /// routes each emission to exactly the workflow waiting for this account.
    let userID: Int
    let approved: Bool
    let reviewer: String
    let ticketID: String?
}

/// Typed event definition for the billing approval gate.
/// Wire name `"billing_approved"` is shared by workflow (`waitForEvent`) and
/// emitter (`client.emit`).
struct BillingApprovedEvent: WorkflowEvent {
    typealias Payload = BillingApprovalPayload
    static let name = "billing_approved"
}
