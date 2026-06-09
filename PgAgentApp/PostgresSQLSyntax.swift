import AppKit

// =============================================================================
// PostgresSQLSyntax — pure SQL lexing helpers for the editor.
//
// Two responsibilities, both side-effect-free except `highlight`, which only
// mutates the passed text storage:
//   1. Keyword / type / function vocabularies for schema-aware completion.
//   2. `highlight(_:baseFont:)` — apply syntax colors to an NSTextStorage.
//
// Colors are semantic system colors so they adapt to light/dark automatically.
// =============================================================================

enum PostgresSQLSyntax {
    /// Reserved words that get keyword coloring and are offered in completion.
    static let keywords: [String] = [
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
        "DELETE", "CREATE", "TABLE", "VIEW", "MATERIALIZED", "INDEX", "DROP",
        "ALTER", "ADD", "COLUMN", "JOIN", "INNER", "LEFT", "RIGHT", "FULL",
        "OUTER", "CROSS", "NATURAL", "LATERAL", "ON", "USING", "GROUP", "BY",
        "ORDER", "HAVING", "LIMIT", "OFFSET", "FETCH", "FIRST", "LAST", "NEXT",
        "ROWS", "ONLY", "DISTINCT", "AS", "AND", "OR", "NOT", "NULL", "IS",
        "IN", "EXISTS", "BETWEEN", "LIKE", "ILIKE", "SIMILAR", "CASE", "WHEN",
        "THEN", "ELSE", "END", "UNION", "ALL", "INTERSECT", "EXCEPT", "WITH",
        "RECURSIVE", "RETURNING", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
        "UNIQUE", "CHECK", "DEFAULT", "CONSTRAINT", "CASCADE", "RESTRICT",
        "GRANT", "REVOKE", "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION",
        "SAVEPOINT", "ANALYZE", "EXPLAIN", "VACUUM", "REINDEX", "TRUNCATE",
        "COPY", "ASC", "DESC", "NULLS", "OVER", "PARTITION", "WINDOW", "FILTER",
        "TEMP", "TEMPORARY", "IF", "SCHEMA", "DATABASE", "SEQUENCE", "FUNCTION",
        "PROCEDURE", "TRIGGER", "TYPE", "DOMAIN", "EXTENSION", "ROLE", "USER",
        "TABLESPACE", "COMMENT", "RESET", "SHOW", "DECLARE", "CURSOR", "FOR",
        "LOOP", "CALL", "DO", "LANGUAGE", "POLICY", "ENABLE", "DISABLE", "ROW",
        "LEVEL", "SECURITY", "REFRESH", "CONCURRENTLY", "GENERATED", "ALWAYS",
        "IDENTITY", "INTERVAL", "AT", "ZONE", "CAST", "COLLATE",
    ]

    /// Common built-in types offered in completion (not separately colored).
    static let types: [String] = [
        "int", "integer", "int4", "bigint", "int8", "smallint", "int2",
        "serial", "bigserial", "numeric", "decimal", "real", "float8", "float4",
        "boolean", "bool", "text", "varchar", "char",
        "date", "time", "timestamp", "timestamptz", "interval", "json", "jsonb",
        "uuid", "bytea", "inet", "cidr", "macaddr", "money", "tsvector",
    ]

    /// Common functions offered in completion.
    static let functions: [String] = [
        "count", "sum", "avg", "min", "max", "coalesce", "nullif", "greatest",
        "least", "now", "current_date", "current_timestamp", "current_user",
        "lower", "upper", "initcap", "length", "char_length", "substring",
        "left", "right", "trim", "ltrim", "rtrim", "lpad", "rpad", "replace",
        "concat", "concat_ws", "split_part", "position", "strpos", "format",
        "array_agg", "string_agg", "unnest", "array_length", "cardinality",
        "jsonb_build_object", "json_build_object", "jsonb_agg", "json_agg",
        "jsonb_array_elements", "row_number", "rank", "dense_rank", "ntile",
        "lag", "lead", "first_value", "last_value", "generate_series",
        "to_char", "to_date", "to_timestamp", "to_number", "extract",
        "date_trunc", "date_part", "age", "round", "ceil", "floor",
        "abs", "mod", "power", "sqrt", "random", "md5", "encode", "decode",
        "regexp_replace", "regexp_matches", "to_regclass",
    ]

    /// Everything offered to the completion engine besides live schema
    /// identifiers — keywords are upper-cased (SQL convention), the rest
    /// lower-cased.
    static var completionVocabulary: [String] {
        keywords + types + functions
    }

    private static let keywordSet: Set<String> = Set(keywords.map { $0.uppercased() })

    // MARK: - Highlighting

    // Compiled once, reused for every highlight pass (this runs on each
    // keystroke, so per-call recompilation would stutter on large queries).
    // Patterns are static literals → `try!` is safe.
    private static let identifierRegex = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*")
    private static let numberRegex = try! NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b")
    private static let stringRegex = try! NSRegularExpression(pattern: "'(?:[^']|'')*'")
    private static let lineCommentRegex = try! NSRegularExpression(pattern: "--[^\\n]*")
    private static let blockCommentRegex = try! NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/")

    static func highlight(_ storage: NSTextStorage, baseFont: NSFont) {
        let text = storage.string
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        guard full.length > 0 else { return }

        storage.beginEditing()
        storage.setAttributes(
            [.font: baseFont, .foregroundColor: NSColor.textColor],
            range: full
        )

        // Keywords (whole word) — colored first so the string/comment passes
        // below can override a keyword that lives inside a literal or comment.
        identifierRegex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let r = match?.range else { return }
            if keywordSet.contains(nsText.substring(with: r).uppercased()) {
                storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: r)
            }
        }

        // Numbers, then strings, then comments (later passes win).
        apply(numberRegex, NSColor.systemOrange, storage, text, full)
        apply(stringRegex, NSColor.systemRed, storage, text, full)
        apply(lineCommentRegex, NSColor.systemGray, storage, text, full)
        apply(blockCommentRegex, NSColor.systemGray, storage, text, full)

        storage.endEditing()
    }

    private static func apply(
        _ regex: NSRegularExpression,
        _ color: NSColor,
        _ storage: NSTextStorage,
        _ text: String,
        _ range: NSRange
    ) {
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            if let r = match?.range {
                storage.addAttribute(.foregroundColor, value: color, range: r)
            }
        }
    }
}
