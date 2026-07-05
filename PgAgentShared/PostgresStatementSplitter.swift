import Foundation

// =============================================================================
// PostgresStatementSplitter — split a SQL script into its top-level
// statements, respecting single-quoted strings ('' escape), quoted
// identifiers ("" escape), line comments (-- …), block comments (/* … */),
// and dollar-quoted bodies ($$ … $$ / $tag$ … $tag$).
//
// A Swift port of the lexer in ssh-commander-pg's `exec.rs` (whose splitter
// is pub(crate) and therefore not reachable through the FFI). Used by the
// script-execution path so a multi-statement run can execute statement by
// statement through the existing `pgExecute` bridge — which is what keeps
// the read-only classifier and the write audit log applying per statement.
//
// Platform-neutral: compiled into both the macOS and iOS apps.
// =============================================================================

/// One top-level statement of a script.
struct PostgresScriptStatement: Equatable, Sendable {
    /// The statement text, trimmed of surrounding whitespace. Retains any
    /// embedded comments (a leading `-- note` line stays part of its
    /// statement) and does not include the terminating `;`.
    let text: String
    /// Character offset (Swift `Character` count, matching how the editor's
    /// `errorCharOffset` is measured) of `text`'s first character in the
    /// original script. Lets a server error position inside statement N be
    /// mapped back onto the editor's full text.
    let startCharOffset: Int
}

enum PostgresStatementSplitter {
    /// Split `sql` into top-level statements. Segments that contain only
    /// whitespace and/or comments (e.g. the tail after a trailing `;`)
    /// are dropped. A single-statement script returns one element.
    static func split(_ sql: String) -> [PostgresScriptStatement] {
        let chars = Array(sql)
        var statements: [PostgresScriptStatement] = []
        var segmentStart = 0
        for boundary in topLevelSemicolons(chars) + [chars.count] {
            if let statement = makeStatement(chars, from: segmentStart, to: boundary) {
                statements.append(statement)
            }
            segmentStart = boundary + 1
        }
        return statements
    }

    // MARK: - Segment extraction

    /// Build a statement from `chars[from..<to]`, or `nil` when the segment
    /// is effectively empty (whitespace and comments only).
    private static func makeStatement(
        _ chars: [Character],
        from: Int,
        to: Int
    ) -> PostgresScriptStatement? {
        guard from < to, hasRealToken(chars, from: from, to: to) else { return nil }
        var start = from
        while start < to, chars[start].isWhitespace { start += 1 }
        var end = to
        while end > start, chars[end - 1].isWhitespace { end -= 1 }
        guard start < end else { return nil }
        return PostgresScriptStatement(
            text: String(chars[start..<end]),
            startCharOffset: start
        )
    }

    /// Whether the segment contains anything beyond whitespace and
    /// comments — mirrors `is_effectively_empty` in the core crate
    /// (inverted). A comment-only tail after the final `;` is not a
    /// statement.
    private static func hasRealToken(_ chars: [Character], from: Int, to: Int) -> Bool {
        var i = from
        while i < to {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
            } else if c == "-", i + 1 < to, chars[i + 1] == "-" {
                while i < to, chars[i] != "\n" { i += 1 }
            } else if c == "/", i + 1 < to, chars[i + 1] == "*" {
                i += 2
                while i < to {
                    if chars[i] == "*", i + 1 < to, chars[i + 1] == "/" {
                        i += 2
                        break
                    }
                    i += 1
                }
            } else {
                return true
            }
        }
        return false
    }

    // MARK: - Lexer

    private enum LexState {
        case normal
        case singleQuote
        case doubleQuote
        case lineComment
        case blockComment
        case dollarQuote([Character])
    }

    /// Character indices of every `;` that sits outside strings, quoted
    /// identifiers, comments, and dollar-quoted bodies.
    private static func topLevelSemicolons(_ chars: [Character]) -> [Int] {
        var positions: [Int] = []
        var state = LexState.normal
        var i = 0
        let n = chars.count
        while i < n {
            let c = chars[i]
            switch state {
            case .normal:
                switch c {
                case "'": state = .singleQuote
                case "\"": state = .doubleQuote
                case "-" where i + 1 < n && chars[i + 1] == "-":
                    state = .lineComment
                    i += 1
                case "/" where i + 1 < n && chars[i + 1] == "*":
                    state = .blockComment
                    i += 1
                case "$":
                    if let delimiter = dollarQuoteDelimiter(chars, at: i) {
                        state = .dollarQuote(delimiter)
                        i += delimiter.count - 1
                    }
                case ";": positions.append(i)
                default: break
                }
            case .singleQuote:
                if c == "'" {
                    if i + 1 < n, chars[i + 1] == "'" {
                        i += 1 // escaped '' — stay in the string
                    } else {
                        state = .normal
                    }
                }
            case .doubleQuote:
                if c == "\"" {
                    if i + 1 < n, chars[i + 1] == "\"" {
                        i += 1 // escaped "" — stay in the identifier
                    } else {
                        state = .normal
                    }
                }
            case .lineComment:
                if c == "\n" { state = .normal }
            case .blockComment:
                if c == "*", i + 1 < n, chars[i + 1] == "/" {
                    state = .normal
                    i += 1
                }
            case .dollarQuote(let delimiter):
                if matches(chars, at: i, delimiter: delimiter) {
                    state = .normal
                    i += delimiter.count - 1
                }
            }
            i += 1
        }
        return positions
    }

    /// If a dollar-quote opener starts at `idx`, return its full delimiter
    /// (`$$`, `$body$`, …). The first tag character must be a letter or
    /// underscore — `$1` is a positional parameter, not a quote.
    private static func dollarQuoteDelimiter(_ chars: [Character], at idx: Int) -> [Character]? {
        guard idx < chars.count, chars[idx] == "$" else { return nil }
        var end = idx + 1
        guard end < chars.count else { return nil }
        if chars[end] == "$" { return Array(chars[idx...end]) }
        guard chars[end].isLetter || chars[end] == "_" else { return nil }
        end += 1
        while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" {
            end += 1
        }
        guard end < chars.count, chars[end] == "$" else { return nil }
        return Array(chars[idx...end])
    }

    private static func matches(_ chars: [Character], at idx: Int, delimiter: [Character]) -> Bool {
        guard idx + delimiter.count <= chars.count else { return false }
        for k in 0..<delimiter.count where chars[idx + k] != delimiter[k] { return false }
        return true
    }
}
