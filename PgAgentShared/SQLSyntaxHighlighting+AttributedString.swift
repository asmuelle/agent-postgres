import SwiftUI

// =============================================================================
// SQLSyntaxHighlighting+AttributedString — read-only SwiftUI rendering of the
// shared highlighter, for places that show SQL in a `Text` rather than an
// editor (e.g. the Property Inspector's "DDL Source" tab).
//
// Runs the exact same NSTextStorage pass as the editors, then maps each color
// run onto a SwiftUI `AttributedString`. Only colors are carried over — the
// highlighter never varies the font, so callers keep their own `.font(...)`.
// =============================================================================

extension SQLSyntaxHighlighting {
    static func attributedString(_ sql: String) -> AttributedString {
        let storage = NSTextStorage(string: sql)
        highlight(storage, baseFont: .monospacedSystemFont(ofSize: 12, weight: .regular))

        var result = AttributedString()
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            var run = AttributedString(storage.attributedSubstring(from: range).string)
            if let color = value as? SQLPlatformColor {
                run.foregroundColor = swiftUIColor(color)
            }
            result += run
        }
        return result
    }

    private static func swiftUIColor(_ color: SQLPlatformColor) -> Color {
        #if canImport(AppKit)
        return Color(nsColor: color)
        #else
        return Color(uiColor: color)
        #endif
    }
}
