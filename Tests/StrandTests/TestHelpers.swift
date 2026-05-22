@_exported import StrandTesting
import Synchronization
import Testing

@testable import Strand

// MARK: - Tag

extension Tag {
    @Tag static var integration: Self
}

// MARK: - Thread-safe test utilities

/// Thread-safe integer counter used to verify execution counts from workflow/activity handlers.
final class AtomicCounter: Sendable {
    private let _value: Mutex<Int> = Mutex(0)
    var value: Int { _value.withLock { $0 } }
    func increment() { _value.withLock { $0 += 1 } }
}

/// Thread-safe single-value box used to compare values captured across separate activations.
final class AtomicInt: Sendable {
    private let _value: Mutex<Int> = Mutex(0)
    var value: Int { _value.withLock { $0 } }
    func store(_ v: Int) { _value.withLock { $0 = v } }
}
