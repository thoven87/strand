-- California Natural Resources Agency — Groundwater Level Pipeline Schema
-- Apply: psql "$DATABASE_URL" -f cnra_schema.sql
-- Compatible with PostgreSQL 15+

CREATE SCHEMA IF NOT EXISTS cnra;

-- ─────────────────────────────────────────────────────────────────────────────
-- Core measurements table — range-partitioned by measurement date.
--
-- Range partitioning lets Postgres skip entire decades of data for time-bounded
-- queries (e.g. "last 5 years") and allows maintenance (VACUUM, index rebuilds)
-- per partition rather than locking the whole 6M-row table.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS cnra.groundwater_measurements (
    id          BIGINT          GENERATED ALWAYS AS IDENTITY,
    site_code   TEXT            NOT NULL,
    msmt_date   DATE            NOT NULL,
    -- Key hydrological metrics
    gse_gwe     NUMERIC(12, 3),                 -- depth to groundwater (ft below surface)
    gwe         NUMERIC(12, 3),                 -- groundwater elevation (ft NAVD88)
    wlm_gse     NUMERIC(12, 3),                 -- ground surface elevation (ft NAVD88)
    wlm_rpe     NUMERIC(12, 3),                 -- reference point elevation (ft NAVD88)
    -- Quality and metadata
    qa_status   TEXT,                           -- Good | Questionable | Provisional | Missing
    qa_detail   TEXT,
    method      TEXT,
    accuracy    TEXT,
    org_name    TEXT,
    coop_org    TEXT,
    program     TEXT,                           -- SGMA | CASGEM | VOLUNTARY
    basin_code  TEXT,
    county_name TEXT,
    well_use    TEXT,
    source      TEXT,                           -- DWR_DISCRETE | DWR_CONTINUOUS
    msmt_cmt    TEXT,
    -- Pipeline metadata
    ingested_at TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    job_id      TEXT            NOT NULL,
    PRIMARY KEY (id, msmt_date)                 -- composite PK required for partitioning
) PARTITION BY RANGE (msmt_date);

-- Decade partitions — prune old data without a full-table scan
CREATE TABLE IF NOT EXISTS cnra.gw_pre1970
    PARTITION OF cnra.groundwater_measurements
    FOR VALUES FROM (MINVALUE) TO ('1970-01-01');

CREATE TABLE IF NOT EXISTS cnra.gw_1970s
    PARTITION OF cnra.groundwater_measurements
    FOR VALUES FROM ('1970-01-01') TO ('1980-01-01');

CREATE TABLE IF NOT EXISTS cnra.gw_1980s
    PARTITION OF cnra.groundwater_measurements
    FOR VALUES FROM ('1980-01-01') TO ('1990-01-01');

CREATE TABLE IF NOT EXISTS cnra.gw_1990s
    PARTITION OF cnra.groundwater_measurements
    FOR VALUES FROM ('1990-01-01') TO ('2000-01-01');

CREATE TABLE IF NOT EXISTS cnra.gw_2000s
    PARTITION OF cnra.groundwater_measurements
    FOR VALUES FROM ('2000-01-01') TO ('2010-01-01');

CREATE TABLE IF NOT EXISTS cnra.gw_2010s
    PARTITION OF cnra.groundwater_measurements
    FOR VALUES FROM ('2010-01-01') TO ('2020-01-01');

CREATE TABLE IF NOT EXISTS cnra.gw_2020s
    PARTITION OF cnra.groundwater_measurements
    FOR VALUES FROM ('2020-01-01') TO ('2030-01-01');

CREATE TABLE IF NOT EXISTS cnra.gw_future
    PARTITION OF cnra.groundwater_measurements
    FOR VALUES FROM ('2030-01-01') TO (MAXVALUE);

-- Indexes — created on the parent, automatically applied to each partition
CREATE INDEX IF NOT EXISTS cnra_gw_county_date
    ON cnra.groundwater_measurements (county_name, msmt_date DESC);

CREATE INDEX IF NOT EXISTS cnra_gw_site_date
    ON cnra.groundwater_measurements (site_code, msmt_date DESC);

CREATE INDEX IF NOT EXISTS cnra_gw_basin
    ON cnra.groundwater_measurements (basin_code, msmt_date DESC)
    WHERE basin_code IS NOT NULL;

CREATE INDEX IF NOT EXISTS cnra_gw_qa
    ON cnra.groundwater_measurements (qa_status, county_name)
    WHERE qa_status IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- Per-county aggregated statistics — populated by ComputeStatsWorkflow.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS cnra.county_stats (
    county_name         TEXT            PRIMARY KEY,
    measurement_count   BIGINT          NOT NULL DEFAULT 0,
    site_count          INT             NOT NULL DEFAULT 0,
    good_pct            NUMERIC(5, 2),           -- % of measurements with qa_status = 'Good'
    avg_depth_ft        NUMERIC(10, 3),          -- avg gse_gwe
    min_depth_ft        NUMERIC(10, 3),
    max_depth_ft        NUMERIC(10, 3),
    stddev_depth_ft     NUMERIC(10, 3),
    -- Trend: compare last 5 years avg depth vs previous 5 years avg depth.
    -- Positive delta = water table DROPPING (deeper) = DECLINING.
    recent_avg_depth    NUMERIC(10, 3),          -- avg depth, last 5 years
    prev_avg_depth      NUMERIC(10, 3),          -- avg depth, years 6-10
    trend_delta_ft      NUMERIC(10, 3),          -- recent - prev (+ means declining)
    earliest_msmt       DATE,
    latest_msmt         DATE,
    -- AI-populated fields (OllamaTrendActivity)
    trend               TEXT,                    -- DECLINING | STABLE | RECOVERING | UNKNOWN
    ai_narrative        TEXT,
    computed_at         TIMESTAMPTZ     DEFAULT NOW(),
    ai_analyzed_at      TIMESTAMPTZ
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Per-chunk progress — enables idempotent restarts and dashboard progress.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS cnra.chunk_progress (
    job_id          TEXT            NOT NULL,
    chunk_offset    BIGINT          NOT NULL,
    chunk_limit     INT             NOT NULL,
    rows_downloaded INT             NOT NULL DEFAULT 0,
    rows_inserted   INT             NOT NULL DEFAULT 0,
    started_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ,
    PRIMARY KEY (job_id, chunk_offset)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Top-level pipeline run log — one row per `swift run GroundwaterPipeline`.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS cnra.pipeline_runs (
    job_id              TEXT            PRIMARY KEY,
    total_rows          BIGINT,
    total_chunks        INT,
    ingested_rows       BIGINT          NOT NULL DEFAULT 0,
    counties_analyzed   INT             NOT NULL DEFAULT 0,
    status              TEXT            NOT NULL DEFAULT 'RUNNING',
    started_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    completed_at        TIMESTAMPTZ,
    duration_seconds    NUMERIC(12, 3),
    notes               TEXT
);
