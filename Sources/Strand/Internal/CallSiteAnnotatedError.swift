/// Package-internal error wrapper that carries the `#fileID` / `#line` of the
/// public `WorkflowContext` call site where the failure was observed (e.g. the
/// `context.runActivity(...)` call in the user's workflow handler).
///
/// Follows the same pattern postgres-nio uses for stamping call-site info onto
/// `PSQLError`: the public boundary captures `#fileID` / `#line` as defaulted
/// parameters, and on error it wraps (or stamps) the error before rethrowing.
///
/// `StrandWorker.runTask` unwraps this before building the stored `FailureReason`,
/// so the location ends up in `strand.runs.failure_reason` for the dashboard.
package struct CallSiteAnnotatedError: Error, Sendable {
    package let underlying: any Error & Sendable
    package let fileID: String
    package let line: Int
}
