import Foundation

// =============================================================================
// PostgresSnippetPlaceholders — TextMate-style placeholder parsing for the
// snippet library.
//
// Supported syntax in a snippet body:
//   ${1:default}   tab stop 1 whose inserted text is "default" (selected on
//                  arrival so typing replaces it)
//   ${2}  /  $2    empty tab stop (caret placed, nothing selected)
//   $0             final caret position after the last tab stop
//   \$             a literal dollar sign
//
// Tab order is by placeholder number ascending; equal numbers order by
// position (mirroring is not supported — each occurrence is its own stop).
// `$0` never appears as a stop; it only supplies the final caret.
//
// All offsets are UTF-16 so they can be handed straight to NSTextView /
// NSRange machinery on the AppKit side. Platform-neutral: compiled into
// both apps; the parser has no UI dependencies and is unit-tested.
// =============================================================================

/// One tab stop in the expanded snippet text.
struct PostgresSnippetTabStop: Equatable, Sendable {
    let number: Int
    /// Location/length in UTF-16 units into `PostgresParsedSnippet.text`.
    let location: Int
    let length: Int
}

struct PostgresParsedSnippet: Equatable, Sendable {
    /// The body with placeholder markup replaced by its default text.
    let text: String
    /// Stops in tab order (number ascending, then position).
    let tabStops: [PostgresSnippetTabStop]
    /// UTF-16 offset of the `$0` final caret in `text`, when present.
    let finalCursorUTF16: Int?
}

enum PostgresSnippetPlaceholders {
    /// Expand `body` and collect its tab stops. Malformed markup (an
    /// unterminated `${1:…`) is left in the output verbatim rather than
    /// dropped — a snippet should never lose user-visible characters.
    static func parse(_ body: String) -> PostgresParsedSnippet {
        var out = ""
        var outUTF16 = 0
        var stops: [PostgresSnippetTabStop] = []
        var finalCursor: Int?

        let chars = Array(body)
        var i = 0
        let n = chars.count

        func append(_ piece: some StringProtocol) {
            out.append(contentsOf: piece)
            outUTF16 += String(piece).utf16.count
        }

        while i < n {
            let c = chars[i]
            // Escaped dollar: \$ → literal $
            if c == "\\", i + 1 < n, chars[i + 1] == "$" {
                append("$")
                i += 2
                continue
            }
            guard c == "$", i + 1 < n else {
                append(String(c))
                i += 1
                continue
            }

            // Bare $N
            if chars[i + 1].isNumber {
                var j = i + 1
                var digits = ""
                while j < n, chars[j].isNumber {
                    digits.append(chars[j])
                    j += 1
                }
                let number = Int(digits) ?? 0
                if number == 0 {
                    finalCursor = finalCursor ?? outUTF16
                } else {
                    stops.append(PostgresSnippetTabStop(
                        number: number, location: outUTF16, length: 0
                    ))
                }
                i = j
                continue
            }

            // ${N} or ${N:content}
            if chars[i + 1] == "{",
               let parsed = parseBraced(chars, openBrace: i + 1) {
                if parsed.number == 0 {
                    // ${0} / ${0:text}: insert any content, caret after it.
                    append(parsed.content)
                    finalCursor = finalCursor ?? outUTF16
                } else {
                    let location = outUTF16
                    append(parsed.content)
                    stops.append(PostgresSnippetTabStop(
                        number: parsed.number,
                        location: location,
                        length: outUTF16 - location
                    ))
                }
                i = parsed.nextIndex
                continue
            }

            // A lone $ that isn't placeholder markup.
            append("$")
            i += 1
        }

        let ordered = stops.enumerated().sorted {
            ($0.element.number, $0.element.location, $0.offset)
                < ($1.element.number, $1.element.location, $1.offset)
        }.map(\.element)

        return PostgresParsedSnippet(
            text: out,
            tabStops: ordered,
            finalCursorUTF16: finalCursor
        )
    }

    /// Whether `body` contains any placeholder markup at all — used by the
    /// insertion path to skip the tab-stop session for plain snippets.
    static func containsPlaceholders(_ body: String) -> Bool {
        let parsed = parse(body)
        return !parsed.tabStops.isEmpty || parsed.finalCursorUTF16 != nil
    }

    // MARK: - Internals

    private struct BracedPlaceholder {
        let number: Int
        let content: String
        /// Index just past the closing `}`.
        let nextIndex: Int
    }

    /// Parse `${N}` / `${N:content}` with `chars[openBrace] == "{"`.
    /// Returns `nil` when the markup is malformed (no digits, or no
    /// closing brace) so the caller emits it verbatim. Content runs to
    /// the first `}` — nested placeholders are not supported.
    private static func parseBraced(
        _ chars: [Character],
        openBrace: Int
    ) -> BracedPlaceholder? {
        var j = openBrace + 1
        let n = chars.count
        var digits = ""
        while j < n, chars[j].isNumber {
            digits.append(chars[j])
            j += 1
        }
        guard !digits.isEmpty, let number = Int(digits), j < n else { return nil }

        if chars[j] == "}" {
            return BracedPlaceholder(number: number, content: "", nextIndex: j + 1)
        }
        guard chars[j] == ":" else { return nil }
        j += 1
        var content = ""
        while j < n, chars[j] != "}" {
            // \} inside content escapes the brace.
            if chars[j] == "\\", j + 1 < n, chars[j + 1] == "}" {
                content.append("}")
                j += 2
            } else {
                content.append(chars[j])
                j += 1
            }
        }
        guard j < n else { return nil } // unterminated
        return BracedPlaceholder(number: number, content: content, nextIndex: j + 1)
    }
}
