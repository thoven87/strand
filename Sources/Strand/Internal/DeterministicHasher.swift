/// Deterministic string hashing that produces stable results across process restarts.
///
/// Swift's built-in `Hasher` is randomised on every launch for security reasons,
/// so it cannot be used anywhere a stable, repeatable hash value is required.
/// This utility provides a djb2-based hash that returns the same `Int` for the
/// same input regardless of when or where the process runs.
///
/// Current use: ``SchedulePattern`` feeds values from this hasher into its
/// `Hashable` conformance so schedule patterns can be used as dictionary keys
/// and compared across activations.
struct DeterministicHasher {
    /// Returns a stable, positive hash value for `string` using the djb2 algorithm.
    static func hash(_ string: String) -> Int {
        var h: UInt32 = 5381
        for byte in string.utf8 {
            h = ((h << 5) &+ h) &+ UInt32(byte)
        }
        return Int(h & 0x7FFF_FFFF)
    }
}
