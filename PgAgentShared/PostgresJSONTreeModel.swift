import Foundation

// =============================================================================
// PostgresJSONTreeModel — platform-neutral model behind the cell inspector's
// JSON tree mode: parse a json/jsonb cell into a display tree and generate
// extraction expressions for any node:
//
//   Postgres:  col->'a'->0->>'b'      (`->>` on the last hop for scalars)
//   jsonpath:  $.a[0].b               (quoted segment for non-identifier keys)
//
// Keys are sorted alphabetically (JSONSerialization does not preserve
// object order); array order is preserved. No UI dependencies — unit-tested
// in PgAgentAppTests.
// =============================================================================

enum PostgresJSONPathSegment: Hashable, Sendable {
    case key(String)
    case index(Int)
}

struct PostgresJSONTreeNode: Identifiable {
    enum Kind {
        case object(count: Int)
        case array(count: Int)
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    /// Stable identity derived from the path (root = "$").
    let id: String
    /// Row label: the object key, `[i]` for array elements, or the type
    /// name at the root.
    let label: String
    let path: [PostgresJSONPathSegment]
    let kind: Kind
    /// Non-nil for containers (even empty ones — an empty array still
    /// discloses to "no elements"); nil marks a leaf.
    let children: [PostgresJSONTreeNode]?

    var isContainer: Bool {
        switch kind {
        case .object, .array: return true
        default: return false
        }
    }

    /// Right-hand display text for the row.
    var valueDisplay: String {
        switch kind {
        case .object(let count): return count == 1 ? "{1 key}" : "{\(count) keys}"
        case .array(let count): return count == 1 ? "[1 item]" : "[\(count) items]"
        case .string(let s): return "\"\(s)\""
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }
}

enum PostgresJSONTree {
    /// Parse `text` and build the display tree. Returns `nil` when the text
    /// is not valid JSON. Scalars at the top level (legal in jsonb) yield a
    /// single leaf root.
    static func build(fromJSONText text: String) -> PostgresJSONTreeNode? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                  with: data, options: [.fragmentsAllowed]
              )
        else { return nil }
        return node(for: object, label: "root", path: [])
    }

    // MARK: - Tree building

    private static func node(
        for value: Any,
        label: String,
        path: [PostgresJSONPathSegment]
    ) -> PostgresJSONTreeNode {
        let id = idString(for: path)
        switch value {
        case let dict as [String: Any]:
            let children = dict.keys.sorted().map { key in
                node(for: dict[key]!, label: key, path: path + [.key(key)])
            }
            return PostgresJSONTreeNode(
                id: id, label: label, path: path,
                kind: .object(count: dict.count), children: children
            )
        case let array as [Any]:
            let children = array.enumerated().map { idx, element in
                node(for: element, label: "[\(idx)]", path: path + [.index(idx)])
            }
            return PostgresJSONTreeNode(
                id: id, label: label, path: path,
                kind: .array(count: array.count), children: children
            )
        case let string as String:
            return PostgresJSONTreeNode(
                id: id, label: label, path: path, kind: .string(string), children: nil
            )
        case let number as NSNumber:
            if isBoolean(number) {
                return PostgresJSONTreeNode(
                    id: id, label: label, path: path,
                    kind: .bool(number.boolValue), children: nil
                )
            }
            return PostgresJSONTreeNode(
                id: id, label: label, path: path,
                kind: .number(numberDisplay(number)), children: nil
            )
        default: // NSNull (or anything unexpected) renders as null
            return PostgresJSONTreeNode(
                id: id, label: label, path: path, kind: .null, children: nil
            )
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        number === kCFBooleanTrue || number === kCFBooleanFalse
    }

    /// Integral NSNumbers print without a trailing `.0`; everything else
    /// uses the default description (JSONSerialization already normalized
    /// the literal).
    private static func numberDisplay(_ number: NSNumber) -> String {
        number.stringValue
    }

    private static func idString(for path: [PostgresJSONPathSegment]) -> String {
        "$" + path.map { segment in
            switch segment {
            case .key(let k): return ".\(k)"
            case .index(let i): return "[\(i)]"
            }
        }.joined()
    }

    // MARK: - Path expressions

    /// Postgres extraction expression, e.g. `col->'a'->0->>'b'`. The last
    /// hop uses `->>` (text) when the node is a scalar and `->` when it is
    /// a container; an empty path returns the bare column reference.
    static func postgresExpression(
        column: String,
        path: [PostgresJSONPathSegment],
        leafIsScalar: Bool
    ) -> String {
        var expr = quoteIdentIfNeeded(column)
        for (i, segment) in path.enumerated() {
            let isLast = i == path.count - 1
            let arrow = (isLast && leafIsScalar) ? "->>" : "->"
            switch segment {
            case .key(let key):
                expr += "\(arrow)'\(key.replacingOccurrences(of: "'", with: "''"))'"
            case .index(let idx):
                expr += "\(arrow)\(idx)"
            }
        }
        return expr
    }

    /// SQL/JSON path expression, e.g. `$.a[0].b`. Keys that are not plain
    /// identifiers are double-quoted (`$."weird key"`), with `\` and `"`
    /// escaped per the jsonpath string rules.
    static func jsonpathExpression(path: [PostgresJSONPathSegment]) -> String {
        var expr = "$"
        for segment in path {
            switch segment {
            case .key(let key):
                if isPlainJsonpathIdentifier(key) {
                    expr += ".\(key)"
                } else {
                    let escaped = key
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    expr += ".\"\(escaped)\""
                }
            case .index(let idx):
                expr += "[\(idx)]"
            }
        }
        return expr
    }

    // MARK: - Quoting helpers

    /// Quote a column reference only when it isn't already a plain
    /// lower-case identifier — keeps the common `payload->'a'` output
    /// clean while staying correct for `"Weird Column"`.
    static func quoteIdentIfNeeded(_ ident: String) -> String {
        guard !ident.isEmpty else { return pgQuoteIdent(ident) }
        let scalars = ident.unicodeScalars
        let first = scalars.first!
        let firstOK = (first >= "a" && first <= "z") || first == "_"
        let restOK = scalars.dropFirst().allSatisfy {
            ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "_" || $0 == "$"
        }
        return (firstOK && restOK) ? ident : pgQuoteIdent(ident)
    }

    private static func isPlainJsonpathIdentifier(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        let firstOK = (first >= "a" && first <= "z") || (first >= "A" && first <= "Z")
            || first == "_"
        let restOK = key.unicodeScalars.dropFirst().allSatisfy {
            ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z")
                || ($0 >= "0" && $0 <= "9") || $0 == "_"
        }
        return firstOK && restOK
    }
}
