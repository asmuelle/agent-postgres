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
    /// Reserved words that get keyword coloring. Single source of truth is
    /// the shared `SQLCompletionVocabulary` (also used by the platform-
    /// neutral completion engine); these forwards keep existing call sites
    /// and tests working.
    static let keywords: [String] = SQLCompletionVocabulary.keywords

    /// Common built-in types (not separately colored).
    static let types: [String] = SQLCompletionVocabulary.types

    /// Common functions.
    static let functions: [String] = SQLCompletionVocabulary.functions

    /// Legacy flat vocabulary — keywords upper-cased (SQL convention), the
    /// rest lower-cased. Kept for tests; the editor now ranks through
    /// `SQLCompletionEngine` instead.
    static var completionVocabulary: [String] {
        keywords + types + functions
    }

    private static let keywordSet: Set<String> = SQLCompletionVocabulary.keywordSet

    // MARK: - Highlighting

    // Compiled once, reused for every highlight pass (this runs on each
    // keystroke, so per-call recompilation would stutter on large queries).
    // Patterns are static literals → `try!` is safe.
    private static let identifierRegex = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*")
    private static let numberRegex = try! NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b")
    private static let stringRegex = try! NSRegularExpression(pattern: "'(?:[^']|'')*'")
    private static let lineCommentRegex = try! NSRegularExpression(pattern: "--[^\\n]*")
    private static let blockCommentRegex = try! NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/")
    // Dollar-quote *delimiters* only ($$ or $tag$), not the body between them —
    // a function body is plpgsql we want highlighted as code, so we mark just
    // the boundary tokens (secondary color) rather than painting the whole
    // body as one string. Tags follow identifier rules; `$1` (a positional
    // parameter) has no closing `$` so it never matches.
    private static let dollarTagRegex = try! NSRegularExpression(pattern: "\\$([A-Za-z_][A-Za-z0-9_]*)?\\$")

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

        // Numbers, then strings, dollar-quote delimiters, then comments (later
        // passes win). Dollar delimiters go after keywords/numbers so a tag like
        // `$body$` reads as a boundary token, but before comments so a `--`
        // inside a body still greys correctly.
        apply(numberRegex, NSColor.systemOrange, storage, text, full)
        apply(stringRegex, NSColor.systemRed, storage, text, full)
        apply(dollarTagRegex, NSColor.secondaryLabelColor, storage, text, full)
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
