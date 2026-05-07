import PostgresNIO
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Calls a local Ollama instance to classify groundwater trend and generate
/// a 2-sentence narrative for one California county.
///
/// Uses `format: "json"` to get structured output instead of tool calling —
/// faster and more reliable for simple classification tasks.
struct OllamaTrendActivity: ActivityDefinition {
    typealias Input = OllamaTrendInput
    typealias Output = OllamaTrendOutput

    let postgres: PostgresClient

    func run(input: Input, context: ActivityContext) async throws -> Output {
        context.logger.info(
            "AI analysis for county: \(input.countyName)",
            metadata: ["county": .string(input.countyName)]
        )

        let prompt = buildPrompt(input)
        let result = try await callOllama(prompt: prompt, countyName: input.countyName, logger: context.logger)

        // Persist the AI result to county_stats
        try await postgres.query(
            """
            UPDATE cnra.county_stats
            SET trend           = \(result.trend),
                ai_narrative    = \(result.narrative),
                ai_analyzed_at  = NOW()
            WHERE county_name = \(input.countyName)
            """,
            logger: context.logger
        )

        context.logger.info(
            "AI result for \(input.countyName): \(result.trend)",
            metadata: ["county": .string(input.countyName)]
        )

        return result
    }

    // MARK: - Prompt construction

    private func buildPrompt(_ input: OllamaTrendInput) -> String {
        var lines: [String] = [
            "County: \(input.countyName), California",
            "Total groundwater measurements: \(input.measurementCount)",
        ]
        if let avg = input.avgDepthFt {
            lines.append("Average depth to groundwater: \(String(format: "%.1f", avg)) feet")
        }
        if let mn = input.minDepthFt {
            lines.append("Shallowest recorded depth: \(String(format: "%.1f", mn)) feet")
        }
        if let mx = input.maxDepthFt {
            lines.append("Deepest recorded depth: \(String(format: "%.1f", mx)) feet")
        }
        if let dt = input.trendDeltaFt {
            let dir =
                dt > 0 ? "deeper (declining)" : dt < 0 ? "shallower (recovering)" : "unchanged"
            lines.append(
                "5-year trend: water table \(String(format: "%.2f", abs(dt))) ft \(dir) vs prior 5 years"
            )
        }
        if let e = input.earliestMsmt {
            lines.append("Data spans: \(e) to \(input.latestMsmt ?? "present")")
        }

        return """
            You are a California hydrologist analyzing groundwater level data.

            Data for \(input.countyName) County:
            \(lines.joined(separator: "\n"))

            Task: Based on this data, respond with a JSON object containing:
            1. "trend": exactly one of "DECLINING" (water table dropping), "STABLE" (minimal change), or "RECOVERING" (water table rising). Use "UNKNOWN" only if there is genuinely insufficient trend data.
            2. "narrative": exactly 2 sentences describing the groundwater situation for a non-technical audience.

            Respond with only the JSON object, no other text.
            """
    }
}

// MARK: - Ollama HTTP client (non-streaming, format:json)

private func callOllama(
    prompt: String,
    countyName: String,
    logger: Logger
) async throws -> OllamaTrendOutput {
    struct OllamaRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
        let format: String
    }
    struct OllamaResponse: Decodable {
        let response: String
    }
    struct TrendJSON: Decodable {
        let trend: String
        let narrative: String
    }

    let url = URL(string: "\(CNRA.ollamaURL)/api/generate")!
    var req = URLRequest(url: url, timeoutInterval: 120)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONEncoder().encode(
        OllamaRequest(
            model: CNRA.ollamaModel,
            prompt: prompt,
            stream: false,
            format: "json"
        )
    )

    let (data, response) = try await URLSession.shared.data(for: req)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw OllamaError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    let ollamaResp = try JSONDecoder().decode(OllamaResponse.self, from: data)

    // Parse the JSON that Ollama embedded in its response string
    guard let jsonData = ollamaResp.response.data(using: .utf8),
        let tj = try? JSONDecoder().decode(TrendJSON.self, from: jsonData)
    else {
        // Fallback: parse trend keyword from raw text
        let raw = ollamaResp.response.uppercased()
        let trend: String
        if raw.contains("DECLINING") {
            trend = "DECLINING"
        } else if raw.contains("RECOVERING") {
            trend = "RECOVERING"
        } else if raw.contains("STABLE") {
            trend = "STABLE"
        } else {
            trend = "UNKNOWN"
        }
        return OllamaTrendOutput(
            countyName: countyName,
            trend: trend,
            narrative: ollamaResp.response.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // Sanitise trend value
    let validTrends = Set(["DECLINING", "STABLE", "RECOVERING", "UNKNOWN"])
    let trend = validTrends.contains(tj.trend.uppercased()) ? tj.trend.uppercased() : "UNKNOWN"
    return OllamaTrendOutput(countyName: countyName, trend: trend, narrative: tj.narrative)
}

enum OllamaError: Error, CustomStringConvertible, LocalizedError {
    case httpError(Int)
    var description: String {
        switch self {
        case .httpError(let c): return "Ollama HTTP \(c)"
        }
    }
    var errorDescription: String? { description }
}
