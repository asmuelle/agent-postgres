import Foundation

// =============================================================================
// PostgresStatementClassifier — decides whether a SQL string is read-only,
// for enforcing per-connection read-only mode at the bridge layer.
//
// This is a security boundary shared by macOS and iOS, so the bias is
// deliberately conservative: a false BLOCK (refusing an exotic read) is
// acceptable; a false ALLOW (letting a write through) is not. Documented
// consequences of that bias:
//
//   * The whole text is scanned for data-modifying keywords as standalone
//     word tokens (after literals/comments are stripped), not just CTE
//     bodies. `SELECT "update" FROM t` is fine (quoted), but an unquoted
//     column literally named `update` false-blocks. Acceptable.
//   * `SELECT ... FOR UPDATE` is blocked (row locks are a write-adjacent
//     side effect) via the UPDATE token. Acceptable.
//   * `EXPLAIN ANALYZE` is blocked because ANALYZE executes the explained
//     statement, even when the statement starts with SELECT.
//   * Multi-statement scripts: the sanitized text is split on top-level
//     semicolons and EVERY statement must classify read-only. Scripts that
//     lead with BEGIN/SET are blocked (not in the allowed leading set) —
//     conservative, by design.
//   * Statement keywords hidden in string literals, quoted identifiers,
//     dollar-quoted bodies, or comments are ignored — the lexer strips
//     them first (nested block comments handled).
//
// The lexing helpers here are also used by the macOS-only `PgReadOnlyGuard`
// (AI-issued SQL screening), which layers stricter single-statement rules
// on top. Keep the lexer changes in sync with that guard's expectations.
// =============================================================================

enum PostgresStatementClassifier {
    /// Statements permitted to lead a read-only query.
    private static let allowedLeading: Set<String> = [
        "SELECT", "EXPLAIN", "SHOW", "VALUES", "TABLE", "FETCH", "WITH",
    ]

    /// Keywords that perform (or can perform) data or schema modification.
    /// Found anywhere as a standalone token (post-strip) → not read-only.
    private static let writeKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "MERGE",
        "CREATE", "ALTER", "DROP", "TRUNCATE",
        "GRANT", "REVOKE", "VACUUM", "REINDEX", "CLUSTER", "REFRESH",
        "CALL", "DO", "COPY", "LOCK", "IMPORT", "COMMENT", "SECURITY",
        "ANALYZE",
    ]

    /// Built-in functions with observable side effects. User-defined
    /// functions are protected by the server-side `default_transaction_read_only`
    /// setting applied by the bridge; this list closes the obvious local false
    /// allows before a statement reaches the server.
    private static let sideEffectingFunctions: Set<String> = [
        "NEXTVAL", "SETVAL", "SET_CONFIG", "PG_NOTIFY",
        "PG_ADVISORY_LOCK", "PG_ADVISORY_XACT_LOCK", "PG_ADVISORY_UNLOCK",
        "PG_ADVISORY_UNLOCK_ALL", "PG_CANCEL_BACKEND", "PG_TERMINATE_BACKEND",
        "PG_RELOAD_CONF", "PG_ROTATE_LOGFILE", "LO_CREATE", "LO_UNLINK",
        "DBLINK", "DBLINK_EXEC",
    ]

    /// `true` when every top-level statement in `sql` is read-only under
    /// the conservative rules above. Empty/whitespace-only input returns
    /// `true` — nothing executable means nothing can write.
    static func isReadOnly(_ sql: String) -> Bool {
        let sanitized = stripLiteralsAndComments(sql)

        // Any write keyword anywhere (including CTE bodies like
        // `WITH x AS (DELETE ...) SELECT ...`) fails the whole text.
        for token in tokenize(sanitized)
        where writeKeywords.contains(token) || sideEffectingFunctions.contains(token)
        {
            return false
        }

        // Semicolons inside strings/comments were stripped above, so this
        // split sees only real statement separators. Every statement must
        // lead with an allowed read keyword.
        let statements = sanitized
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for statement in statements {
            guard let leading = tokenize(statement).first,
                  allowedLeading.contains(leading)
            else { return false }
        }
        return true
    }

    /// Redact literal and comment contents before persisting SQL in the audit
    /// log. The returned SQL keeps its statement shape and keywords while
    /// removing string literals, quoted identifiers, dollar-quoted bodies, and
    /// comments that may contain credentials or personal data.
    static func redactedForAudit(_ sql: String) -> String {
        let withoutQuotedData = stripLiteralsAndComments(sql)
        // Numeric constants can also carry identifiers, account numbers, or
        // other personal data. Keep the SQL shape while replacing standalone
        // numeric tokens; digits embedded in identifiers remain untouched.
        return withoutQuotedData.replacingOccurrences(
            of: #"(?<![A-Za-z_])[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"#,
            with: "?",
            options: .regularExpression
        )
    }

    // MARK: - Lexing helpers

    /// Replace the *contents* of string literals, quoted identifiers,
    /// dollar-quoted bodies, and comments with spaces, so keywords hidden
    /// in data can't fool the classifier and separators outside them
    /// survive. Postgres-aware: nested `/* */`, doubled `''`/`""` escapes,
    /// `$tag$ ... $tag$` bodies.
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
    /// (e.g. `$$` or `$body$`); otherwise `nil`.
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
