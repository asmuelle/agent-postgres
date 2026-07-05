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

extension Notification.Name {
    /// Ask a `PostgresSQLEditor` to insert a snippet body at the caret and
    /// start its placeholder session. `userInfo`: `channel` (the target
    /// editor's `snippetChannel`) and `body` (raw snippet text with
    /// `${n:default}` markup). Editors without a matching channel ignore it.
    static let pgSQLEditorInsertSnippet = Notification.Name("pgSQLEditorInsertSnippet")
}

struct PostgresSQLEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    /// Identity for snippet-insertion routing (the owning query tab's id
    /// string). `nil` — the default for other hosts of this editor — opts
    /// out of snippet notifications entirely.
    var snippetChannel: String? = nil
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
            // A wholesale replacement invalidates any snippet tab-stop
            // ranges — end the session before the text changes under it.
            textView.endSnippetSession()
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
        private var snippetObserver: NSObjectProtocol?

        init(_ parent: PostgresSQLEditor) {
            self.parent = parent
            super.init()
            // Snippet insertion requests are broadcast (the popover and the
            // command palette don't hold a reference to the NSTextView);
            // the channel id routes them to the right editor instance.
            snippetObserver = NotificationCenter.default.addObserver(
                forName: .pgSQLEditorInsertSnippet,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      let channel = self.parent.snippetChannel,
                      (note.userInfo?["channel"] as? String) == channel,
                      let body = note.userInfo?["body"] as? String,
                      let textView = self.textView,
                      textView.isEditable
                else { return }
                textView.insertSnippet(PostgresSnippetPlaceholders.parse(body))
            }
        }

        deinit {
            if let snippetObserver {
                NotificationCenter.default.removeObserver(snippetObserver)
            }
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

    // MARK: - Snippet placeholder session

    /// Live tab-stop state for the most recent snippet insertion. Ranges
    /// are absolute UTF-16 locations in the buffer, maintained across
    /// edits by `shouldChangeText`. One session at a time — inserting a
    /// new snippet replaces any active session.
    private struct SnippetSession {
        var stops: [NSRange]
        var current: Int
        var finalCursor: Int?
    }

    private var snippetSession: SnippetSession?

    deinit {
        pendingCompletion?.cancel()
    }

    /// Insert an expanded snippet at the caret (replacing any selection),
    /// then select the first tab stop. Tab / ⇧Tab move between stops while
    /// the session is active; Esc — or tabbing past the last stop — ends it
    /// (the caret then lands on `$0` when the snippet defined one).
    func insertSnippet(_ parsed: PostgresParsedSnippet) {
        snippetSession = nil
        let replaceRange = selectedRange()
        let base = replaceRange.location
        // Goes through the normal editing pipeline: undoable, fires
        // shouldChangeText/didChangeText, and lands in the SwiftUI binding
        // via the delegate's textDidChange.
        insertText(parsed.text, replacementRange: replaceRange)

        let stops = parsed.tabStops.map {
            NSRange(location: base + $0.location, length: $0.length)
        }
        let finalCursor = parsed.finalCursorUTF16.map { base + $0 }
        let target: NSRange
        if let first = stops.first {
            snippetSession = SnippetSession(stops: stops, current: 0, finalCursor: finalCursor)
            target = first
        } else {
            target = NSRange(
                location: finalCursor ?? base + (parsed.text as NSString).length,
                length: 0
            )
        }
        setSelectedRange(target)
        // The insertion usually comes from a popover / palette that holds
        // first responder; take it (back) so Tab lands here. Deferred one
        // runloop turn so the dismissing popover can't steal it right back.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            self.setSelectedRange(target)
            self.scrollRangeToVisible(target)
        }
    }

    func endSnippetSession() {
        snippetSession = nil
    }

    /// Move to the stop `delta` away from the current one. Advancing past
    /// the last stop jumps to `$0` (or stays put) and ends the session;
    /// moving before the first clamps.
    private func moveSnippetStop(by delta: Int) {
        guard var session = snippetSession else { return }
        let next = session.current + delta
        if next >= session.stops.count {
            let end = session.finalCursor
                ?? session.stops.last.map { $0.location + $0.length }
            snippetSession = nil
            if let end {
                let clamped = min(end, (string as NSString).length)
                setSelectedRange(NSRange(location: clamped, length: 0))
            }
            return
        }
        session.current = max(0, next)
        snippetSession = session
        let range = session.stops[session.current]
        setSelectedRange(range)
        scrollRangeToVisible(range)
    }

    /// Keep tab-stop ranges in sync with edits. Typing inside the current
    /// stop grows/shrinks it; edits before a stop shift it; an edit that
    /// overlaps any *other* stop (multi-line paste, undo of the insertion
    /// itself) invalidates the session rather than guessing.
    override func shouldChangeText(
        in affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        let allowed = super.shouldChangeText(
            in: affectedCharRange, replacementString: replacementString
        )
        guard allowed, var session = snippetSession else { return allowed }

        let delta = ((replacementString ?? "") as NSString).length - affectedCharRange.length
        let affectedEnd = affectedCharRange.location + affectedCharRange.length
        var invalidated = false

        for i in session.stops.indices {
            let stop = session.stops[i]
            let stopEnd = stop.location + stop.length
            if i == session.current,
               affectedCharRange.location >= stop.location,
               affectedEnd <= stopEnd {
                session.stops[i].length += delta
            } else if affectedEnd <= stop.location {
                session.stops[i].location += delta
            } else if affectedCharRange.location >= stopEnd {
                // Entirely after this stop — unaffected.
            } else {
                invalidated = true
                break
            }
        }

        if invalidated {
            snippetSession = nil
            return allowed
        }
        if let finalCursor = session.finalCursor {
            if affectedEnd <= finalCursor {
                session.finalCursor = finalCursor + delta
            } else if affectedCharRange.location < finalCursor {
                // Edit swallowed the final-cursor position; approximate to
                // the end of the replacement.
                session.finalCursor = affectedCharRange.location
                    + ((replacementString ?? "") as NSString).length
            }
        }
        snippetSession = session
        return allowed
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

        // Snippet placeholder session: Tab advances, ⇧Tab goes back, Esc
        // deactivates (consumed so it doesn't also trigger completion).
        // Only while a session is active — otherwise Tab stays a tab.
        if snippetSession != nil {
            if event.keyCode == 48 { // Tab
                if modifiers.isEmpty {
                    moveSnippetStop(by: 1)
                    return
                }
                if modifiers == [.shift] {
                    moveSnippetStop(by: -1)
                    return
                }
            }
            if event.keyCode == 53 { // Esc
                endSnippetSession()
                return
            }
        }

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
