import PostgresNIO
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Computes aggregated groundwater statistics for one county using SQL window
/// functions. All heavy computation runs inside Postgres — the activity just
/// issues the query and writes the result.
///
/// Trend computation:
///   trend_delta = avg depth (last 5 years) - avg depth (prior 5 years)
///   Positive → water table is deeper (declining)
///   Negative → water table is shallower (recovering)
///   Near zero → stable
struct ComputeCountyStatsActivity: Activity {
    typealias Input = ComputeStatsInput
    typealias Output = ComputeStatsOutput

    let postgres: PostgresClient

    func run(input: Input, context: ActivityContext) async throws -> Output {
        context.logger.info(
            "Computing stats for county: \(input.countyName)",
            metadata: ["job_id": .string(input.jobID)]
        )

        // ── Single query: aggregates + 5-year trend comparison ─────────────────
        let stream = try await postgres.query(
            """
            WITH base AS (
                SELECT
                    COUNT(*)                                       AS cnt,
                    COUNT(DISTINCT site_code)                      AS sites,
                    ROUND(AVG(gse_gwe)::numeric, 3)               AS avg_depth,
                    ROUND(MIN(gse_gwe)::numeric, 3)               AS min_depth,
                    ROUND(MAX(gse_gwe)::numeric, 3)               AS max_depth,
                    ROUND(STDDEV(gse_gwe)::numeric, 3)            AS stddev_depth,
                    ROUND(SUM(CASE WHEN qa_status = 'Good' THEN 1.0 ELSE 0 END)
                          / NULLIF(COUNT(*), 0) * 100, 1)         AS good_pct,
                    MIN(msmt_date)::text                           AS earliest,
                    MAX(msmt_date)::text                           AS latest
                FROM cnra.groundwater_measurements
                WHERE county_name = \(input.countyName)
                  AND gse_gwe IS NOT NULL
            ),
            recent AS (
                SELECT ROUND(AVG(gse_gwe)::numeric, 3) AS avg_depth
                FROM cnra.groundwater_measurements
                WHERE county_name = \(input.countyName)
                  AND gse_gwe IS NOT NULL
                  AND msmt_date >= CURRENT_DATE - INTERVAL '5 years'
            ),
            prev AS (
                SELECT ROUND(AVG(gse_gwe)::numeric, 3) AS avg_depth
                FROM cnra.groundwater_measurements
                WHERE county_name = \(input.countyName)
                  AND gse_gwe IS NOT NULL
                  AND msmt_date >= CURRENT_DATE - INTERVAL '10 years'
                  AND msmt_date  < CURRENT_DATE - INTERVAL '5 years'
            )
            SELECT
                b.cnt::int8, b.sites::int8,
                -- ROUND() / AVG() / STDDEV() return numeric; cast to float8
                -- so PostgresNIO can decode them as Double without typeMismatch.
                b.avg_depth::float8,   b.min_depth::float8,  b.max_depth::float8,
                b.stddev_depth::float8, b.good_pct::float8,
                b.earliest, b.latest,
                r.avg_depth::float8 AS recent_avg,
                p.avg_depth::float8 AS prev_avg,
                ROUND((r.avg_depth - p.avg_depth)::numeric, 3)::float8 AS trend_delta
            FROM base b
            CROSS JOIN recent r
            CROSS JOIN prev p
            """,
            logger: context.logger
        )

        guard let row = try await stream.first(where: { _ in true }) else {
            // County has no data — still return zeros so the workflow doesn't fail
            return ComputeStatsOutput(
                countyName: input.countyName,
                measurementCount: 0,
                siteCount: 0,
                avgDepthFt: nil,
                minDepthFt: nil,
                maxDepthFt: nil,
                trendDeltaFt: nil
            )
        }

        var col = row.makeIterator()
        let cnt = try col.next()!.decode(Int.self, context: .default)
        let sites = try col.next()!.decode(Int.self, context: .default)
        let avgDepth = try col.next()!.decode(Double?.self, context: .default)
        let minDepth = try col.next()!.decode(Double?.self, context: .default)
        let maxDepth = try col.next()!.decode(Double?.self, context: .default)
        let stddev = try col.next()!.decode(Double?.self, context: .default)
        let goodPct = try col.next()!.decode(Double?.self, context: .default)
        let earliest = try col.next()!.decode(String?.self, context: .default)
        let latest = try col.next()!.decode(String?.self, context: .default)
        let recentAvg = try col.next()!.decode(Double?.self, context: .default)
        let prevAvg = try col.next()!.decode(Double?.self, context: .default)
        let trendDelta = try col.next()!.decode(Double?.self, context: .default)

        // ── Upsert into county_stats ───────────────────────────────────────────
        try await postgres.query(
            """
            INSERT INTO cnra.county_stats
                (county_name, measurement_count, site_count, good_pct,
                 avg_depth_ft, min_depth_ft, max_depth_ft, stddev_depth_ft,
                 recent_avg_depth, prev_avg_depth, trend_delta_ft,
                 earliest_msmt, latest_msmt, computed_at)
            VALUES (
                \(input.countyName), \(cnt), \(sites), \(goodPct),
                \(avgDepth), \(minDepth), \(maxDepth), \(stddev),
                \(recentAvg), \(prevAvg), \(trendDelta),
                \(earliest)::date, \(latest)::date,
                NOW()
            )
            ON CONFLICT (county_name) DO UPDATE SET
                measurement_count = EXCLUDED.measurement_count,
                site_count        = EXCLUDED.site_count,
                good_pct          = EXCLUDED.good_pct,
                avg_depth_ft      = EXCLUDED.avg_depth_ft,
                min_depth_ft      = EXCLUDED.min_depth_ft,
                max_depth_ft      = EXCLUDED.max_depth_ft,
                stddev_depth_ft   = EXCLUDED.stddev_depth_ft,
                recent_avg_depth  = EXCLUDED.recent_avg_depth,
                prev_avg_depth    = EXCLUDED.prev_avg_depth,
                trend_delta_ft    = EXCLUDED.trend_delta_ft,
                earliest_msmt     = EXCLUDED.earliest_msmt,
                latest_msmt       = EXCLUDED.latest_msmt,
                computed_at       = NOW()
            """,
            logger: context.logger
        )

        let avgStr = avgDepth.map { String(format: "%.1f", $0) } ?? "n/a"
        context.logger.info(
            "Stats for \(input.countyName): \(cnt) measurements, avg depth \(avgStr) ft",
            metadata: ["job_id": .string(input.jobID)]
        )

        return ComputeStatsOutput(
            countyName: input.countyName,
            measurementCount: cnt,
            siteCount: sites,
            avgDepthFt: avgDepth,
            minDepthFt: minDepth,
            maxDepthFt: maxDepth,
            trendDeltaFt: trendDelta
        )
    }
}
