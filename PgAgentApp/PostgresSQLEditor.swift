import AppKit
import SwiftUI

// =============================================================================
// PostgresSQLEditor — AppKit-backed SQL editor.
//
// Replaces the bare SwiftUI TextEditor on the most-used surface in the
// workspace with an NSTextView that has SQL syntax highlighting and
// schema-aware completion driven by `SQLCompletionEngine` (context-sensitive:
// tables after FROM/JOIN, columns after `alias.` / in WHERE, keywords
// elsewhere; nothing inside strings or comments).
//
// Completion presentation deliberately stays on NSTextView's *native*
// machinery (`complete(_:)` + the `textView(_:completions:…)` delegate)
// rather than a custom panel: it gives list navigation, insertion, ⎋/typing
// dismissal and — critically — zero key stealing while hidden, all for free,
// and it matches how completion already behaved in this editor. The engine
// supplies context-aware, pre-quoted candidates; the popup just displays
// them. Triggers: typing 2+ identifier chars (debounced ~150 ms), `.` after
// an identifier, and Ctrl-Space / Esc explicitly.
//
// ⌘↵ (run) and ⌘. (cancel) stay handled by the hidden SwiftUI buttons in the
// parent's overlay — those register as window-level key equivalents and fire
// before keyDown reaches this view, so we deliberately don't duplicate them
// here (avoids double-execution).
// =============================================================================

struct PostgresSQLEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    /// 0-based character offset (into `text`) to underline as the last query
    /// error location, or `nil` for none. Mapped from the server's position.
    var errorCharOffset: Int?
    /// Snapshot of the loaded schema metadata for completion. Evaluated
    /// lazily (and cached briefly) when the user triggers completion, so it
    /// always reflects whatever the browser has loaded so far. `@MainActor`
    /// because it reads the main-actor PgSchemaStore; the completion
    /// delegate runs on the main actor, so this is always satisfied.
    var completionCatalog: @MainActor () -> SQLCompletionCatalog
    /// Called when the current statement references a relation whose columns
    /// aren't loaded yet — the owner may ask PgSchemaStore to fetch them so
    /// the *next* completion has columns. Optional; default no-op.
    var requestColumns: @MainActor (_ schema: String, _ table: String) -> Void = { _, _ in }

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
            context.coordinator.errorCharOffset = errorCharOffset
            context.coordinator.applyHighlighting()
            return
        }

        // Reconcile the error underline (without disturbing the caret) and
        // scroll the offending token into view when it first appears.
        if context.coordinator.errorCharOffset != errorCharOffset {
            context.coordinator.errorCharOffset = errorCharOffset
            context.coordinator.applyHighlighting()
            if let offset = errorCharOffset,
               let range = Coordinator.errorWordRange(in: textView.string, charOffset: offset) {
                textView.scrollRangeToVisible(range)
            }
        }
    }

    private static var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PostgresSQLEditor
        weak var textView: PgSQLTextView?

        // Snapshotting the catalog walks all loaded schema state, and
        // completion fires on most keystrokes — so cache it briefly rather
        // than rebuilding per keystroke.
        private var cachedCatalog = SQLCompletionCatalog.empty
        private var lastCatalogRefresh: Date = .distantPast
        /// Last-applied error-underline offset, so `updateNSView` can detect
        /// changes; cleared the moment the user edits.
        var errorCharOffset: Int?

        init(_ parent: PostgresSQLEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // Any edit invalidates the error underline; drop it before recoloring
            // so a stale red marker never lingers on changed text.
            errorCharOffset = nil
            // Push the edit back through the binding; the parent's setter
            // also revokes AI provenance and the error offset on the query tab.
            if parent.text != textView.string {
                parent.text = textView.string
            }
            applyHighlighting()
        }

        /// Schema-aware completion via `SQLCompletionEngine`: the engine
        /// classifies the cursor context from the full text and returns
        /// ranked, insertion-ready candidates (identifiers pre-quoted).
        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            let now = Date()
            if now.timeIntervalSince(lastCatalogRefresh) > 1.0 {
                cachedCatalog = parent.completionCatalog()
                lastCatalogRefresh = now
            }

            let result = SQLCompletionEngine.complete(
                sql: textView.string,
                cursorUTF16: charRange.location + charRange.length,
                catalog: cachedCatalog
            )

            // Statement references relations whose columns aren't cached →
            // ask the owner to prefetch them, and drop the catalog cache so
            // the next trigger picks the loaded columns up.
            if !result.relationsNeedingColumns.isEmpty {
                lastCatalogRefresh = .distantPast
                for rel in result.relationsNeedingColumns {
                    parent.requestColumns(rel.schema, rel.name)
                }
            }

            // Don't pre-select a row, so fast typing can't accidentally accept.
            index?.pointee = -1
            return result.items.map(\.insertText)
        }

        func applyHighlighting() {
            guard let textView, let storage = textView.textStorage else { return }
            PostgresSQLSyntax.highlight(storage, baseFont: textView.font ?? PostgresSQLEditor.editorFont)
            if let offset = errorCharOffset,
               let range = Self.errorWordRange(in: textView.string, charOffset: offset) {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: range)
                storage.addAttribute(.underlineColor, value: NSColor.systemRed, range: range)
            }
        }

        /// UTF-16 range of the identifier-ish run starting at `charOffset`
        /// (0-based, counted in Characters), guaranteed at least one character.
        /// A position one past the end (e.g. `SELECT 1 +`) underlines the last
        /// character rather than vanishing.
        static func errorWordRange(in text: String, charOffset: Int) -> NSRange? {
            guard !text.isEmpty, charOffset >= 0, charOffset <= text.count else { return nil }
            let clampedOffset = min(charOffset, text.count - 1)
            let start = text.index(text.startIndex, offsetBy: clampedOffset)
            var end = start
            while end < text.endIndex {
                let c = text[end]
                if c.isLetter || c.isNumber || c == "_" {
                    end = text.index(after: end)
                } else {
                    break
                }
            }
            if end == start { end = text.index(after: start) }
            return NSRange(start..<end, in: text)
        }
    }
}

