/// Typed-throws async ``Result`` initialiser.
///
/// Allows capturing the result of a `throws(Failure)` async closure into a
/// `Result<Success, Failure>` without losing the static error type at the
/// call site.
///
/// ```swift
/// let outcome = await Result(catching: { try await someTypedThrowsOperation() })
/// switch outcome {
/// case .success(let value): ...
/// case .failure(let err): ...  // err is the concrete Failure type, no casting needed
/// }
/// ```
extension Result {
    /// Creates a `Result` by running `body`, capturing the return value on
    /// success or the thrown error on failure.  The static `Failure` type is
    /// preserved end-to-end — no `as?` cast is needed at the call site.
    @inlinable
    init(catching body: () async throws(Failure) -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
