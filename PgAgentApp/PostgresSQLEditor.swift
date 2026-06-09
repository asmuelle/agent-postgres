import AppKit
import SwiftUI

// =============================================================================
// PostgresSQLEditor — AppKit-backed SQL editor.
//
// Replaces the bare SwiftUI TextEditor on the most-used surface in the
// workspace with an NSTextView that has SQL syntax highlighting and
// schema-aware word completion (keywords + types + functions + live
// table/column/schema identifiers from PgSchemaStore).
//
// ⌘↵ (run) and ⌘. (cancel) stay handled by the hidden SwiftUI buttons in the
// parent's overlay — those register as window-level key equivalents and fire
// before keyDown reaches this view, so we deliberately don't duplicate them
// here (avoids double-execution).
// =============================================================================

struct PostgresSQLEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    /// Live identifier candidates (table / column / schema / function names).
    /// Evaluated lazily, only when the user triggers completion, so it always
    /// reflects whatever the browser has loaded so far. `@MainActor` because it
    /// reads the main-actor PgSchemaStore; the completion delegate runs on the
    /// main actor, so this is always satisfied.
    var identifiers: @MainActor () -> [String]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PgSQLTextView()
        textView.delegate = context.coordinator
        textView.font = Self.editorFont
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isEditable = isEditable
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.string = text

        // Vertically resizable, width-tracking — standard editor geometry.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        context.coordinator.textView = textView
        context.coordinator.applyHighlighting()

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PgSQLTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEditable

        // Sync programmatic text changes (AI insert, history, saved query).
        // This runs only when the buffer differs from the model — i.e. a
        // wholesale replacement, never mid-typing (the binding keeps them in
        // sync during edits). Old caret offsets are meaningless against the new
        // text, so place the caret at end-of-document.
        if textView.string != text {
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            context.coordinator.applyHighlighting()
        }
    }

    private static var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PostgresSQLEditor
        weak var textView: PgSQLTextView?

        // Completion fires on most keystrokes, and `identifiers()` scans all
        // loaded schema state — so cache it and refresh at most once a second
        // rather than rescanning per keystroke.
        private var cachedIdentifiers: [String] = []
        private var lastIdentifierRefresh: Date = .distantPast

        init(_ parent: PostgresSQLEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // Push the edit back through the binding; the parent's setter
            // also revokes AI provenance on the query tab.
            if parent.text != textView.string {
                parent.text = textView.string
            }
            applyHighlighting()
        }

        /// Schema-aware completion: SQL vocabulary + live identifiers,
        /// prefix-matched against the partial word, case-insensitively.
        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            let partial = (textView.string as NSString).substring(with: charRange).lowercased()
            guard partial.count >= 1 else { return [] }

            let now = Date()
            if now.timeIntervalSince(lastIdentifierRefresh) > 1.0 {
                cachedIdentifiers = parent.identifiers()
                lastIdentifierRefresh = now
            }

            var seen = Set<String>()
            let matches = (PostgresSQLSyntax.completionVocabulary + cachedIdentifiers)
                .filter { candidate in
                    let lower = candidate.lowercased()
                    return lower != partial
                        && lower.hasPrefix(partial)
                        && seen.insert(lower).inserted
                }
                .sorted { $0.lowercased() < $1.lowercased() }

            // Don't pre-select a row, so fast typing can't accidentally accept.
            index?.pointee = -1
            return Array(matches.prefix(60))
        }

        func applyHighlighting() {
            guard let textView, let storage = textView.textStorage else { return }
            PostgresSQLSyntax.highlight(storage, baseFont: textView.font ?? PostgresSQLEditor.editorFont)
        }
    }
}

/// NSTextView that pops the completion list as the user types an identifier.
final class PgSQLTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)

        // Only auto-suggest on a plain identifier keystroke (no modifiers),
        // once the current word is at least two characters — enough signal to
        // be useful without flickering on every single letter. Esc still works
        // as the manual trigger.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty || modifiers == [.shift],
              let chars = event.charactersIgnoringModifiers,
              chars.count == 1,
              let scalar = chars.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        else { return }

        let caret = selectedRange().location
        if caret - currentWordStart(before: caret) >= 2 {
            complete(self)
        }
    }

    private func currentWordStart(before location: Int) -> Int {
        let ns = string as NSString
        var i = min(location, ns.length)
        while i > 0 {
            guard let s = Unicode.Scalar(UInt32(ns.character(at: i - 1))),
                  CharacterSet.alphanumerics.contains(s) || s == "_"
            else { break }
            i -= 1
        }
        return i
    }
}
