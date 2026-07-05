import Foundation

// =============================================================================
// Paste-to-connect parser (roadmap 2.1).
//
// Accepts the two connection-string shapes users actually paste:
//   1. URL form:  postgres://user:p%40ss@host:5432/dbname?sslmode=require
//                 postgresql://user@[2001:db8::1]:6432/app
//   2. DSN form:  host=db.example.com port=5432 dbname=app user=me password='p w'
//
// The extracted password is kept SEPARATE from the profile fields so callers
// stage it into the keychain — it must never land in a persisted profile.
// Platform-neutral: compiled into both the macOS and iOS apps.
// =============================================================================

enum PostgresConnectionURLError: LocalizedError, Equatable {
    case emptyInput
    case unsupportedScheme(String)
    case malformedURL
    case notAConnectionString
    case invalidPort(String)
    case unknownSslMode(String)
    case malformedKeywordPair(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "The connection string is empty."
        case .unsupportedScheme(let scheme):
            return "Unsupported URL scheme “\(scheme)” — expected postgres:// or postgresql://."
        case .malformedURL:
            return "The text looks like a Postgres URL but could not be parsed. Check for unescaped special characters (encode them with %XX)."
        case .notAConnectionString:
            return "Not a recognizable Postgres connection string. Paste a postgres:// URL or a keyword DSN like “host=… dbname=… user=…”."
        case .invalidPort(let port):
            return "Invalid port “\(port)” — expected a number between 1 and 65535."
        case .unknownSslMode(let mode):
            return "Unknown sslmode “\(mode)” — expected disable, allow, prefer, require, verify-ca, or verify-full."
        case .malformedKeywordPair(let pair):
            return "Malformed keyword/value pair “\(pair)” — expected key=value (quote values containing spaces with single quotes)."
        }
    }
}

/// Value result of parsing a connection URL or DSN. Convertible to a
/// `PostgresProfile` via `makeProfile(named:)`; the password stays out of
/// the profile so callers can store it in the keychain.
struct PostgresConnectionURL: Equatable, Sendable {
    var host: String
    var port: UInt16
    var database: String
    /// Empty when the string didn't specify a user — the connection form
    /// leaves the field blank for the user to fill in.
    var user: String
    /// Kept separate from profile fields on purpose — see file header.
    var password: String?
    /// `nil` when the string didn't specify an sslmode; callers apply
    /// their own default (the profile default is `.require`).
    var tls: PostgresTlsMode?
    var applicationName: String?
    var connectTimeoutSecs: UInt64?

    static let defaultPort: UInt16 = 5432

    // MARK: - Entry point

