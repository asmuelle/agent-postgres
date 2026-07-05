import Foundation

// =============================================================================
// Parsers for the two local libpq config files offered for import on macOS
// (roadmap 2.1): ~/.pgpass and ~/.pg_service.conf. Pure text → value structs;
// no file I/O here so the parsers are trivially unit-testable and platform
// neutral. The UI layer (PgAgentApp) reads the files and stores passwords in
// the keychain.
// =============================================================================

enum PostgresLocalConfig {

    // MARK: - ~/.pgpass

    /// One concrete credential line from ~/.pgpass
    /// (`hostname:port:database:username:password`).
    struct PgPassEntry: Equatable, Sendable, Identifiable {
        var host: String
        var port: UInt16
        var database: String
        var user: String
        var password: String

        var id: String { "\(user)@\(host):\(port)/\(database)" }
    }

    /// Parse ~/.pgpass content. Rules honored:
    /// - `#` comment lines and blank lines are skipped.
    /// - `\` escapes `:` and `\` inside fields.
    /// - Only concrete entries are importable: lines whose host or user is
    ///   `*` are skipped (a profile needs both). A `*` port defaults to
    ///   5432 and a `*` database defaults to `postgres` — those wildcards
    ///   are ubiquitous in real files and have safe concrete defaults.
    /// - Lines with the wrong field count or an empty password are skipped.
    static func parsePgPass(_ text: String) -> [PgPassEntry] {
        var entries: [PgPassEntry] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let fields = splitEscaped(line, separator: ":")
            guard fields.count == 5 else { continue }

            let host = fields[0]
            let portField = fields[1]
            let database = fields[2]
            let user = fields[3]
            let password = fields[4]

            // Pure-wildcard host/user lines can't become a concrete profile.
            guard host != "*", !host.isEmpty, user != "*", !user.isEmpty,
                  !password.isEmpty
            else { continue }

            let port: UInt16
            if portField == "*" || portField.isEmpty {
                port = 5432
            } else if let p = UInt16(portField), p > 0 {
                port = p
            } else {
                continue // malformed port — skip the line
            }

            entries.append(PgPassEntry(
                host: host,
                port: port,
                database: (database == "*" || database.isEmpty) ? "postgres" : database,
                user: user,
                password: password
            ))
        }
        return entries
    }

    /// Split on `separator` honoring backslash escapes (`\:` and `\\`).
    private static func splitEscaped(_ line: String, separator: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch == "\\", line.index(after: index) < line.endIndex {
                index = line.index(after: index)
                current.append(line[index])
            } else if ch == separator {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            index = line.index(after: index)
        }
        fields.append(current)
        return fields
    }

    // MARK: - ~/.pg_service.conf

    /// One `[service]` section from ~/.pg_service.conf.
    struct PgServiceEntry: Equatable, Sendable, Identifiable {
        var name: String
        var host: String
        var port: UInt16
        var database: String
        var user: String
        var password: String?
        /// Parsed from `sslmode=`; `nil` when absent or unrecognized
        /// (unknown modes shouldn't sink the whole import).
        var tls: PostgresTlsMode?

        var id: String { name }
    }

    /// Parse ~/.pg_service.conf content: INI sections, `key=value` lines,
    /// `#` comments. Sections without a concrete `host` are skipped; port
    /// defaults to 5432, dbname to `postgres`, user to `postgres`.
    static func parsePgServiceConf(_ text: String) -> [PgServiceEntry] {
        var entries: [PgServiceEntry] = []
        var currentName: String?
        var params: [String: String] = [:]

        func flush() {
            defer { params = [:] }
            guard let name = currentName,
                  let host = params["host"], !host.isEmpty
            else { return }
            let port = params["port"].flatMap { UInt16($0) }.flatMap { $0 > 0 ? $0 : nil } ?? 5432
            entries.append(PgServiceEntry(
                name: name,
                host: host,
                port: port,
                database: params["dbname"] ?? "postgres",
                user: params["user"] ?? "postgres",
                password: params["password"].flatMap { $0.isEmpty ? nil : $0 },
                tls: params["sslmode"].flatMap { try? PostgresConnectionURL.tlsMode(fromSslMode: $0) }
            ))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                flush()
                currentName = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard currentName != nil,
                  let eq = line.firstIndex(of: "=")
            else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            params[key] = value
        }
        flush()
        return entries
    }
}
