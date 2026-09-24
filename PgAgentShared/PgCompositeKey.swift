import Foundation

// =============================================================================
// PgCompositeKey — the one builder/parser for dotted composite keys
// (`db.schema.table`) used by PgSchemaStore caches and the tree views'
// expansion sets.
//
// Built on PgNodeID's component escaping (`\` → `\\`, `.` → `\.`), so a
// database `my.app` with schema `s` and a database `my` with schema `app.s`
// get different keys, and a prefix built from a key's leading components
// matches exactly the keys nested under them. Plain names encode exactly as
// the old `"\(a).\(b)"` interpolation did.
//
// Platform-neutral: compiled into both the macOS and iOS targets.
// =============================================================================
enum PgCompositeKey {
    /// Escaped `components` joined with `.`.
    static func make(_ components: String...) -> String {
        make(components)
    }

    static func make(_ components: [String]) -> String {
        components.map(PgNodeID.escape).joined(separator: ".")
    }

    /// Unescaped components of a key built by `make`.
    static func parse(_ key: String) -> [String] {
        PgNodeID.parse("k:" + key)?.components ?? [key]
    }

    /// Prefix shared by every key whose leading components are `components`
    /// (and that has at least one more component).
    static func prefix(_ components: String...) -> String {
        make(components) + "."
    }

    /// `database.schema` — schema-contents cache / schema expansion key.
    static func schema(database: String, schema: String) -> String {
        make(database, schema)
    }

    /// `database.schema.table` — columns / meta / foreign-key cache key.
    static func table(database: String, schema: String, table: String) -> String {
        make(database, schema, table)
    }
}
