import Logging

/// A log handler that silently drops records while the workflow is replaying.
///
/// Workflow handlers re-execute from the beginning on every activation, so without
/// this suppression every log statement emits once per replayed workflow task.
/// The handler reads a shared `ArcBox<Bool>` that `_WorkflowActivation` keeps in
/// sync with `isReplaying`, so it reflects the exact replay/live boundary without
/// needing a separate reference to the activation itself.
struct WorkflowReplayLogHandler: LogHandler {

    private var underlying: any LogHandler
    /// Shared reference to the activation's replay state.
    /// `true` while replaying history, `false` once fresh work begins.
    private let replayState: ArcBox<Bool>

    init(underlying: any LogHandler, replayState: ArcBox<Bool>) {
        self.underlying = underlying
        self.replayState = replayState
    }

    var metadata: Logger.Metadata {
        get { underlying.metadata }
        set { underlying.metadata = newValue }
    }

    var metadataProvider: Logger.MetadataProvider? {
        get { underlying.metadataProvider }
        set { underlying.metadataProvider = newValue }
    }

    var logLevel: Logger.Level {
        get { underlying.logLevel }
        set { underlying.logLevel = newValue }
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { underlying[metadataKey: key] }
        set { underlying[metadataKey: key] = newValue }
    }

    func log(event: LogEvent) {
        guard !replayState.value else { return }
        underlying.log(event: event)
    }
}
