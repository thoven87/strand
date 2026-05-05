import PostgresNIO
import Strand

/// Queries `cnra.groundwater_measurements` for distinct county names.
/// Used by StatsWorkflow to drive fan-out — the county list is data-driven,
/// not hardcoded, so it adapts to whatever counties appear in the ingested data.
struct DiscoverCountiesActivity: ActivityDefinition {
    typealias Input = String  // jobID
    typealias Output = [String]

    let postgres: PostgresClient

    func run(input: String, context: ActivityContext) async throws -> [String] {
        let stream = try await postgres.query(
            """
            SELECT DISTINCT county_name
            FROM cnra.groundwater_measurements
            WHERE county_name IS NOT NULL
              AND county_name <> ''
            ORDER BY county_name
            """,
            logger: context.logger
        )
        var counties: [String] = []
        for try await row in stream {
            var col = row.makeIterator()
            if let name = try col.next()?.decode(String?.self, context: .default) {
                counties.append(name)
            }
        }
        context.logger.info(
            "Found \(counties.count) distinct counties",
            metadata: ["job_id": .string(input)]
        )
        return counties
    }
}
