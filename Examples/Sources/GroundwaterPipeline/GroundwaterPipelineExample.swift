/// California Groundwater Level Pipeline
///
/// Downloads 6.2M rows of CNRA groundwater measurements, inserts them into
/// a range-partitioned Postgres table, computes per-county statistics, and
/// runs Ollama AI trend analysis — all durably orchestrated by Strand.
///
/// ## Quick start
///
///   # Apply schema (once)
///   psql "$POSTGRES_URL" -f Sources/GroundwaterPipeline/cnra_schema.sql
///
///   # Run full pipeline (all 125 chunks, ~6.2M rows)
///   cd Examples && swift run GroundwaterPipeline
///
///   # Test run — just 2 chunks (100k rows) without AI
///   cd Examples && CHUNK_SIZE=50000 MAX_CHUNKS=2 RUN_AI=false swift run GroundwaterPipeline
///
///   # Monitor progress (while running)
///   psql "$POSTGRES_URL" -c "SELECT * FROM cnra.pipeline_runs;"
///   psql "$POSTGRES_URL" -c "SELECT job_id, COUNT(*), SUM(rows_inserted) FROM cnra.chunk_progress GROUP BY job_id;"
///
/// ## Architecture
///
/// Four Strand queues, each with dedicated worker pools:
///
///   gw-orchestrator   (1 workflow) — GroundwaterPipelineWorkflow
///   gw-ingestion     (20 workflows × 40 activities) — IngestChunkWorkflow
///   gw-analytics     (10 workflows × 20 activities) — StatsWorkflow
///   gw-ai             (5 workflows × 10 activities) — AIAnalysisWorkflow
///
/// The orchestrator dispatches all 125 chunk workflows at once; each runs
/// independently on gw-ingestion. When all chunks complete, the orchestrator
/// transitions to stats, then AI — sequential at the pipeline level but
/// parallel within each stage.

