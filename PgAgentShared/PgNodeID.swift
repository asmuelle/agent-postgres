import Foundation

// =============================================================================
// PgNodeID — the one encoder/parser for schema-tree node ids.
//
// Ids look like `kind:component.component…` (`rel:appdb.public.users`), but
// every component is escaped — `\` → `\\`, `.` → `\.` — so a database named
// `my.app` or a table named `v1.2` can't shift the component boundaries.
// Plain names (no dots, no backslashes) encode exactly as before, so ids of
// ordinary objects are unchanged.
//
// Node ids are never persisted (selection and expansion state are in-memory
// `@State`), so there is nothing to migrate; the parser nevertheless accepts
// the old unescaped form (surplus components fold back into the trailing
// name, the routine signature may be glued onto the name) so hand-built ids
// in tests and older call sites still resolve.
//
// Platform-neutral: compiled into both the macOS and iOS targets.
// =============================================================================

/// Resolved identity of a tree node.
struct PgNodeTarget: Hashable, Sendable {
    let database: String
    let schema: String
    /// Parent table for table-scoped children (columns, keys,
    /// constraints, triggers); `nil` otherwise.
    let table: String?
    /// Bare object name (never a display label).
    let name: String
}

enum PgNodeID {
    /// Id prefixes, one per node kind. Raw values are the on-the-wire
    /// prefixes other code matches with `hasPrefix("col:")` etc.
    enum Prefix: String, Sendable {
        case database = "db"
        case schema
        case category = "cat"
        case relation = "rel"
        case sequence = "seq"
        case routine = "fn"
        case objectType = "type"
        case column = "col"
        case key
        case constraint = "const"
        case trigger = "trig"
        case language = "lang"
        case role
        case tablespace = "tspace"
    }

    private static let separator: Unicode.Scalar = "."
    private static let escapeChar: Unicode.Scalar = "\\"

    // MARK: - Encoding

    /// `prefix:` followed by the escaped components joined with `.`.
    static func make(_ prefix: Prefix, _ components: String...) -> String {
        make(prefix, components)
    }

    static func make(_ prefix: Prefix, _ components: [String]) -> String {
        prefix.rawValue + ":" + components.map(escape).joined(separator: ".")
    }

    /// Escape one component. Works on unicode scalars so a `.` followed
    /// by a combining mark is still escaped (and parsed) consistently.
    static func escape(_ component: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in component.unicodeScalars {
            if scalar == separator || scalar == escapeChar {
                out.append(escapeChar)
            }
            out.append(scalar)
        }
        return String(out)
    }

    // MARK: - Parsing

    /// Split an id into its raw prefix and unescaped components. `nil`
    /// when the id has no `prefix:` part. A dangling trailing `\` is
    /// kept literally rather than rejected.
    static func parse(_ id: String) -> (prefix: String, components: [String])? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let prefix = String(id[..<colon])
        let body = id[id.index(after: colon)...]

        var components: [String] = []
        var current = String.UnicodeScalarView()
        var escaping = false
        for scalar in body.unicodeScalars {
            if escaping {
                current.append(scalar)
                escaping = false
            } else if scalar == escapeChar {
                escaping = true
            } else if scalar == separator {
                components.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if escaping { current.append(escapeChar) }
        components.append(String(current))
        return (prefix, components)
    }

    /// Kind-aware resolution of `node`'s id into its database / schema /
    /// table / bare-name parts. `nil` for category headers and ids that
    /// don't match the node's kind.
    static func target(for node: PgSchemaNode) -> PgNodeTarget? {
        guard let parsed = parse(node.id) else { return nil }
        let c = parsed.components

        switch node.kind {
        case .database:
            let name = c.joined(separator: ".")
            return PgNodeTarget(database: name, schema: "", table: nil, name: name)
        case .role, .tablespace:
            return PgNodeTarget(database: "", schema: "", table: nil, name: c.joined(separator: "."))
        case .schema, .language:
            guard c.count >= 2 else { return nil }
            let name = tail(c, from: 1)
            return PgNodeTarget(database: c[0], schema: name, table: nil, name: name)
        case .routine(_, let signature, _):
            guard c.count >= 3 else { return nil }
            if c.count == 4 {
                // Current form: db . schema . name . signature
                return PgNodeTarget(database: c[0], schema: c[1], table: nil, name: c[2])
            }
            // Legacy form: the signature was glued onto the name.
            var name = tail(c, from: 2)
            if !signature.isEmpty, name.hasSuffix(signature) {
                name = String(name.dropLast(signature.count))
            }
            return PgNodeTarget(database: c[0], schema: c[1], table: nil, name: name)
        case .relation, .sequence, .objectType:
            guard c.count >= 3 else { return nil }
            return PgNodeTarget(database: c[0], schema: c[1], table: nil, name: tail(c, from: 2))
        case .column, .key, .constraint, .trigger:
            guard c.count >= 4 else { return nil }
            return PgNodeTarget(database: c[0], schema: c[1], table: c[2], name: tail(c, from: 3))
        case .category:
            return nil
        }
    }

    /// Components from `index` on, re-joined with `.` — only more than
    /// one for legacy unescaped ids whose trailing name contained dots.
    private static func tail(_ c: [String], from index: Int) -> String {
        c[index...].joined(separator: ".")
    }
}
