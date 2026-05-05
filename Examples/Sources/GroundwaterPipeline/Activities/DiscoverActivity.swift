import PostgresNIO
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Queries the CKAN datastore API to get the exact row count without downloading
/// any data, then creates the pipeline_runs record for progress tracking.
struct DiscoverActivity: ActivityDefinition {
    typealias Input = DiscoverInput
    typealias Output = DiscoverOutput

    let postgres: PostgresClient

    func run(input: Input, context: ActivityContext) async throws -> Output {
        // ── 1. Get row count from CKAN metadata API ────────────────────────────
        let url = URL(
            string: "\(CNRA.apiBase)?resource_id=\(CNRA.resourceID)&limit=0&include_total=true"
        )!
        let (data, _) = try await URLSession.shared.data(from: url)

        struct CKANResponse: Decodable {
            struct Result: Decodable { let total: Int }
            let success: Bool
            let result: Result
        }
        let resp = try JSONDecoder().decode(CKANResponse.self, from: data)
        guard resp.success else {
            throw DiscoverError.apiFailure("CKAN API returned success=false")
        }
        let totalRows = resp.result.total
        context.logger.info(
            "Discovered \(totalRows) rows in CNRA groundwater dataset",
            metadata: ["job_id": .string(input.jobID)]
        )

        // ── 2. Create pipeline_runs record ─────────────────────────────────────
        try await postgres.query(
            """
            INSERT INTO cnra.pipeline_runs (job_id, total_rows, status, started_at)
            VALUES (\(input.jobID), \(totalRows), 'RUNNING', NOW())
            ON CONFLICT (job_id) DO UPDATE
                SET total_rows = EXCLUDED.total_rows, status = 'RUNNING'
            """,
            logger: context.logger
        )

        return DiscoverOutput(totalRows: totalRows, jobID: input.jobID)
    }
}

enum DiscoverError: Error, CustomStringConvertible {
    case apiFailure(String)
    var description: String {
        switch self {
        case .apiFailure(let msg): return "CKAN API failure: \(msg)"
        }
    }
}
