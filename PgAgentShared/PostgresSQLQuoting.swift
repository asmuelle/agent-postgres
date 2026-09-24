import Foundation

// =============================================================================
// PostgresSQLQuoting — platform-neutral identifier/literal quoting helpers
// shared by the macOS and iOS targets. Kept free of AppKit/UIKit so both
// PgAgentApp (macOS) and PgAgentMobile (iOS) can compile them.
// =============================================================================

/// Quote a Postgres identifier defensively — mixed-case and
/// reserved-word identifiers silently target the wrong object when
/// unquoted.
func pgQuoteIdent(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

/// Escape a value for inclusion in a single-quoted SQL literal.
func pgQuoteLiteral(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
}

/// Postgres keywords that can't appear as a bare column reference: the
/// "reserved" and "reserved (can be function or type)" categories of the
/// SQL Key Words appendix. `user`, `order`, `left`, … must be quoted.
let pgReservedKeywords: Set<String> = [
    // reserved
    "ALL", "ANALYSE", "ANALYZE", "AND", "ANY", "ARRAY", "AS", "ASC",
    "ASYMMETRIC", "BOTH", "CASE", "CAST", "CHECK", "COLLATE", "COLUMN",
    "CONSTRAINT", "CREATE", "CURRENT_CATALOG", "CURRENT_DATE", "CURRENT_ROLE",
    "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER", "DEFAULT",
    "DEFERRABLE", "DESC", "DISTINCT", "DO", "ELSE", "END", "EXCEPT", "FALSE",
    "FETCH", "FOR", "FOREIGN", "FROM", "GRANT", "GROUP", "HAVING", "IN",
    "INITIALLY", "INTERSECT", "INTO", "LATERAL", "LEADING", "LIMIT",
    "LOCALTIME", "LOCALTIMESTAMP", "NOT", "NULL", "OFFSET", "ON", "ONLY", "OR",
    "ORDER", "PLACING", "PRIMARY", "REFERENCES", "RETURNING", "SELECT",
    "SESSION_USER", "SOME", "SYMMETRIC", "SYSTEM_USER", "TABLE", "THEN", "TO",
    "TRAILING", "TRUE", "UNION", "UNIQUE", "USER", "USING", "VARIADIC", "WHEN",
    "WHERE", "WINDOW", "WITH",
    // reserved (can be function or type)
    "AUTHORIZATION", "BINARY", "COLLATION", "CONCURRENTLY", "CROSS",
    "CURRENT_SCHEMA", "FREEZE", "FULL", "ILIKE", "INNER", "IS", "ISNULL",
    "JOIN", "LEFT", "LIKE", "NATURAL", "NOTNULL", "OUTER", "OVERLAPS", "RIGHT",
    "SIMILAR", "TABLESAMPLE", "VERBOSE",
]

/// Identifier for SQL text, quoted only when it has to be: anything
/// outside the unquoted-identifier grammar (`[a-z_][a-z0-9_$]*` —
/// Postgres folds unquoted names to lower case) and any reserved
/// keyword. Deliberately self-contained (no dependency on the completion
/// vocabulary): the iOS logic-test target compiles this file on its own.
func pgQuoteIdentIfNeeded(_ ident: String) -> String {
    guard let first = ident.unicodeScalars.first else { return pgQuoteIdent(ident) }
    let firstOK = (first >= "a" && first <= "z") || first == "_"
    let restOK = ident.unicodeScalars.dropFirst().allSatisfy {
        ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "_" || $0 == "$"
    }
    guard firstOK, restOK else { return pgQuoteIdent(ident) }
    return pgReservedKeywords.contains(ident.uppercased()) ? pgQuoteIdent(ident) : ident
}
