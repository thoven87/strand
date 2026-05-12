import PostgresNIO
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Downloads a chunk of groundwater CSV data from CNRA, parses it line-by-line,
/// and bulk-inserts it into the partitioned `cnra.groundwater_measurements` table.
///
/// Key design decisions:
/// - **Streaming download**: `URLSession.bytes` reads the HTTP body incrementally
///   so we never load a 50k-row CSV entirely into memory.
/// - **`context.heartbeat(rowsDownloaded)`**: called every 1 000 rows.
///   Stores the running row count so a failed attempt knows exactly where to
///   resume: `offset += lastHeartbeat`, `limit -= lastHeartbeat`. This avoids
///   re-downloading already-inserted rows on retry.
/// - **Batch insert**: rows are accumulated in groups of 1 000 and flushed in a
///   single UNNEST transaction, balancing round-trips against memory usage.
/// - **Idempotent progress tracking**: `cnra.chunk_progress` uses ON CONFLICT so
///   a retried activity updates the existing row rather than inserting a duplicate.
struct DownloadAndInsertActivity: ActivityDefinition {
    typealias Input = IngestChunkInput
    typealias Output = IngestChunkOutput

    /// Rows per UNNEST batch. One query regardless of this number —
    /// larger batches = fewer round-trips. 1 000 is a safe balance between
    /// memory usage and network efficiency.
    static let batchInsertSize = 1_000
    static let heartbeatEvery = 1_000

    let postgres: PostgresClient

