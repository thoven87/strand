import Strand

struct ChargeCreditCardActivity: ActivityDefinition {
    struct Input: Codable, Sendable {
        let invoiceID: String
        let amount: Double
    }
    typealias Output = ChargeData

    func run(input: Input, context: ActivityContext) async throws -> ChargeData {
        try await Task.sleep(for: .milliseconds(Int64.random(in: 400...1_000)))
        let chargeID = "ch_\(String(input.invoiceID.suffix(6)).lowercased())"
        context.logger.info(
            "Charged credit card",
            metadata: [
                "chargeID": .string(chargeID),
                "invoiceID": .string(input.invoiceID),
                "amount": .stringConvertible(input.amount),
            ]
        )
        return ChargeData(chargeID: chargeID, invoiceID: input.invoiceID)
    }
}