import Logging
import PostgresNIO
import ServiceLifecycle
import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@main struct GroundwaterPipelineExample {
    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput(label:))
        let logger = Logger(label: "gw-pipeline")

        let env = ProcessInfo.processInfo.environment
        let chunkSize = Int(env["CHUNK_SIZE"] ?? "50000") ?? 50_000
        let maxChunks = env["MAX_CHUNKS"].flatMap(Int.init)
        let runAI = (env["RUN_AI"] ?? "true").lowercased() != "false"
        // CNRA.cnraDownloadRPS and CNRA.ollamaRPS are read lazily from env at first
        // use; reference them here just to trigger eager initialisation so they
        // appear in the startup banner below.
        let downloadRPS = CNRA.cnraDownloadRPS
        let ollamaRPS   = CNRA.ollamaRPS
        // RESUME_ONLY=true: start workers to continue existing in-flight
        // pipelines without spawning a new one. Use after a crash or Ctrl+C.
        let resumeOnly = (env["RESUME_ONLY"] ?? "false").lowercased() == "true"

        let postgres = PostgresClient(
            configuration: .init(
                host: env["POSTGRES_HOST"] ?? "localhost",
                port: Int(env["POSTGRES_PORT"] ?? "5499") ?? 5499,
                username: env["POSTGRES_USER"] ?? "strand",
                password: env["POSTGRES_PASSWORD"] ?? "strand",
                database: env["POSTGRES_DB"] ?? "strand_dev",
                tls: .disable
            ),
            backgroundLogger: logger
        )

        // ── StrandService: four queues sharing one notifier connection ──────────
        let strand = StrandService(
            postgres: postgres,
            options: .init(
                queues: [
                    // Orchestrator — top-level pipeline + discovery
                    .init(
                        name: "gw-orchestrator",
                        namespace: "groundwater-pipeline",
                        workflows: [GroundwaterPipelineWorkflow.self, StatsWorkflow.self],
                        activities: [
                            DiscoverActivity(postgres: postgres),
                            DiscoverCountiesActivity(postgres: postgres),
                        ],
                        workflowConcurrency: 4,
                        activityConcurrency: 8,
                        claimTimeout: .seconds(120)
                    ),
                    // Ingestion — 20 concurrent chunk workflows × 40 download activities.
                    // Each download can take 30–120 s; claimTimeout gives 10 min.
                    .init(
                        name: "gw-ingestion",
                        namespace: "groundwater-pipeline",
                        workflows: [IngestChunkWorkflow.self],
                        activities: [DownloadAndInsertActivity(postgres: postgres)],
                        workflowConcurrency: 20,
                        activityConcurrency: 40,
                        claimTimeout: .seconds(600)
                    ),
                    // Analytics — stats computation
                    .init(
                        name: "gw-analytics",
                        namespace: "groundwater-pipeline",
                        workflows: [StatsWorkflow.self],
                        activities: [
                            ComputeCountyStatsActivity(postgres: postgres),
                            // DiscoverCountiesActivity runs inside StatsWorkflow on
                            // gw-analytics so it must be registered here too.
                            DiscoverCountiesActivity(postgres: postgres),
                        ],
                        workflowConcurrency: 10,
                        activityConcurrency: 20,
                        claimTimeout: .seconds(300)
                    ),
                    // AI — rate-limited; Ollama is the bottleneck
                    .init(
                        name: "gw-ai",
                        namespace: "groundwater-pipeline",
                        workflows: [AIAnalysisWorkflow.self],
                        activities: [
                            OllamaTrendActivity(postgres: postgres),
                            FetchCountyStatsActivity(postgres: postgres),
                        ],
                        workflowConcurrency: 5,
                        activityConcurrency: 10,
                        claimTimeout: .seconds(180)
                    ),
                ],
                logger: logger
            )
        )

        let client = strand.client(queue: "gw-orchestrator", namespace: "groundwater-pipeline")

        // ── Pipeline launch task ───────────────────────────────────────────────────
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        Task {
            do {
                try await Task.sleep(for: .milliseconds(500))

                // Apply CNRA schema (idempotent — uses IF NOT EXISTS everywhere)
                try await applySchema(postgres: postgres, logger: logger)

                if resumeOnly {
                    // Workers are running — any SLEEPING/PENDING workflows in
                    // the DB will be claimed and continued automatically.
                    print("\n▶️  Resume mode: workers started, watching for in-flight pipelines…")
                    print("   Ctrl+C to stop once all workflows complete.")
                    return
                }

                let input = PipelineInput(
                    chunkSize: chunkSize,
                    maxChunks: maxChunks,
                    runAI: runAI
                )

                print(
                    """

                    🌊 California Groundwater Level Pipeline
                    ─────────────────────────────────────────
                      Dataset:    CNRA Periodic Groundwater Measurements
                      Rows:       ~6,209,669 (will verify via API)
                      Chunk size: \(chunkSize) rows
                      Max chunks: \(maxChunks.map(String.init) ?? "all (~125)")
                      AI stage:   \(runAI ? "enabled (requires Ollama + qwen3)" : "disabled")
                      Job ID:     \(input.jobID)
                    ─────────────────────────────────────────
                      Rate limits (Strand slot scheduling):
                        CNRA API: \(String(format: "%.1f", downloadRPS)) downloads/s  (CNRA_DOWNLOAD_RPS)
                        Ollama:   \(String(format: "%.3g", ollamaRPS)) req/s           (OLLAMA_RPS)
                    ─────────────────────────────────────────
                    """
                )

                let handle = try await client.startWorkflow(
                    GroundwaterPipelineWorkflow.self,
                    input: input
                )
                print("📌 Workflow started: \(handle.workflowID)")
                print("   Track: SELECT * FROM cnra.pipeline_runs WHERE job_id = '\(input.jobID)';")
                print(
                    "   Chunk progress: SELECT COUNT(*), SUM(rows_inserted) FROM cnra.chunk_progress WHERE job_id = '\(input.jobID)';"
                )
                print()

                let result = try await handle.result(
                    timeout: .seconds(
                        Double(max(3600, chunkSize * (maxChunks ?? 130) / 50_000 * 60))
                    )
                )

                print(
                    """

                    ✅ Pipeline complete!
                    ──────────────────────────────────────────
                      Job ID:           \(result.jobID)
                      Total rows:       \(result.totalRows)
                      Chunks ingested:  \(result.chunksIngested)
                      Rows inserted:    \(result.rowsInserted)
                      Counties:         \(result.countiesAnalyzed)
                      Duration:         \(String(format: "%.1f", result.durationSeconds))s
                    ──────────────────────────────────────────

                    📊 Query your data:
                      SELECT county_name, measurement_count, avg_depth_ft, trend, ai_narrative
                      FROM cnra.county_stats ORDER BY measurement_count DESC LIMIT 10;
                    """
                )

            } catch {
                print("❌ Pipeline error:", error)
            }
            cont.finish()
        }

        try await ServiceGroup(
            services: [postgres, strand],
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: logger
        ).run()

        for await _ in stream {}
    }
}

// MARK: - Schema application

private func applySchema(postgres: PostgresClient, logger: Logger) async throws {
    // Each statement must be executed separately (extended query protocol = one at a time)
    let statements = schemaStatements()
    for sql in statements {
        try await postgres.query(PostgresQuery(unsafeSQL: sql), logger: logger)
    }
    logger.info("CNRA schema applied")
}

