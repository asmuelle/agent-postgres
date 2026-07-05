import Foundation

/// Neon API v2 client.
///
/// `GET /projects/{id}/connection_uri` requires `database_name` and
/// `role_name` query parameters, so the minimal working call set is:
///   1. `GET /api/v2/projects`                                  → projects
///   2. `GET /api/v2/projects/{id}/branches`                    → default branch
///   3. `GET /api/v2/projects/{id}/branches/{bid}/databases`    → db + owner
///   4. `GET /api/v2/projects/{id}/connection_uri?...`          → postgres:// URI
/// The returned URI includes the role password; it is parsed with
/// `PostgresConnectionURL` and lands in the keychain, never in the profile.
struct NeonProviderClient: ProviderClient {
    let apiKey: String
    /// Injectable for tests; production uses the real API host.
    var baseURL = URL(string: "https://console.neon.tech/api/v2")!

    // MARK: - Response shapes (only the fields we read)

    private struct ProjectList: Decodable {
        struct Project: Decodable {
            var id: String
            var name: String
            var region_id: String?
        }
        var projects: [Project]
    }

    private struct BranchList: Decodable {
        struct Branch: Decodable {
            var id: String
            var name: String?
            var `default`: Bool?
        }
        var branches: [Branch]
    }

    private struct DatabaseList: Decodable {
        struct Database: Decodable {
            var name: String
            var owner_name: String
        }
        var databases: [Database]
    }

    private struct ConnectionURI: Decodable {
        var uri: String
    }

    // MARK: - ProviderClient

    func listDatabases() async throws -> [ProviderDatabase] {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderImportError.emptyToken }

        let projectData = try await ProviderHTTP.get(
            baseURL.appendingPathComponent("projects"), bearer: trimmed
        )
        let projects = try decode(ProjectList.self, from: projectData, what: "project list").projects

        var results: [ProviderDatabase] = []
        for project in projects {
            // Default branch (fall back to the first) — one branch per
            // project keeps the import to the databases users actually mean.
            let branchData = try await ProviderHTTP.get(
                baseURL.appendingPathComponent("projects/\(project.id)/branches"),
                bearer: trimmed
            )
            let branches = try decode(BranchList.self, from: branchData, what: "branch list").branches
            guard let branch = branches.first(where: { $0.default == true }) ?? branches.first else {
                continue
            }

            let dbData = try await ProviderHTTP.get(
                baseURL.appendingPathComponent(
                    "projects/\(project.id)/branches/\(branch.id)/databases"
                ),
                bearer: trimmed
            )
            let databases = try decode(DatabaseList.self, from: dbData, what: "database list").databases

            for database in databases {
                guard var components = URLComponents(
                    url: baseURL.appendingPathComponent("projects/\(project.id)/connection_uri"),
                    resolvingAgainstBaseURL: false
                ) else { continue }
                components.queryItems = [
                    URLQueryItem(name: "branch_id", value: branch.id),
                    URLQueryItem(name: "database_name", value: database.name),
                    URLQueryItem(name: "role_name", value: database.owner_name),
                ]
                guard let uriURL = components.url else { continue }

                let uriData = try await ProviderHTTP.get(uriURL, bearer: trimmed)
                let uri = try decode(ConnectionURI.self, from: uriData, what: "connection URI").uri

                let connection: PostgresConnectionURL
                do {
                    connection = try PostgresConnectionURL.parse(uri)
                } catch {
                    throw ProviderImportError.malformedResponse(
                        "Neon returned an unparseable connection URI for \(project.name)/\(database.name): \(error.localizedDescription)"
                    )
                }

                var detail = connection.host
                if let region = project.region_id, !region.isEmpty {
                    detail += " · \(region)"
                }
                results.append(ProviderDatabase(
                    id: "neon:\(project.id):\(database.name)",
                    name: databases.count > 1 ? "\(project.name) / \(database.name)" : project.name,
                    detail: detail,
                    connection: connection,
                    requiresPasswordOnFirstConnect: connection.password == nil
                ))
            }
        }
        return results
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ProviderImportError.malformedResponse(
                "could not decode the Neon \(what) (\(error.localizedDescription))"
            )
        }
    }
}
