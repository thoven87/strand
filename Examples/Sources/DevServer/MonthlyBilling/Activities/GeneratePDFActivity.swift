import Strand

struct GeneratePDFActivity: Activity {
    struct Input: Codable, Sendable {
        let invoiceID: String
        let chargeID: String
    }
    typealias Output = String

    func run(input: Input, context: ActivityContext) async throws -> String {
        try await Task.sleep(for: .milliseconds(Int64.random(in: 600...1_500)))
        let pdfPath = "/receipts/\(input.invoiceID)/receipt.pdf"
        context.logger.info(
            "Generated PDF receipt",
            metadata: [
                "pdfPath": .string(pdfPath),
                "invoiceID": .string(input.invoiceID),
            ]
        )
        return pdfPath
    }
}
