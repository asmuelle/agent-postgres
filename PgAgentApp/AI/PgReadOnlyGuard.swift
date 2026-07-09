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
//
// Lexing (literal/comment stripping, tokenizing) is shared with
// `PostgresStatementClassifier` (PgAgentShared), which enforces
// per-connection read-only mode at the bridge layer. This guard is
// stricter on top: single statement only, and a wider forbidden-keyword
// set (SET/BEGIN/PREPARE/... are refused outright for AI-issued SQL).
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
        // Known side-effecting functions; arbitrary user-defined functions
        // are additionally contained by the server-side read-only setting.
        "NEXTVAL", "SETVAL", "SET_CONFIG", "PG_NOTIFY",
        "PG_ADVISORY_LOCK", "PG_ADVISORY_XACT_LOCK", "PG_ADVISORY_UNLOCK",
        "PG_ADVISORY_UNLOCK_ALL", "PG_CANCEL_BACKEND", "PG_TERMINATE_BACKEND",
        "PG_RELOAD_CONF", "PG_ROTATE_LOGFILE", "LO_CREATE", "LO_UNLINK",
        "DBLINK", "DBLINK_EXEC",
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

    // MARK: - Lexing helpers (delegated to the shared classifier)

    /// Replace the *contents* of string literals, quoted identifiers,
    /// dollar-quoted bodies, and comments with spaces, preserving overall
    /// length-ish structure so statement separators outside them survive.
    static func stripLiteralsAndComments(_ sql: String) -> String {
        PostgresStatementClassifier.stripLiteralsAndComments(sql)
    }

    /// Split into uppercased word tokens (letters, digits, underscore).
    static func tokenize(_ s: String) -> [String] {
        PostgresStatementClassifier.tokenize(s)
    }
}
