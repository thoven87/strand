import Logging

// MARK: - Strand structured-logging conventions
//
// Every significant Strand log event carries `strand.*` metadata keys so that
// log-aggregation systems (Datadog, Splunk, Loki, …) can filter and group
// without parsing message strings.
//
// Key names follow OTel semantic conventions where applicable:
//   error.type        — Swift type name of the thrown error
//   exception.message — String(describing:) of the error
//   strand.queue      — queue name
//   strand.namespace  — tenant namespace
//   strand.worker.id  — process-level worker identifier
//   strand.task.id    — UUID of the strand.tasks row
//   strand.run.id     — UUID of the strand.runs row (one per attempt)
//   strand.task.name  — registered workflow / activity name
//   strand.attempt    — 1-based attempt counter

// MARK: - OTel key constants

enum StrandLogKeys {
    // OTel standard
    static let errorType = "error.type"
    static let exceptionMessage = "exception.message"
    // Strand domain
    static let queue = "strand.queue"
    static let namespace = "strand.namespace"
    static let workerID = "strand.worker.id"
    static let taskID = "strand.task.id"
    static let runID = "strand.run.id"
    static let taskName = "strand.task.name"
    static let attempt = "strand.attempt"
}

// MARK: - Logger scoping helpers

extension Logger {

    /// Returns a copy of this logger enriched with worker-level metadata.
    func withWorkerContext(queue: String, namespace: String, workerID: String) -> Logger {
        self.with([
            StrandLogKeys.queue: .string(queue),
            StrandLogKeys.namespace: .string(namespace),
            StrandLogKeys.workerID: .string(workerID),
        ])
    }

    /// Returns a copy of this logger enriched with task-activation metadata.
    func withTaskContext(_ task: ClaimedTask) -> Logger {
        self.with([
            StrandLogKeys.taskID: .string(task.taskID.uuidString.lowercased()),
            StrandLogKeys.runID: .string(task.runID.uuidString.lowercased()),
            StrandLogKeys.taskName: .string(task.taskName),
            StrandLogKeys.attempt: .stringConvertible(task.attempt),
        ])
    }

    /// Returns a copy with each key-value pair in `extra` merged into the metadata.
    private func with(_ extra: Logger.Metadata) -> Logger {
        var l = self
        for (key, value) in extra {
            l[metadataKey: key] = value
        }
        return l
    }
}

// MARK: - Error metadata

extension Logger.Metadata {

    /// OTel-convention error metadata: `error.type` + `exception.message`.
    static func forError(_ error: Error) -> Logger.Metadata {
        [
            StrandLogKeys.errorType: .string(String(describing: type(of: error))),
            StrandLogKeys.exceptionMessage: .string(String(describing: error)),
        ]
    }

    /// Merge two metadata dictionaries; `rhs` wins on key conflicts.
    static func + (lhs: Logger.Metadata, rhs: Logger.Metadata) -> Logger.Metadata {
        lhs.merging(rhs) { _, new in new }
    }
}
