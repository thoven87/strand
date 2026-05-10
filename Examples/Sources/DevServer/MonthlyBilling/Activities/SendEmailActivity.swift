import Strand

struct SendEmailActivity: ActivityDefinition {
    struct Input: Codable, Sendable {
        let to: String
        let subject: String
        let failureRate: Double
    }
    typealias Output = StrandVoid

    func run(input: Input, context: ActivityContext) async throws -> StrandVoid {
        try await Task.sleep(for: .milliseconds(Int64.random(in: 200...700)))

        if context.attempt <= 2 && Double.random(in: 0..<1) < input.failureRate {
            throw RateLimitError()
        }

        context.logger.info(
            "Sent email",
            metadata: [
                "to": .string(input.to),
                "subject": .string(input.subject),
                "attempt": .stringConvertible(context.attempt),
            ]
        )
        return StrandVoid()
    }
}

struct RateLimitError: Error, CustomStringConvertible {
    var description: String { "email send error: rate limit exceeded" }
}