    func run(input: Input, context: ActivityContext) async throws -> Output {
        // Resume from the last heartbeat checkpoint if this is a retry.
        // On attempt 1 (or if the previous attempt never heartbeated) this is 0.
        let resumeFromRow = context.heartbeatDetails(as: Int.self) ?? 0

        // All rows were already processed in a previous attempt (failed after the
        // last insert but before returning). The inserts would be no-ops anyway,
        // but skip the redundant network request entirely.
        guard resumeFromRow < input.limit else {
            context.logger.info(
                "Chunk already complete (resumeFromRow=\(resumeFromRow) >= limit=\(input.limit)), skipping",
                metadata: ["job_id": .string(input.jobID)]
            )
            return IngestChunkOutput(offset: input.offset, rowsDownloaded: input.limit, rowsInserted: 0)
        }

        // Adjust the API offset/limit to skip rows already inserted.
        let resumeOffset = input.offset + resumeFromRow
        let resumeLimit = input.limit - resumeFromRow

        let chunkURL = URL(
            string: "\(CNRA.dumpBase)?limit=\(resumeLimit)&offset=\(resumeOffset)"
        )!
        context.logger.info(
            resumeFromRow == 0
                ? "Downloading chunk offset=\(input.offset) limit=\(input.limit)"
                : "Resuming chunk offset=\(input.offset) from row \(resumeFromRow) (apiOffset=\(resumeOffset) remaining=\(resumeLimit))",
            metadata: ["job_id": .string(input.jobID)]
        )

        // ── 1. Record chunk start (idempotent) ───────────────────────────────────────
        try await postgres.query(
            """
            INSERT INTO cnra.chunk_progress
                (job_id, chunk_offset, chunk_limit, rows_downloaded, rows_inserted)
            VALUES (\(input.jobID), \(input.offset), \(input.limit), 0, 0)
            ON CONFLICT (job_id, chunk_offset) DO NOTHING
            """,
            logger: context.logger
        )

        // ── 2. Stream + parse ───────────────────────────────────────────────────
        var request = URLRequest(url: chunkURL, timeoutInterval: 600)
        request.setValue("text/csv", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw IngestionError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        var batch: [GroundwaterRow] = []
        // Start the counter at resumeFromRow so heartbeats store the cumulative
        // position within the original chunk across all attempts.
        var rowsDownloaded = resumeFromRow
        var rowsInserted = 0
        var headerSkipped = false

        for try await line in bytes.lines {
            // Skip the header row
            if !headerSkipped {
                headerSkipped = true
                continue
            }
            guard let row = GroundwaterRow(csvLine: line) else { continue }

            batch.append(row)
            rowsDownloaded += 1

            // Heartbeat every N rows: extend the lease AND persist the current
            // row count so a retry knows exactly where to resume.
            if rowsDownloaded % Self.heartbeatEvery == 0 {
                try await context.heartbeat(rowsDownloaded)
                context.logger.debug(
                    "offset=\(input.offset) downloaded=\(rowsDownloaded)",
                    metadata: ["job_id": .string(input.jobID)]
                )
            }

            // Flush batch to Postgres
            if batch.count >= Self.batchInsertSize {
                rowsInserted += try await insertBatch(
                    batch,
                    jobID: input.jobID,
                    postgres: postgres,
                    logger: context.logger
                )
                batch.removeAll(keepingCapacity: true)
            }
        }

        // Flush remaining rows
        if !batch.isEmpty {
            rowsInserted += try await insertBatch(
                batch,
                jobID: input.jobID,
                postgres: postgres,
                logger: context.logger
            )
        }

        // ── 3. Mark chunk complete ──────────────────────────────────────────────
        try await postgres.query(
            """
            UPDATE cnra.chunk_progress
            SET rows_downloaded = \(rowsDownloaded),
                rows_inserted   = \(rowsInserted),
                completed_at    = NOW()
            WHERE job_id = \(input.jobID) AND chunk_offset = \(input.offset)
            """,
            logger: context.logger
        )

        // ── 4. Increment pipeline_runs counter ──────────────────────────────────
        try await postgres.query(
            """
            UPDATE cnra.pipeline_runs
            SET ingested_rows = ingested_rows + \(rowsInserted)
            WHERE job_id = \(input.jobID)
            """,
            logger: context.logger
        )

        context.logger.info(
            "Chunk complete offset=\(input.offset): \(rowsInserted) rows inserted",
            metadata: ["job_id": .string(input.jobID)]
        )

        return IngestChunkOutput(
            offset: input.offset,
            rowsDownloaded: rowsDownloaded,
            rowsInserted: rowsInserted
        )
    }
}

// MARK: - Batch INSERT via UNNEST

/// Inserts a batch of rows in a **single query** using PostgreSQL's UNNEST.
///
/// Binding model (from the example in the project):
///   - Build one `[String]` array per column (column-major layout).
///   - Append each array as one `$N` binding via `PostgresBindings`.
///   - SQL uses `UNNEST($1::text[], ..., $18::text[])` to expand the arrays
///     back into rows server-side.
///
/// This produces exactly 19 bindings regardless of batch size, eliminating
/// the N×round-trips overhead of the per-row approach. For 1 000 rows this
/// is ~1 000× fewer queries than the previous loop-in-transaction approach.
private func insertBatch(
    _ rows: [GroundwaterRow],
    jobID: String,
    postgres: PostgresClient,
    logger: Logger
) async throws -> Int {
    guard !rows.isEmpty else { return 0 }

    // ── Build column-major arrays ───────────────────────────────────────────
    // Empty string stands for SQL NULL: NULLIF(c, '') in the SELECT list
    // converts it back to NULL before the cast to numeric/date.
    var siteCodes = [String]()
    var msmtDates = [String]()
    var wlmRpes = [String]()
    var wlmGses = [String]()
    var gwes = [String]()
    var gseGwes = [String]()
    var qaStatuses = [String]()
    var qaDetails = [String]()
    var methods = [String]()
    var accuracies = [String]()
    var orgNames = [String]()
    var coopOrgs = [String]()
    var programs = [String]()
    var basinCodes = [String]()
    var countyNames = [String]()
    var wellUses = [String]()
    var sources = [String]()
    var msmtCmts = [String]()

    siteCodes.reserveCapacity(rows.count)
    msmtDates.reserveCapacity(rows.count)
    wlmRpes.reserveCapacity(rows.count)
    wlmGses.reserveCapacity(rows.count)
    gwes.reserveCapacity(rows.count)
    gseGwes.reserveCapacity(rows.count)
    qaStatuses.reserveCapacity(rows.count)
    qaDetails.reserveCapacity(rows.count)
    methods.reserveCapacity(rows.count)
    accuracies.reserveCapacity(rows.count)
    orgNames.reserveCapacity(rows.count)
    coopOrgs.reserveCapacity(rows.count)
    programs.reserveCapacity(rows.count)
    basinCodes.reserveCapacity(rows.count)
    countyNames.reserveCapacity(rows.count)
    wellUses.reserveCapacity(rows.count)
    sources.reserveCapacity(rows.count)
    msmtCmts.reserveCapacity(rows.count)

    for row in rows {
        siteCodes.append(row.siteCode)
        msmtDates.append(row.msmtDate)
        wlmRpes.append(row.wlmRpe ?? "")
        wlmGses.append(row.wlmGse ?? "")
        gwes.append(row.gwe ?? "")
        gseGwes.append(row.gseGwe ?? "")
        qaStatuses.append(row.qaStatus ?? "")
        qaDetails.append(row.qaDetail ?? "")
        methods.append(row.method ?? "")
        accuracies.append(row.accuracy ?? "")
        orgNames.append(row.orgName ?? "")
        coopOrgs.append(row.coopOrg ?? "")
        programs.append(row.program ?? "")
        basinCodes.append(row.basinCode ?? "")
        countyNames.append(row.countyName ?? "")
        wellUses.append(row.wellUse ?? "")
        sources.append(row.source ?? "")
        msmtCmts.append(row.msmtCmt ?? "")
    }

    // ── Build bindings: 18 text[] arrays + 1 scalar text ───────────────────
    var bindings = PostgresBindings(capacity: 19)
    bindings.append(siteCodes)  // $1  site_code text[]
    bindings.append(msmtDates)  // $2  msmt_date text[] → ::date
    bindings.append(wlmRpes)  // $3  wlm_rpe   text[] → NULLIF::numeric
    bindings.append(wlmGses)  // $4  wlm_gse
    bindings.append(gwes)  // $5  gwe
    bindings.append(gseGwes)  // $6  gse_gwe
    bindings.append(qaStatuses)  // $7  qa_status text[] → NULLIF
    bindings.append(qaDetails)  // $8  qa_detail
    bindings.append(methods)  // $9  method
    bindings.append(accuracies)  // $10 accuracy
    bindings.append(orgNames)  // $11 org_name
    bindings.append(coopOrgs)  // $12 coop_org
    bindings.append(programs)  // $13 program
    bindings.append(basinCodes)  // $14 basin_code
    bindings.append(countyNames)  // $15 county_name
    bindings.append(wellUses)  // $16 well_use
    bindings.append(sources)  // $17 source
    bindings.append(msmtCmts)  // $18 msmt_cmt
    bindings.append(jobID)  // $19 job_id (scalar constant)

    // ── Single UNNEST INSERT — one round-trip for the entire batch ──────────
    let sql = """
        WITH inserted AS (
            INSERT INTO cnra.groundwater_measurements
                (site_code, msmt_date, wlm_rpe, wlm_gse, gwe, gse_gwe,
                 qa_status, qa_detail, method, accuracy, org_name, coop_org,
                 program, basin_code, county_name, well_use, source, msmt_cmt,
                 job_id)
            SELECT
                c0,
                c1::date,
                NULLIF(c2, '')::numeric,
                NULLIF(c3, '')::numeric,
                NULLIF(c4, '')::numeric,
                NULLIF(c5, '')::numeric,
                NULLIF(c6,  ''), NULLIF(c7,  ''), NULLIF(c8,  ''), NULLIF(c9,  ''),
                NULLIF(c10, ''), NULLIF(c11, ''), NULLIF(c12, ''), NULLIF(c13, ''),
                NULLIF(c14, ''), NULLIF(c15, ''), NULLIF(c16, ''), NULLIF(c17, ''),
                $19
            FROM UNNEST(
                $1::text[],  $2::text[],  $3::text[],  $4::text[],
                $5::text[],  $6::text[],  $7::text[],  $8::text[],
                $9::text[],  $10::text[], $11::text[], $12::text[],
                $13::text[], $14::text[], $15::text[], $16::text[],
                $17::text[], $18::text[]
            ) AS t(c0,c1,c2,c3,c4,c5,c6,c7,c8,c9,c10,c11,c12,c13,c14,c15,c16,c17)
            ON CONFLICT DO NOTHING
            RETURNING 1
        )
        SELECT COUNT(*)::int FROM inserted
        """

    let stream = try await postgres.query(
        PostgresQuery(unsafeSQL: sql, binds: bindings),
        logger: logger
    )
    for try await count in stream.decode(Int.self, context: .default) {
        return count
    }
    return rows.count
}

// MARK: - Errors

enum IngestionError: Error, CustomStringConvertible, LocalizedError {
    case httpError(Int)
    var description: String {
        switch self {
        case .httpError(let c): return "HTTP \(c) from CNRA API"
        }
    }
    var errorDescription: String? { description }
}
