import Hummingbird
import Logging
import PostgresNIO
import Strand

struct NamespaceResponse: Codable, Sendable {
    let id: String
    let displayName: String?
}
extension NamespaceResponse: ResponseCodable {}

struct NamespaceRoutes {
    let postgres: PostgresClient
    let logger: Logger

    func register(on router: some RouterMethods<StrandRequestContext>) {
        // GET /api/namespaces — list all registered namespaces
        router.get("api/namespaces") { _, _ -> [NamespaceResponse] in
            let stream = try await self.postgres.query(
                "SELECT id, display_name FROM strand.namespaces ORDER BY id",
                logger: self.logger
            )
            var rows: [NamespaceResponse] = []
            for try await row in stream {
                var col = row.makeIterator()
                let id = try col.next()!.decode(String.self, context: .default)
                let displayName = try col.next()!.decode(String?.self, context: .default)
                rows.append(NamespaceResponse(id: id, displayName: displayName))
            }
            return rows
        }
    }
}
