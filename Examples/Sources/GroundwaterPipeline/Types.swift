import Strand

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Dataset constants

enum CNRA {
    static let resourceID = "bfa9f262-24a1-45bd-8dc8-138bc8107266"
    static let dumpBase = "https://data.cnra.ca.gov/datastore/dump/\(resourceID)"
    static let apiBase = "https://data.cnra.ca.gov/api/3/action/datastore_search"
    static let ollamaURL = "http://localhost:11434"
    static let ollamaModel = "qwen3"
}

// MARK: - Pipeline workflow I/O

struct PipelineInput: Codable, Sendable {
    /// Unique ID for this pipeline run — written to cnra.pipeline_runs.
    let jobID: String
    /// Number of rows per ingestion chunk. Default: 50 000.
    let chunkSize: Int
    /// Maximum number of chunks to ingest. `nil` = ingest everything (~125 chunks).
    let maxChunks: Int?
    /// Whether to run the AI analysis stage (requires Ollama running locally).
    let runAI: Bool

    init(
        jobID: String = "gw-\(Int(Date.now.timeIntervalSince1970))",
        chunkSize: Int = 50_000,
        maxChunks: Int? = nil,
        runAI: Bool = true
    ) {
        self.jobID = jobID
        self.chunkSize = chunkSize
        self.maxChunks = maxChunks
        self.runAI = runAI
    }
}

struct PipelineResult: Codable, Sendable {
    let jobID: String
    let totalRows: Int
    let chunksIngested: Int
    let rowsInserted: Int
    let countiesAnalyzed: Int
    let durationSeconds: Double
}

// MARK: - Discovery

struct DiscoverInput: Codable, Sendable {
    let jobID: String
}

struct DiscoverOutput: Codable, Sendable {
    let totalRows: Int
    let jobID: String
}

// MARK: - Ingestion chunk

struct IngestChunkInput: Codable, Sendable {
    let jobID: String
    let offset: Int  // 0-based row offset (after header)
    let limit: Int  // rows to download
}

struct IngestChunkOutput: Codable, Sendable {
    let offset: Int
    let rowsDownloaded: Int
    let rowsInserted: Int
}

// MARK: - Stats computation

struct ComputeStatsInput: Codable, Sendable {
    let jobID: String
    let countyName: String
}

struct ComputeStatsOutput: Codable, Sendable {
    let countyName: String
    let measurementCount: Int
    let siteCount: Int
    let avgDepthFt: Double?
    let minDepthFt: Double?
    let maxDepthFt: Double?
    let trendDeltaFt: Double?  // recent5yr avg - prev5yr avg (+ = declining)
}

// MARK: - AI trend analysis

struct OllamaTrendInput: Codable, Sendable {
    let countyName: String
    let measurementCount: Int
    let avgDepthFt: Double?
    let minDepthFt: Double?
    let maxDepthFt: Double?
    let trendDeltaFt: Double?
    let earliestMsmt: String?
    let latestMsmt: String?
}

struct OllamaTrendOutput: Codable, Sendable {
    let countyName: String
    let trend: String  // DECLINING | STABLE | RECOVERING | UNKNOWN
    let narrative: String  // 2-sentence human-readable summary
}

// MARK: - Parsed CSV row

/// One row from the CNRA groundwater CSV, ready for database insertion.
struct GroundwaterRow: Sendable {
    let siteCode: String
    let msmtDate: String  // ISO 8601 date string, e.g. "2026-03-19"
    let wlmRpe: String?
    let wlmGse: String?
    let gwe: String?
    let gseGwe: String?  // depth to groundwater — the key metric
    let qaStatus: String?
    let qaDetail: String?
    let method: String?
    let accuracy: String?
    let orgName: String?
    let coopOrg: String?
    let program: String?
    let basinCode: String?
    let countyName: String?
    let wellUse: String?
    let source: String?
    let msmtCmt: String?
}

// MARK: - CSV parsing

extension GroundwaterRow {
    /// Parse one line of the CNRA dump CSV.
    ///
    /// Column order (from API field list):
    /// 0: _id, 1: site_code, 2: msmt_date, 3: wlm_rpe, 4: wlm_gse,
    /// 5: gwe, 6: gse_gwe, 7: wlm_qa_desc, 8: wlm_qa_detail,
    /// 9: wlm_mthd_desc, 10: wlm_acc_desc, 11: wlm_org_name,
    /// 12: coop_org_name, 13: monitoring_program, 14: basin_code,
    /// 15: county_name, 16: well_use, 17: source, 18: msmt_cmt
    init?(csvLine line: String) {
        let fields = splitCSV(line)
        guard fields.count >= 18 else { return nil }

        // col 1 — site_code (required)
        let sc = fields[1].trimmingCharacters(in: .whitespaces)
        guard !sc.isEmpty else { return nil }
        siteCode = sc

        // col 2 — msmt_date (required; "2026-03-19T00:00:00" → "2026-03-19")
        let rawDate = fields[2].trimmingCharacters(in: .whitespaces)
        guard !rawDate.isEmpty else { return nil }
        msmtDate = String(rawDate.prefix(10))  // keep YYYY-MM-DD only

        wlmRpe = nilIfEmpty(fields[3])
        wlmGse = nilIfEmpty(fields[4])
        gwe = nilIfEmpty(fields[5])
        gseGwe = nilIfEmpty(fields[6])
        qaStatus = nilIfEmpty(fields[7])
        qaDetail = nilIfEmpty(fields[8])
        method = nilIfEmpty(fields[9])
        accuracy = nilIfEmpty(fields[10])
        orgName = nilIfEmpty(fields[11])
        coopOrg = nilIfEmpty(fields[12])
        program = nilIfEmpty(fields[13])
        basinCode = nilIfEmpty(fields[14])
        countyName = nilIfEmpty(fields[15])
        wellUse = nilIfEmpty(fields[16])
        source = nilIfEmpty(fields[17])
        msmtCmt = fields.count > 18 ? nilIfEmpty(fields[18]) : nil
    }
}

// MARK: - CSV splitting helper

/// RFC 4180-compliant CSV field splitter.
/// Handles quoted fields that contain commas or newlines.
private func splitCSV(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    let chars = Array(line)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "\"" {
            if inQuotes && i + 1 < chars.count && chars[i + 1] == "\"" {
                current.append("\"")
                i += 2
                continue  // escaped quote
            }
            inQuotes.toggle()
        } else if c == "," && !inQuotes {
            fields.append(current)
            current = ""
        } else {
            current.append(c)
        }
        i += 1
    }
    fields.append(current)
    return fields
}

private func nilIfEmpty(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespaces)
    return t.isEmpty ? nil : t
}
