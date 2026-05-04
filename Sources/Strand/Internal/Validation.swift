let maxQueueNameByteLength = 57

/// Validates `name` as a legal Absurd queue name and returns it unchanged.
/// Throws `StrandError.invalidQueueName` for empty or over-length names.
@discardableResult
func validateQueueName(_ name: String) throws -> String {
    guard !name.isEmpty else {
        throw StrandError.invalidQueueName("Queue name must not be empty")
    }
    guard name.utf8.count <= maxQueueNameByteLength else {
        throw StrandError.invalidQueueName(
            "Queue name \"\(name)\" exceeds \(maxQueueNameByteLength) UTF-8 bytes"
        )
    }
    return name
}
