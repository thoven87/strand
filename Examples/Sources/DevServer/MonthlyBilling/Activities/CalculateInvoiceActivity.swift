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

    func run(input: Input, context: ActivityContext) async throws -> InvoiceData {
        try await Task.sleep(for: .milliseconds(Int64.random(in: 800...2_000)))
        let invoiceID = "INV-\(input.userID)-\(Int(Date().timeIntervalSince1970) % 100_000)"
        let rawAmount = Double.random(in: 49.99...499.99)
        let amount = (rawAmount * 100).rounded() / 100
        context.logger.info(
            "Calculated invoice",
            metadata: [
                "invoiceID": .string(invoiceID),
                "amount": .stringConvertible(amount),
            ]
        )
        return InvoiceData(invoiceID: invoiceID, amount: amount)
    }
}