/// Returns all schema DDL statements split for one-at-a-time execution.
private func schemaStatements() -> [String] {
    [
        "CREATE SCHEMA IF NOT EXISTS cnra",

        // Main measurements table (partitioned)
        """
        CREATE TABLE IF NOT EXISTS cnra.groundwater_measurements (
            id BIGINT GENERATED ALWAYS AS IDENTITY,
            site_code TEXT NOT NULL, msmt_date DATE NOT NULL,
            gse_gwe NUMERIC(12,3), gwe NUMERIC(12,3),
            wlm_gse NUMERIC(12,3), wlm_rpe NUMERIC(12,3),
            qa_status TEXT, qa_detail TEXT, method TEXT, accuracy TEXT,
            org_name TEXT, coop_org TEXT, program TEXT, basin_code TEXT,
            county_name TEXT, well_use TEXT, source TEXT, msmt_cmt TEXT,
            ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), job_id TEXT NOT NULL,
            PRIMARY KEY (id, msmt_date)
        ) PARTITION BY RANGE (msmt_date)
        """,
        "CREATE TABLE IF NOT EXISTS cnra.gw_pre1970 PARTITION OF cnra.groundwater_measurements FOR VALUES FROM (MINVALUE) TO ('1970-01-01')",
        "CREATE TABLE IF NOT EXISTS cnra.gw_1970s PARTITION OF cnra.groundwater_measurements FOR VALUES FROM ('1970-01-01') TO ('1980-01-01')",
        "CREATE TABLE IF NOT EXISTS cnra.gw_1980s PARTITION OF cnra.groundwater_measurements FOR VALUES FROM ('1980-01-01') TO ('1990-01-01')",
        "CREATE TABLE IF NOT EXISTS cnra.gw_1990s PARTITION OF cnra.groundwater_measurements FOR VALUES FROM ('1990-01-01') TO ('2000-01-01')",
        "CREATE TABLE IF NOT EXISTS cnra.gw_2000s PARTITION OF cnra.groundwater_measurements FOR VALUES FROM ('2000-01-01') TO ('2010-01-01')",
        "CREATE TABLE IF NOT EXISTS cnra.gw_2010s PARTITION OF cnra.groundwater_measurements FOR VALUES FROM ('2010-01-01') TO ('2020-01-01')",
        "CREATE TABLE IF NOT EXISTS cnra.gw_2020s PARTITION OF cnra.groundwater_measurements FOR VALUES FROM ('2020-01-01') TO ('2030-01-01')",
        "CREATE TABLE IF NOT EXISTS cnra.gw_future PARTITION OF cnra.groundwater_measurements FOR VALUES FROM ('2030-01-01') TO (MAXVALUE)",
        "CREATE INDEX IF NOT EXISTS cnra_gw_county_date ON cnra.groundwater_measurements (county_name, msmt_date DESC)",
        "CREATE INDEX IF NOT EXISTS cnra_gw_site_date ON cnra.groundwater_measurements (site_code, msmt_date DESC)",

        // Stats table
        """
        CREATE TABLE IF NOT EXISTS cnra.county_stats (
            county_name TEXT PRIMARY KEY, measurement_count BIGINT NOT NULL DEFAULT 0,
            site_count INT NOT NULL DEFAULT 0, good_pct NUMERIC(5,2),
            avg_depth_ft NUMERIC(10,3), min_depth_ft NUMERIC(10,3),
            max_depth_ft NUMERIC(10,3), stddev_depth_ft NUMERIC(10,3),
            recent_avg_depth NUMERIC(10,3), prev_avg_depth NUMERIC(10,3),
            trend_delta_ft NUMERIC(10,3), earliest_msmt DATE, latest_msmt DATE,
            trend TEXT, ai_narrative TEXT,
            computed_at TIMESTAMPTZ DEFAULT NOW(), ai_analyzed_at TIMESTAMPTZ
        )
        """,

        // Chunk progress
        """
        CREATE TABLE IF NOT EXISTS cnra.chunk_progress (
            job_id TEXT NOT NULL, chunk_offset BIGINT NOT NULL,
            chunk_limit INT NOT NULL, rows_downloaded INT NOT NULL DEFAULT 0,
            rows_inserted INT NOT NULL DEFAULT 0,
            started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), completed_at TIMESTAMPTZ,
            PRIMARY KEY (job_id, chunk_offset)
        )
        """,

        // Pipeline runs
        """
        CREATE TABLE IF NOT EXISTS cnra.pipeline_runs (
            job_id TEXT PRIMARY KEY, total_rows BIGINT, total_chunks INT,
            ingested_rows BIGINT NOT NULL DEFAULT 0,
            counties_analyzed INT NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'RUNNING',
            started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            completed_at TIMESTAMPTZ, duration_seconds NUMERIC(12,3), notes TEXT
        )
        """,
    ]
}
