import Foundation

// =============================================================================
// SQLCompletionInsertion — turns a picked `SQLCompletionItem` into one text
// edit, and decides when suggestions are worth showing at all. Pure and
// platform-neutral (UTF-16 offsets, like UITextView / NSTextView), so any
// editor surface can drive it.
// =============================================================================
enum SQLCompletionInsertion {
    struct Edit: Equatable {
        /// UTF-16 range to replace: the word the caret is in.
        let range: NSRange
        let replacement: String
    }

    /// Replace the word the caret is in — both sides of it — with `item`,
    /// followed by what naturally comes next (a space after keywords and
    /// tables, a dot after a schema). Nothing is added when the word
    /// continued past the caret or a space already follows.
    static func edit(for item: SQLCompletionItem, in text: String, cursorUTF16: Int) -> Edit {
        let cursor = index(in: text, utf16Offset: cursorUTF16)
        var start = cursor
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard SQLCompletionEngine.isIdentChar(text[previous]) else { break }
            start = previous
        }
        var end = cursor
        while end < text.endIndex, SQLCompletionEngine.isIdentChar(text[end]) {
            end = text.index(after: end)
        }

        var replacement = item.insertText
        let followedByWhitespace = end < text.endIndex && text[end].isWhitespace
        if end == cursor, !followedByWhitespace {
            replacement += suffix(after: item.kind)
        }

        let location = start.utf16Offset(in: text)
        return Edit(
            range: NSRange(location: location, length: end.utf16Offset(in: text) - location),
            replacement: replacement
        )
    }

    /// Worth showing while a word is being typed, right after a `.`, or where
    /// the context calls for tables or columns (e.g. right after `FROM `). A
    /// blank spot where only keywords fit stays quiet — that list is noise.
    static func shouldOffer(_ items: [SQLCompletionItem], in text: String, cursorUTF16: Int) -> Bool {
        guard let first = items.first else { return false }
        let cursor = index(in: text, utf16Offset: cursorUTF16)
        if cursor > text.startIndex {
            let previous = text[text.index(before: cursor)]
            if SQLCompletionEngine.isIdentChar(previous) || previous == "." { return true }
        }
        return first.kind == .relation || first.kind == .column
    }

    private static func suffix(after kind: SQLCompletionItem.Kind) -> String {
        switch kind {
        case .keyword, .relation: return " "
        case .schema: return "."
        case .function, .type, .column, .alias: return ""
        }
    }

    /// The character boundary at or before `utf16Offset` — an offset inside
    /// a surrogate pair or emoji sequence never splits it.
    private static func index(in text: String, utf16Offset: Int) -> String.Index {
        let clamped = max(0, min(utf16Offset, text.utf16.count))
        let ns = text as NSString
        let rounded = clamped < ns.length
            ? ns.rangeOfComposedCharacterSequence(at: clamped).location
            : clamped
        return String.Index(utf16Offset: rounded, in: text)
    }
}
