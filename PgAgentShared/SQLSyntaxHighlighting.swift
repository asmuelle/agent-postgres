import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// =============================================================================
// SQLSyntaxHighlighting — platform-neutral SQL syntax coloring over TextKit's
// NSTextStorage (available on both AppKit and UIKit). Extracted from the
// macOS-only PostgresSQLSyntax so the iPad code editor highlights identically;
// the mac enum now forwards here.
//
// Colors are semantic system colors so they adapt to light/dark automatically.
// =============================================================================

#if canImport(AppKit)
typealias SQLPlatformFont = NSFont
typealias SQLPlatformColor = NSColor
#elseif canImport(UIKit)
typealias SQLPlatformFont = UIFont
typealias SQLPlatformColor = UIColor
#endif

enum SQLSyntaxHighlighting {
    private static let keywordSet: Set<String> = SQLCompletionVocabulary.keywordSet

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

    private static var textColor: SQLPlatformColor {
        #if canImport(AppKit)
        return .textColor
        #else
        return .label
        #endif
    }

    private static var secondaryColor: SQLPlatformColor {
        #if canImport(AppKit)
        return .secondaryLabelColor
        #else
        return .secondaryLabel
        #endif
    }

    static func highlight(_ storage: NSTextStorage, baseFont: SQLPlatformFont) {
        let text = storage.string
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        guard full.length > 0 else { return }

        storage.beginEditing()
        storage.setAttributes(
            [.font: baseFont, .foregroundColor: textColor],
            range: full
        )

        // Keywords (whole word) — colored first so the string/comment passes
        // below can override a keyword that lives inside a literal or comment.
        identifierRegex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let r = match?.range else { return }
            if keywordSet.contains(nsText.substring(with: r).uppercased()) {
                storage.addAttribute(.foregroundColor, value: SQLPlatformColor.systemPurple, range: r)
            }
        }

        // Numbers, then strings, dollar-quote delimiters, then comments (later
        // passes win). Dollar delimiters go after keywords/numbers so a tag like
        // `$body$` reads as a boundary token, but before comments so a `--`
        // inside a body still greys correctly.
        apply(numberRegex, SQLPlatformColor.systemOrange, storage, text, full)
        apply(stringRegex, SQLPlatformColor.systemRed, storage, text, full)
        apply(dollarTagRegex, secondaryColor, storage, text, full)
        apply(lineCommentRegex, SQLPlatformColor.systemGray, storage, text, full)
        apply(blockCommentRegex, SQLPlatformColor.systemGray, storage, text, full)

        storage.endEditing()
    }

    private static func apply(
        _ regex: NSRegularExpression,
        _ color: SQLPlatformColor,
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
