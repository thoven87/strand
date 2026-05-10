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
