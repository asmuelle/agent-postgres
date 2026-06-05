import Foundation

// =============================================================================
// PgReadOnlyGuard — defense-in-depth check that an AI-issued SQL string is a
// single read-only statement before it ever reaches `pgExecute`.
//
// The on-device model is told to write read-only SQL, but instructions are not
// a security boundary. This guard is: it strips string literals, quoted
// identifiers, dollar-quoted bodies, and comments (so keywords hidden in data
// can't fool it), rejects multiple statements, and rejects any
// data-modifying keyword anywhere — which also catches data-modifying CTEs
// like `WITH x AS (DELETE FROM t ...) SELECT ...`.
//
// Pure string logic, no FFI dependency — exhaustively unit-tested.
// =============================================================================

enum PgReadOnlyGuard {
    enum Violation: Error, Equatable, CustomStringConvertible {
        case empty
        case multipleStatements
        case notReadOnlyStatement(String)
        case forbiddenKeyword(String)

        var description: String {
            switch self {
            case .empty:
                return "The statement is empty."
            case .multipleStatements:
                return "Only a single statement is allowed."
            case .notReadOnlyStatement(let kw):
                return "Statement must start with SELECT/WITH/VALUES/TABLE/SHOW/EXPLAIN (got \(kw))."
            case .forbiddenKeyword(let kw):
                return "Data-modifying keyword not allowed: \(kw)."
            }
        }
    }

    /// Statements permitted to lead a read-only query.
    private static let allowedLeading: Set<String> = [
        "SELECT", "WITH", "VALUES", "TABLE", "SHOW", "EXPLAIN",
    ]

    /// Keywords that perform (or can perform) writes / side effects. Scanned as
    /// whole tokens anywhere in the statement after literals are stripped.
    /// `ANALYZE` is here so `EXPLAIN ANALYZE` (which actually executes) is
    /// rejected; plain `EXPLAIN` is allowed.
    private static let forbiddenKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "TRUNCATE", "CREATE",
        "GRANT", "REVOKE", "COPY", "MERGE", "CALL", "DO", "VACUUM", "ANALYZE",
        "REINDEX", "REFRESH", "COMMENT", "SET", "RESET", "LOCK", "CLUSTER",
        "IMPORT", "PREPARE", "EXECUTE", "DEALLOCATE", "DECLARE", "FETCH",
        "MOVE", "CLOSE", "LISTEN", "NOTIFY", "UNLISTEN", "CHECKPOINT",
        "DISCARD", "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE",
        "START", "END", "ATTACH", "DETACH",
    ]

    /// Returns the trimmed statement if it is a single read-only statement;
    /// throws `Violation` otherwise.
    @discardableResult
    static func validate(_ sql: String) throws -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = stripLiteralsAndComments(sql)

        // Split on statement separators in the *sanitized* text so semicolons
        // inside strings/comments don't count. A single trailing ';' is fine.
        let statements = sanitized
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !statements.isEmpty else { throw Violation.empty }
        guard statements.count == 1 else { throw Violation.multipleStatements }

        let tokens = tokenize(statements[0])
        guard let leading = tokens.first else { throw Violation.empty }
        guard allowedLeading.contains(leading) else {
            throw Violation.notReadOnlyStatement(leading)
        }

        for token in tokens where forbiddenKeywords.contains(token) {
            throw Violation.forbiddenKeyword(token)
        }

        return trimmed
    }

    /// `true` when `validate` would succeed.
    static func isReadOnly(_ sql: String) -> Bool {
        (try? validate(sql)) != nil
    }

    // MARK: - Lexing helpers

    /// Replace the *contents* of string literals, quoted identifiers,
    /// dollar-quoted bodies, and comments with spaces, preserving overall
    /// length-ish structure so statement separators outside them survive.
    static func stripLiteralsAndComments(_ sql: String) -> String {
        var out = ""
        out.reserveCapacity(sql.count)
        let chars = Array(sql)
        var i = 0
        let n = chars.count

        while i < n {
            let c = chars[i]

            // Line comment: -- ... end-of-line
            if c == "-", i + 1 < n, chars[i + 1] == "-" {
                while i < n, chars[i] != "\n" { i += 1 }
                continue
            }

            // Block comment: /* ... */ (Postgres allows nesting)
            if c == "/", i + 1 < n, chars[i + 1] == "*" {
                var depth = 1
                i += 2
                while i < n, depth > 0 {
                    if chars[i] == "/", i + 1 < n, chars[i + 1] == "*" {
                        depth += 1; i += 2
                    } else if chars[i] == "*", i + 1 < n, chars[i + 1] == "/" {
                        depth -= 1; i += 2
                    } else {
                        i += 1
                    }
                }
                out.append(" ")
                continue
            }

            // Single-quoted string: '...'; '' is an escaped quote.
            if c == "'" {
                i += 1
                while i < n {
                    if chars[i] == "'" {
                        if i + 1 < n, chars[i + 1] == "'" { i += 2; continue }
                        i += 1; break
                    }
                    i += 1
                }
                out.append(" ")
                continue
            }

            // Double-quoted identifier: "..."; "" is an escaped quote.
            if c == "\"" {
                i += 1
                while i < n {
                    if chars[i] == "\"" {
                        if i + 1 < n, chars[i + 1] == "\"" { i += 2; continue }
                        i += 1; break
                    }
                    i += 1
                }
                out.append(" ")
                continue
            }

            // Dollar-quoted string: $tag$ ... $tag$ (tag may be empty).
            if c == "$", let tag = dollarTag(chars, at: i) {
                i += tag.count // advance past opening $tag$
                while i < n {
                    if chars[i] == "$", matchesTag(chars, at: i, tag: tag) {
                        i += tag.count
                        break
                    }
                    i += 1
                }
                out.append(" ")
                continue
            }

            out.append(c)
            i += 1
        }
        return out
    }

    /// If a dollar-quote opener starts at `idx`, return its full delimiter
    /// (e.g. `$$` or `$body$`) as an array slice's string; otherwise `nil`.
    private static func dollarTag(_ chars: [Character], at idx: Int) -> [Character]? {
        guard chars[idx] == "$" else { return nil }
        var j = idx + 1
        var tagBody: [Character] = []
        while j < chars.count, chars[j] != "$" {
            let ch = chars[j]
            // Tag chars are letters, digits, or underscore; anything else means
            // this isn't a dollar-quote opener.
            guard ch == "_" || ch.isLetter || ch.isNumber else { return nil }
            tagBody.append(ch)
            j += 1
        }
        guard j < chars.count, chars[j] == "$" else { return nil }
        return ["$"] + tagBody + ["$"]
    }

    private static func matchesTag(_ chars: [Character], at idx: Int, tag: [Character]) -> Bool {
        guard idx + tag.count <= chars.count else { return false }
        for k in 0..<tag.count where chars[idx + k] != tag[k] { return false }
        return true
    }

    /// Split into uppercased word tokens (letters, digits, underscore).
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in s {
            if ch == "_" || ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                tokens.append(current.uppercased())
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current.uppercased()) }
        return tokens
    }
}
