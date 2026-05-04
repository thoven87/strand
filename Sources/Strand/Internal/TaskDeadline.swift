import Synchronization

/// A deadline that can be renewed from any concurrent context.
///
/// `Sendable`-conformant: the stored instant is protected by a `Mutex`,
/// so concurrent `renew()` and `isExpired` calls are data-race free.
///
/// `Worker.runTask` creates one per task; `_WorkflowActivation.persistCheckpoint`
/// calls `renew()` on every checkpoint write to extend the 2× fatal deadline.
final class TaskDeadline: Sendable {
    private let _deadline: Mutex<ContinuousClock.Instant>
    private let timeout: Duration

    init(timeout: Duration) {
        self.timeout = timeout
        self._deadline = Mutex(.now.advanced(by: timeout))
    }

    /// Reset the deadline to `now + timeout`.
    func renew() {
        _deadline.withLock { $0 = .now.advanced(by: timeout) }
    }

    /// True when the current time has passed the deadline.
    var isExpired: Bool {
        _deadline.withLock { ContinuousClock.now >= $0 }
    }
}
