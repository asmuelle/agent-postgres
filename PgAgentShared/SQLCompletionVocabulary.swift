import Foundation

// =============================================================================
// SQLCompletionVocabulary — the static SQL vocabulary (keywords, common
// types, common functions) shared by the syntax highlighter (macOS) and the
// schema-aware completion engine (platform-neutral).
//
// Single source of truth: `PostgresSQLSyntax` (macOS) forwards to these
// arrays for highlighting, and `SQLCompletionEngine` uses them for keyword /
// function candidates and for deciding when an identifier needs quoting.
// =============================================================================

enum SQLCompletionVocabulary {
    /// Reserved words offered in completion (uppercased on insert) and used
    /// as the "quote this identifier" denylist.
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
        // PL/pgSQL & routine-definition vocabulary — so function bodies in the
        // routine editor (and dollar-quoted bodies in query tabs) highlight.
        "RETURN", "RETURNS", "RAISE", "EXCEPTION", "NOTICE", "WARNING", "DEBUG",
        "INFO", "LOG", "PERFORM", "EXECUTE", "ELSIF", "ELSEIF", "WHILE",
        "FOREACH", "EXIT", "CONTINUE", "GET", "DIAGNOSTICS", "STACKED", "FOUND",
        "ROWTYPE", "CONSTANT", "ALIAS", "OUT", "INOUT", "VARIADIC", "STRICT",
        "VOLATILE", "STABLE", "IMMUTABLE", "PARALLEL", "SAFE", "RESTRICTED",
        "UNSAFE", "LEAKPROOF", "COST", "SUPPORT", "DEFINER", "INVOKER",
        "EXTERNAL", "SETOF", "INSTEAD", "ASSERT", "REPLACE", "SLICE", "REVERSE",
        "QUERY", "CALLED", "INPUT", "OF",
    ]

    /// Common built-in types offered in completion (after `::` casts).
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

    /// Uppercased keyword set — used both to decide whether a bare
    /// identifier in the alias scanner is really an alias, and whether a
    /// completed identifier must be quoted to avoid parsing as a keyword.
    static let keywordSet: Set<String> = Set(keywords.map { $0.uppercased() })

    /// `true` when `name` can be inserted into SQL unquoted: it matches the
    /// unquoted-identifier grammar (`[a-z_][a-z0-9_$]*`) and is not a
    /// keyword. Postgres folds unquoted identifiers to lowercase, so any
    /// uppercase character forces quoting.
    static func needsQuoting(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return true }
        let firstOK = (first >= "a" && first <= "z") || first == "_"
        guard firstOK else { return true }
        for scalar in name.unicodeScalars.dropFirst() {
            let ok = (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "_" || scalar == "$"
            if !ok { return true }
        }
        return keywordSet.contains(name.uppercased())
    }

    /// Identifier ready for insertion into SQL — quoted iff needed.
    static func quoteIfNeeded(_ name: String) -> String {
        needsQuoting(name) ? pgQuoteIdent(name) : name
    }
}