    static func parse(_ input: String) throws -> PostgresConnectionURL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PostgresConnectionURLError.emptyInput }

        if let schemeRange = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<schemeRange.lowerBound]).lowercased()
            guard scheme == "postgres" || scheme == "postgresql" else {
                throw PostgresConnectionURLError.unsupportedScheme(scheme)
            }
            return try parseURLForm(trimmed)
        }

        // DSN form needs at least one key=value pair to be plausible.
        if trimmed.contains("=") {
            return try parseDSNForm(trimmed)
        }
        throw PostgresConnectionURLError.notAConnectionString
    }

    /// Cheap check for "does the clipboard plausibly hold a connection
    /// string" — used for the paste hint without throwing.
    static func plausible(_ input: String) -> Bool {
        (try? parse(input)) != nil
    }

    // MARK: - URL form

    private static func parseURLForm(_ text: String) throws -> PostgresConnectionURL {
        guard let components = URLComponents(string: text) else {
            throw PostgresConnectionURLError.malformedURL
        }

        // URLComponents percent-decodes user/password/host for us.
        let user = components.user ?? ""
        let password = components.password

        var host = components.host ?? ""
        // Depending on the Foundation version, `host` may keep the IPv6
        // brackets ("[::1]") — normalize to the bare address.
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.isEmpty { host = "127.0.0.1" }

        var port = defaultPort
        if let p = components.port {
            guard let value = UInt16(exactly: p), value > 0 else {
                throw PostgresConnectionURLError.invalidPort(String(p))
            }
            port = value
        }

        // Path is "/dbname"; empty path falls back to the user name
        // (libpq behavior), then "postgres".
        let rawPath = components.path
        var database = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
        if database.isEmpty {
            database = user.isEmpty ? "postgres" : user
        }

        var result = PostgresConnectionURL(
            host: host, port: port, database: database,
            user: user, password: password,
            tls: nil, applicationName: nil, connectTimeoutSecs: nil
        )
        for item in components.queryItems ?? [] {
            try result.applyParameter(key: item.name, value: item.value ?? "")
        }
        return result
    }

    // MARK: - DSN (keyword=value) form

    private static func parseDSNForm(_ text: String) throws -> PostgresConnectionURL {
        var result = PostgresConnectionURL(
            host: "127.0.0.1", port: defaultPort, database: "",
            user: "", password: nil,
            tls: nil, applicationName: nil, connectTimeoutSecs: nil
        )
        for (key, value) in try tokenizeDSN(text) {
            try result.applyParameter(key: key, value: value)
        }
        if result.database.isEmpty {
            result.database = result.user.isEmpty ? "postgres" : result.user
        }
        return result
    }

    /// Tokenize libpq keyword/value pairs: whitespace-separated `key=value`,
    /// values optionally single-quoted with `\'` and `\\` escapes.
    private static func tokenizeDSN(_ text: String) throws -> [(String, String)] {
        var pairs: [(String, String)] = []
        var index = text.startIndex

        func skipWhitespace() {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
        }

        while true {
            skipWhitespace()
            guard index < text.endIndex else { break }

            // Key: run up to '='.
            let keyStart = index
            while index < text.endIndex, text[index] != "=", !text[index].isWhitespace {
                index = text.index(after: index)
            }
            let key = String(text[keyStart..<index])
            skipWhitespace()
            guard index < text.endIndex, text[index] == "=", !key.isEmpty else {
                throw PostgresConnectionURLError.malformedKeywordPair(key.isEmpty ? String(text[keyStart...]) : key)
            }
            index = text.index(after: index) // consume '='
            skipWhitespace()

            // Value: quoted or bare.
            var value = ""
            if index < text.endIndex, text[index] == "'" {
                index = text.index(after: index)
                var closed = false
                while index < text.endIndex {
                    let ch = text[index]
                    if ch == "\\", text.index(after: index) < text.endIndex {
                        index = text.index(after: index)
                        value.append(text[index])
                    } else if ch == "'" {
                        closed = true
                        index = text.index(after: index)
                        break
                    } else {
                        value.append(ch)
                    }
                    index = text.index(after: index)
                }
                guard closed else {
                    throw PostgresConnectionURLError.malformedKeywordPair("\(key)='\(value)")
                }
            } else {
                while index < text.endIndex, !text[index].isWhitespace {
                    let ch = text[index]
                    if ch == "\\", text.index(after: index) < text.endIndex {
                        index = text.index(after: index)
                        value.append(text[index])
                    } else {
                        value.append(ch)
                    }
                    index = text.index(after: index)
                }
            }
            pairs.append((key.lowercased(), value))
        }

        guard !pairs.isEmpty else { throw PostgresConnectionURLError.notAConnectionString }
        return pairs
    }

    // MARK: - Shared parameter application

    private mutating func applyParameter(key: String, value: String) throws {
        switch key.lowercased() {
        case "host", "hostaddr":
            // DSN IPv6 addresses may be written bare or bracketed.
            var h = value
            if h.hasPrefix("["), h.hasSuffix("]") {
                h = String(h.dropFirst().dropLast())
            }
            if !h.isEmpty { host = h }
        case "port":
            guard let p = UInt16(value), p > 0 else {
                throw PostgresConnectionURLError.invalidPort(value)
            }
            port = p
        case "dbname":
            database = value
        case "user":
            user = value
        case "password":
            password = value.isEmpty ? nil : value
        case "sslmode":
            tls = try Self.tlsMode(fromSslMode: value)
        case "application_name":
            applicationName = value.isEmpty ? nil : value
        case "connect_timeout":
            connectTimeoutSecs = UInt64(value)
        default:
            // Unknown/unsupported parameters (options, channel_binding,
            // target_session_attrs, …) are ignored rather than fatal —
            // provider URLs carry all sorts of extras.
            break
        }
    }

    /// Map libpq sslmode strings onto the profile's TLS setting.
    /// `verify-ca` maps UP to `.verifyFull` rather than down to `.require`:
    /// the pasted string asked for certificate verification, and silently
    /// dropping it would be a security downgrade.
    static func tlsMode(fromSslMode raw: String) throws -> PostgresTlsMode {
        switch raw.lowercased() {
        case "disable":             return .disable
        case "allow", "prefer":     return .prefer
        case "require":             return .require
        case "verify-ca", "verify-full", "verify_ca", "verify_full":
            return .verifyFull
        default:
            throw PostgresConnectionURLError.unknownSslMode(raw)
        }
    }

    // MARK: - Profile conversion

    /// Suggested display name: "dbname @ host".
    var suggestedName: String {
        database.isEmpty ? host : "\(database) @ \(host)"
    }

    /// Build a profile from the parsed fields. The password is deliberately
    /// NOT carried over — store it in the keychain under
    /// `profile.keychainAccount` instead.
    func makeProfile(named name: String? = nil) -> PostgresProfile {
        PostgresProfile(
            name: name ?? suggestedName,
            host: host,
            port: port,
            database: database,
            user: user.isEmpty ? "postgres" : user,
            auth: .keychain,
            tls: tls ?? .require,
            connectTimeoutSecs: connectTimeoutSecs ?? 10
        )
    }
}
