import Foundation

/// Supabase management-API client.
///
/// Minimal call set: `GET https://api.supabase.com/v1/projects` with the
/// personal access token as a bearer. Each project maps to the direct
/// connection endpoint `db.<ref>.supabase.co:5432`, database `postgres`,
/// user `postgres`. The management API cannot return database passwords,
/// so imported profiles are flagged `requiresPasswordOnFirstConnect`.
struct SupabaseProviderClient: ProviderClient {
    let token: String
    /// Injectable for tests; production uses the real API host.
    var baseURL = URL(string: "https://api.supabase.com")!

    private struct Project: Decodable {
        struct Database: Decodable {
            var host: String?
        }
        /// The project ref (e.g. "abcdefghijklmnop").
        var id: String
        var name: String
        var region: String?
        var status: String?
        var database: Database?
    }

    func listDatabases() async throws -> [ProviderDatabase] {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderImportError.emptyToken }

        let url = baseURL.appendingPathComponent("v1/projects")
        let data = try await ProviderHTTP.get(url, bearer: trimmed)

        let projects: [Project]
        do {
            projects = try JSONDecoder().decode([Project].self, from: data)
        } catch {
            throw ProviderImportError.malformedResponse(
                "could not decode the Supabase project list (\(error.localizedDescription))"
            )
        }

        return projects.map { project in
            let host = project.database?.host ?? "db.\(project.id).supabase.co"
            let connection = PostgresConnectionURL(
                host: host,
                port: 5432,
                database: "postgres",
                user: "postgres",
                password: nil, // not retrievable via the management API
                tls: .require,
                applicationName: nil,
                connectTimeoutSecs: nil
            )
            var detail = host
            if let region = project.region, !region.isEmpty {
                detail += " · \(region)"
            }
            return ProviderDatabase(
                id: "supabase:\(project.id)",
                name: project.name,
                detail: detail,
                connection: connection,
                requiresPasswordOnFirstConnect: true
            )
        }
    }
}
