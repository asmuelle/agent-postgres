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