/// NSTextView that pops the completion list as the user types.
///
/// Triggers:
///   - 2+ identifier characters in the current word → debounced ~150 ms so a
///     fast burst of keystrokes schedules one popup, not five.
///   - `.` typed right after an identifier → member completion (columns of
///     the alias/table, relations of the schema), same debounce.
///   - Ctrl-Space → immediate explicit trigger (Esc keeps working natively).
///
/// While the completion list is hidden this view adds no key handling beyond
/// scheduling — AppKit's completion session owns navigation keys only while
/// its window is visible.
final class PgSQLTextView: NSTextView {
    private static let completionDebounce: TimeInterval = 0.15

    private var pendingCompletion: DispatchWorkItem?

    deinit {
        pendingCompletion?.cancel()
    }

    /// The word being completed: the identifier run immediately before the
    /// caret. Overridden so behavior is deterministic (AppKit's default uses
    /// linguistic word boundaries) and so an empty range right after `alias.`
    /// still opens a completion session listing all columns.
    override var rangeForUserCompletion: NSRange {
        let caret = selectedRange().location
        let ns = string as NSString
        guard caret <= ns.length else { return NSRange(location: NSNotFound, length: 0) }
        let start = currentWordStart(before: caret)
        return NSRange(location: start, length: caret - start)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Ctrl-Space: explicit completion trigger.
        if modifiers == [.control], event.charactersIgnoringModifiers == " " {
            pendingCompletion?.cancel()
            complete(self)
            return
        }

        super.keyDown(with: event)

        // Any keystroke supersedes a previously scheduled popup.
        pendingCompletion?.cancel()
        pendingCompletion = nil

        // Only auto-suggest on plain typing (no command/control modifiers).
        guard modifiers.isEmpty || modifiers == [.shift],
              let chars = event.charactersIgnoringModifiers,
              chars.count == 1,
              let scalar = chars.unicodeScalars.first
        else { return }

        let caret = selectedRange().location

        if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
            // ≥2 chars of the current word — enough signal to be useful
            // without flickering on every first letter.
            guard caret - currentWordStart(before: caret) >= 2 else { return }
            scheduleCompletion()
        } else if scalar == "." {
            // `alias.` / `schema.` member completion — only when the dot
            // follows an identifier character (so `1.5` and `...` stay quiet;
            // the engine re-checks context anyway).
            let ns = string as NSString
            guard caret >= 2, caret <= ns.length else { return }
            guard let prev = Unicode.Scalar(UInt32(ns.character(at: caret - 2))),
                  CharacterSet.alphanumerics.contains(prev) || prev == "_" || prev == "\""
            else { return }
            scheduleCompletion()
        }
    }

    private func scheduleCompletion() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil else { return }
            self.complete(nil)
        }
        pendingCompletion = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.completionDebounce, execute: work)
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
