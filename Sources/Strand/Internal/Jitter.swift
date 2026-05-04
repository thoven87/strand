/// Returns a deterministic delay for deferring a claimed but unregistered task.
///
/// Uses FNV-1a on the run ID to spread retry times across [15 s, 31 s).
/// The stable mapping from run ID → delay prevents all workers from retrying
/// the same unknown task simultaneously during a rolling deploy that adds a
/// new task type not yet registered on every pod.
func unknownTaskDelay(seed: String) -> Duration {
    var hash: UInt32 = 2_166_136_261
    for byte in seed.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 16_777_619
    }
    return .seconds(15 + Int(hash % 16))
}
