import HTTPTypes
import Hummingbird

/// Extracts the active namespace and stores it in ``StrandRequestContext/namespaceID``.
///
/// Resolution order:
///   1. `:namespace` path parameter (e.g. `/api/pizza-demo/tasks`)
///   2. `X-Strand-Namespace` request header
///   3. `defaultNamespace` passed at construction time
struct NamespaceMiddleware: RouterMiddleware {
    typealias Context = StrandRequestContext

    let defaultNamespace: String

    func handle(
        _ req: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        var context = context

        if let ns = context.parameters.get("namespace", as: String.self), !ns.isEmpty {
            context.namespaceID = ns
        } else if let headerName = HTTPField.Name("X-Strand-Namespace"),
            let ns = req.headers[headerName], !ns.isEmpty
        {
            context.namespaceID = ns
        } else {
            context.namespaceID = defaultNamespace
        }

        return try await next(req, context)
    }
}
