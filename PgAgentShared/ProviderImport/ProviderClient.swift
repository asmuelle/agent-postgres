import Foundation

// =============================================================================
// Provider import (roadmap 2.1): thin "list databases, mint connection
// profile" clients. No provider lock-in features, no OAuth (token paste
// only), no telemetry. Network via URLSession; platform neutral.
// =============================================================================

/// Which hosted-Postgres provider a token belongs to. Drives the token's
/// keychain account and the client construction.
enum PostgresProvider: String, CaseIterable, Identifiable, Sendable {
    case supabase
    case neon

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .supabase: return "Supabase"
        case .neon:     return "Neon"
        }
    }

    var tokenFieldLabel: String {
        switch self {
        case .supabase: return "Personal access token"
        case .neon:     return "API key"
        }
    }

    var tokenHelpText: String {
        switch self {
        case .supabase:
            return "Create one at supabase.com → Account → Access Tokens. Project database passwords are not readable via the API — you'll be asked for each database's password on first connect."
        case .neon:
            return "Create one at console.neon.tech → Account settings → API keys. Connection strings include the role password, which is stored in your keychain."
        }
    }

    func makeClient(token: String) -> any ProviderClient {
        switch self {
        case .supabase: return SupabaseProviderClient(token: token)
        case .neon:     return NeonProviderClient(apiKey: token)
        }
    }
}

/// One importable database discovered at a provider.
struct ProviderDatabase: Identifiable, Sendable, Equatable {
    var id: String
    /// Display name (project name, or "project / database" for Neon).
    var name: String
    /// Secondary display line (host, region…).
    var detail: String
    /// Parsed connection parameters. `connection.password` is non-nil when
    /// the provider API returns credentials (Neon); the import flow stores
    /// it in the keychain, never in the profile.
    var connection: PostgresConnectionURL
    /// True when the provider API cannot return the database password
    /// (Supabase) — the profile is imported with keychain auth and the
    /// user supplies the password on first connect / by editing.
    var requiresPasswordOnFirstConnect: Bool
}

protocol ProviderClient: Sendable {
    /// List the databases this token can reach. Implementations keep to the
    /// minimal call set and surface HTTP failures verbatim as
    /// `ProviderImportError`.
    func listDatabases() async throws -> [ProviderDatabase]
}

enum ProviderImportError: LocalizedError {
    case emptyToken
    /// 401 — distinct case so the UI can say "token invalid or expired".
    case unauthorized(status: Int)
    case http(status: Int, body: String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .emptyToken:
            return "Enter an API token first."
        case .unauthorized(let status):
            return "HTTP \(status): token invalid or expired."
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
            return snippet.isEmpty ? "HTTP \(status)." : "HTTP \(status): \(snippet)"
        case .malformedResponse(let detail):
            return "Unexpected response from the provider API: \(detail)"
        }
    }
}

// MARK: - Shared HTTP helper

enum ProviderHTTP {
    /// GET `url` with a bearer token; returns the body on 2xx, throws
    /// `ProviderImportError` otherwise (401 → `.unauthorized`).
    static func get(_ url: URL, bearer token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderImportError.malformedResponse("not an HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw ProviderImportError.unauthorized(status: http.statusCode)
        default:
            throw ProviderImportError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }
}

// MARK: - Token keychain storage

/// Stores provider API tokens in the OS keychain via `KeychainManager`.
///
/// The credential-kind enum (`FfiCredentialKind`) is generated by uniffi and
/// backed by the Rust core on macOS, so a genuinely new kind would require
/// an FFI change. Instead tokens are namespaced under the existing
/// `.postgresPassword` kind with a reserved account prefix — same keychain,
/// zero chance of colliding with a real profile account (profile accounts
/// are always `user@host:port/db`). Tokens never touch UserDefaults or
/// profile JSON.
@MainActor
enum ProviderTokenStore {
    private static let accountPrefix = "pgagent-provider-token:"

    private static func account(for provider: PostgresProvider) -> String {
        accountPrefix + provider.rawValue
    }

    static func load(_ provider: PostgresProvider) -> String? {
        KeychainManager.shared.loadPassword(
            kind: .postgresPassword, account: account(for: provider)
        )
    }

    @discardableResult
    static func save(_ provider: PostgresProvider, token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(provider) }
        return KeychainManager.shared.savePassword(
            kind: .postgresPassword, account: account(for: provider), secret: trimmed
        )
    }

    @discardableResult
    static func delete(_ provider: PostgresProvider) -> Bool {
        KeychainManager.shared.deletePassword(
            kind: .postgresPassword, account: account(for: provider)
        )
    }
}
