import Hummingbird
import Strand

struct HealthResponse: Codable, Sendable { let ok: Bool }
extension HealthResponse: ResponseCodable {}

struct VersionResponse: Codable, Sendable {
    let schema: String
    let sdk: String
}
extension VersionResponse: ResponseCodable {}

struct HealthRoutes {
    let client: StrandClient

    func register(on router: some RouterMethods<StrandRequestContext>) {

        router.get("health") { _, _ -> HealthResponse in
            HealthResponse(ok: true)
        }

        router.get("version") { _, _ -> VersionResponse in
            try await self.client.verifySchema()
            return VersionResponse(schema: "strand/1", sdk: StrandVersion.current)
        }
    }
}
