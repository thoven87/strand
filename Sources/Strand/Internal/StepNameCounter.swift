/// A monotonically-increasing integer counter for workflow checkpoint sequence numbers.
///
/// Each call to `next()` returns the next integer starting from 1, providing a
/// deterministic global ordering of all checkpoint-producing operations within an
/// activation. Every command gets a unique integer identity, discriminating
/// *which instance* of an operation it is.
///
/// The counter is NOT per-step-name — it is global across all operation types
/// (activities, timers, events, uuid(), random(), etc.). This guarantees that any
/// deviation in execution order (non-determinism) produces a different seq_num
/// and is caught immediately.
struct ActivationCounter: Sendable {
    private var value: Int = 0

    /// Returns the next seq_num and advances the counter.
    mutating func next() -> Int {
        value += 1
        return value
    }

    /// The current counter value without advancing.
    var current: Int { value }
}
