import Foundation

/// Presentation helpers for single result values (the row inspector).
enum PostgresCellFormatting {
    /// Values larger than this are shown as they are — pretty-printing a
    /// huge document isn't worth blocking the main thread for.
    static let maxPrettyJSONBytes = 100_000
    private static let indentUnit = "  "

    /// A JSON object or array, re-indented; `nil` for anything else
    /// (scalars, invalid JSON, oversized values).
    ///
    /// Only whitespace changes: numbers, strings, key order and duplicate
    /// keys stay exactly as stored. Parsing and re-serializing would turn a
    /// stored `19.99` into `19.989999999999998`.
    static func prettyJSON(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              trimmed.utf8.count <= maxPrettyJSONBytes,
              // Validity only; the parsed value is never printed.
              (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
        else { return nil }
        return reindented(trimmed)
    }

    /// Re-lays out valid JSON text: one member per line, `": "` after keys,
    /// empty containers kept as `{}` / `[]`. Strings are copied verbatim,
    /// escapes included.
    private static func reindented(_ json: String) -> String {
        let scalars = Array(json.unicodeScalars)
        var out = String.UnicodeScalarView()
        var depth = 0
        var inString = false
        var escaped = false
        var index = 0

        func newline() {
            out.append("\n")
            out.append(contentsOf: String(repeating: indentUnit, count: depth).unicodeScalars)
        }

        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if inString {
                out.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                continue
            }
            switch scalar {
            case " ", "\t", "\n", "\r":
                continue
            case "\"":
                inString = true
                out.append(scalar)
            case "{", "[":
                out.append(scalar)
                let close: Unicode.Scalar = scalar == "{" ? "}" : "]"
                if let next = nextNonWhitespace(in: scalars, from: index), scalars[next] == close {
                    out.append(close)
                    index = next + 1
                } else {
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth -= 1
                newline()
                out.append(scalar)
            case ",":
                out.append(scalar)
                newline()
            case ":":
                out.append(contentsOf: ": ".unicodeScalars)
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }

    private static func nextNonWhitespace(in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        scalars[start...].firstIndex { !" \t\n\r".unicodeScalars.contains($0) }
    }
}
