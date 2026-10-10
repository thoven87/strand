import Foundation
import Strand

@ActivityContainer
struct BatchActivities {
    let totalRecords: Int

    @Activity
    func getRecordCount(input: GetRecordCountInput) async throws -> Int {
        totalRecords
    }

    @Activity
    func getRecords(input: GetRecordsInput) async throws -> GetRecordsOutput {
        var records: [GetRecordsOutput.Record] = []
        let limit = min(input.offset + input.pageSize, input.maxOffset)
        for id in input.offset..<limit {
            records.append(.init(id: id))
        }
        return GetRecordsOutput(records: records)
    }

    /// Simulates record processing. In production this would call an external API,
    /// write to a database, etc. Here it just sleeps for the specified duration.
    @Activity
    func processRecord(input: ProcessRecordInput) async throws {
        try await Task.sleep(nanoseconds: UInt64(input.processingMs) * 1_000_000)
    }
}
