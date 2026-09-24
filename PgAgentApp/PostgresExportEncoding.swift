import Foundation

// =============================================================================
// PostgresExportEncoding — the single set of pure text encoders shared by
// the results grid's copy / visible-rows CSV export and the full-result
// streaming export (CSV / JSONL).
//
// Everything here inspects `unicodeScalars`, never `Character`s: in Swift
// "\r\n" is ONE grapheme cluster, so `s.contains("\n")` is false for a value
// holding a CRLF — which used to leave such fields unquoted and split the
// row in every CSV reader.
// =============================================================================

enum PostgresExportEncoding {
    // MARK: - CSV (RFC 4180)

    /// Encodes one CSV field. Follows PostgreSQL's `COPY … CSV` convention
    /// so NULL and the empty string stay distinguishable: SQL NULL is an
    /// unquoted empty field, the empty string is `""`.
    ///
    /// A value is quoted when it contains a comma, double-quote, CR or LF,
    /// or has leading/trailing whitespace (which some readers trim when
    /// unquoted). Embedded double-quotes are doubled.
    static func csvField(_ value: String?) -> String {
        guard let value else { return "" }
        if value.isEmpty { return "\"\"" }
        guard csvNeedsQuoting(value) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Fields joined with `,`. No line terminator.
    static func csvRow(_ fields: [String?]) -> String {
        fields.map(csvField).joined(separator: ",")
    }

    static func csvNeedsQuoting(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        if let first = scalars.first, isEdgeWhitespace(first) { return true }
        if let last = scalars.last, isEdgeWhitespace(last) { return true }
        return scalars.contains { scalar in
            switch scalar {
            case ",", "\"", "\n", "\r": return true
            default: return false
            }
        }
    }

    private static func isEdgeWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t"
    }

    // MARK: - TSV (clipboard)

    /// Makes a value safe for one tab-separated clipboard cell. Tabs become
    /// a single space (lossy but the common convention); every line break —
    /// LF, CR or CRLF — becomes the two-character literal `\n`, so a pasted
    /// row never splits. Spreadsheets don't honor CSV-style quoting in
    /// tab-pasted data, hence no quoting.
    static func tsvField(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\t":
                out.append(" ")
            case "\r":
                out.append(contentsOf: "\\n".unicodeScalars)
            case "\n":
                // The LF of a CRLF was already emitted with its CR.
                if !previousWasCR { out.append(contentsOf: "\\n".unicodeScalars) }
            default:
                out.append(scalar)
            }
            previousWasCR = scalar == "\r"
        }
        return String(out)
    }

    // MARK: - JSON / JSONL

    /// A JSON string literal (with surrounding quotes) per RFC 8259:
    /// `"` and `\` are escaped, control characters U+0000–U+001F use the
    /// short escapes where they exist and `\u00XX` otherwise. Everything
    /// else (including non-ASCII) is emitted verbatim as UTF-8.
    static func jsonString(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        out.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out.append(contentsOf: "\\\"".unicodeScalars)
            case "\\": out.append(contentsOf: "\\\\".unicodeScalars)
            case "\n": out.append(contentsOf: "\\n".unicodeScalars)
            case "\r": out.append(contentsOf: "\\r".unicodeScalars)
            case "\t": out.append(contentsOf: "\\t".unicodeScalars)
            case "\u{08}": out.append(contentsOf: "\\b".unicodeScalars)
            case "\u{0C}": out.append(contentsOf: "\\f".unicodeScalars)
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    let padded = String(repeating: "0", count: 4 - hex.count) + hex
                    out.append(contentsOf: "\\u\(padded)".unicodeScalars)
                } else {
                    out.append(scalar)
                }
            }
        }
        out.append("\"")
        return String(out)
    }

    /// One JSON object, keys in the given (column) order. Values are
    /// strings, SQL NULL is `null`. `keys` and `values` are zipped; callers
    /// pass keys already de-duplicated via `uniqueKeys`.
    static func jsonObject(keys: [String], values: [String?]) -> String {
        let members = zip(keys, values).map { key, value in
            jsonString(key) + ":" + (value.map(jsonString) ?? "null")
        }
        return "{" + members.joined(separator: ",") + "}"
    }

    /// Result sets can repeat a column name (`SELECT a.id, b.id …`), but a
    /// JSON object with duplicate keys loses data in nearly every parser.
    /// Later duplicates get a `_2`, `_3`, … suffix (skipping suffixes that
    /// collide with a real column name).
    static func uniqueKeys(_ names: [String]) -> [String] {
        var taken = Set(names)
        var seen = Set<String>()
        return names.map { name in
            guard seen.contains(name) else {
                seen.insert(name)
                return name
            }
            var n = 2
            while taken.contains("\(name)_\(n)") { n += 1 }
            let key = "\(name)_\(n)"
            taken.insert(key)
            seen.insert(key)
            return key
        }
    }
}

/// The visible-column projection used by the streaming line export:
/// display names in order, the result-cell index each maps to, and the
/// de-duplicated JSON keys.
struct PostgresExportColumnPlan: Equatable, Sendable {
    let names: [String]
    let indices: [Int]
    let jsonKeys: [String]

    init(names: [String], indices: [Int]) {
        precondition(names.count == indices.count, "names/indices must align")
        self.names = names
        self.indices = indices
        self.jsonKeys = PostgresExportEncoding.uniqueKeys(names)
    }

    /// Every result column except the hidden `__pg_*` helpers, in result order.
    init(resultColumnNames: [String]) {
        let visible = resultColumnNames.enumerated().filter { !$0.element.hasPrefix("__pg_") }
        self.init(names: visible.map(\.element), indices: visible.map(\.offset))
    }

    var isEmpty: Bool { names.isEmpty }

    /// Picks this plan's cells out of a result row; a short row yields NULLs.
    func project(_ cells: [String?]) -> [String?] {
        indices.map { $0 < cells.count ? cells[$0] : nil }
    }

    /// CSV header line, `\n`-terminated.
    var csvHeaderLine: String {
        names.map { PostgresExportEncoding.csvField($0) }.joined(separator: ",") + "\n"
    }

    /// One `\n`-terminated CSV record.
    func csvLine(_ cells: [String?]) -> String {
        PostgresExportEncoding.csvRow(project(cells)) + "\n"
    }

    /// One `\n`-terminated JSONL record (keys in column order).
    func jsonlLine(_ cells: [String?]) -> String {
        PostgresExportEncoding.jsonObject(keys: jsonKeys, values: project(cells)) + "\n"
    }
}
