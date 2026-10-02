import SwiftUI
import UIKit

// =============================================================================
// MobileSQLCodeEditor — UITextView-backed SQL / plpgsql editor with the same
// syntax highlighting as the macOS PostgresSQLEditor (shared
// SQLSyntaxHighlighting over NSTextStorage), plus an optional error underline
// at a server-reported character offset.
//
// The text view owns its text; the binding is only written on edits and only
// pushed back in when it changes from outside. (A SwiftUI TextEditor bound
// through the query store re-rendered mid-typing and dropped or reordered
// fast keystrokes — "alert" typed quickly came out "lrtea".)
//
// Optional hooks drive the query workspace: focus changes (the editor grows
// while you type), caret moves (schema-aware completion), and a controller
// that inserts a picked completion exactly as typing would, undo included.
// =============================================================================
struct MobileSQLCodeEditor: UIViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    /// 0-based character offset to underline in red (server error position),
    /// or `nil` for none. The underline extends to the end of the word.
    var errorCharOffset: Int? = nil
    var controller: MobileSQLEditorController? = nil
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Text and caret (UTF-16) after every edit or caret move; the caret is
    /// `nil` while a range is selected.
    var onCaretChange: ((_ text: String, _ cursorUTF16: Int?) -> Void)? = nil

    /// Monospaced, scaled with Dynamic Type. Read on every highlight pass so
    /// a text-size change applies to the next keystroke.
    static var baseFont: UIFont {
        UIFontMetrics(forTextStyle: .callout).scaledFont(
            for: .monospacedSystemFont(ofSize: 15, weight: .regular)
        )
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = Self.baseFont
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.inlinePredictionType = .no
        view.keyboardType = .asciiCapable
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.accessibilityLabel = "SQL"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // Closures and the binding change with every render — keep the
        // coordinator pointed at the current ones.
        context.coordinator.parent = self
        controller?.textView = view
        view.isEditable = isEditable
        if view.text != text {
            // External change (tab switch, load, inserted query) — replace
            // and re-highlight while keeping the caret where possible. Caret
            // reports are muted: this runs inside a SwiftUI update.
            context.coordinator.isApplyingExternalChange = true
            let selected = view.selectedRange
            view.text = text
            // Old undo steps point into text that no longer exists.
            view.undoManager?.removeAllActions()
            context.coordinator.highlight(view)
            let caret = min(selected.location, (text as NSString).length)
            view.selectedRange = NSRange(location: caret, length: 0)
            context.coordinator.isApplyingExternalChange = false
        }
        context.coordinator.applyErrorUnderline(view, at: errorCharOffset)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MobileSQLCodeEditor
        /// True while the editor applies its own changes (external text,
        /// re-highlighting) so those don't read as caret moves.
        var isApplyingExternalChange = false
        /// The error underline last scrolled to, so later renders (e.g. a
        /// caret move) don't yank the view back to it.
        private var scrolledError: (offset: Int, text: String)?

        init(_ parent: MobileSQLCodeEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ view: UITextView) {
            // Always write through: the binding's getter is a snapshot from
            // the last render, so comparing against it can drop an edit
            // that lands before SwiftUI re-renders (type, then delete).
            parent.text = view.text
            highlight(view)
            reportCaret(view)
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            reportCaret(view)
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            parent.onFocusChange?(true)
            reportCaret(view)
        }

        func textViewDidEndEditing(_ view: UITextView) {
            parent.onFocusChange?(false)
        }

        private func reportCaret(_ view: UITextView) {
            guard !isApplyingExternalChange, let onCaretChange = parent.onCaretChange else { return }
            let selection = view.selectedRange
            onCaretChange(view.text, selection.length == 0 ? selection.location : nil)
        }

        func highlight(_ view: UITextView) {
            // Re-coloring must not move the caret.
            let wasApplying = isApplyingExternalChange
            isApplyingExternalChange = true
            let selected = view.selectedRange
            SQLSyntaxHighlighting.highlight(view.textStorage, baseFont: MobileSQLCodeEditor.baseFont)
            view.selectedRange = selected
            isApplyingExternalChange = wasApplying
        }

        /// Red squiggle from `offset` to the end of the token (mirrors the mac
        /// editor's error underline). `offset` is a 0-based code-point offset,
        /// as Postgres reports positions — converted to the text view's UTF-16
        /// range by the shared helper, so emoji / CRLF before the error don't
        /// shift it. Highlighting resets attributes on every edit, so stale
        /// underlines clear themselves.
        func applyErrorUnderline(_ view: UITextView, at offset: Int?) {
            guard let offset,
                  let range = SQLSyntaxHighlighting.errorWordRange(in: view.text, codePointOffset: offset)
            else { return }
            view.textStorage.addAttributes(
                [
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: UIColor.systemRed,
                ],
                range: range
            )
            if scrolledError?.offset != offset || scrolledError?.text != view.text {
                scrolledError = (offset, view.text)
                view.scrollRangeToVisible(range)
            }
        }
    }
}

/// Lets SwiftUI act on the editor's text view: apply a completion as if it
/// were typed (one undo step, binding and highlighting kept in sync).
@MainActor
final class MobileSQLEditorController {
    fileprivate(set) weak var textView: UITextView?

    /// Put the keyboard away (e.g. on Run, so results get the screen).
    func resignFocus() {
        textView?.resignFirstResponder()
    }

    /// Insert a picked completion at the caret, replacing the word there.
    func insert(_ item: SQLCompletionItem) {
        guard let textView else { return }
        let caret = textView.selectedRange.location
        apply(SQLCompletionInsertion.edit(for: item, in: textView.text, cursorUTF16: caret))
    }

    func apply(_ edit: SQLCompletionInsertion.Edit) {
        guard let textView,
              let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
              let end = textView.position(from: start, offset: edit.range.length),
              let range = textView.textRange(from: start, to: end)
        else { return }
        textView.replace(range, withText: edit.replacement)
        // Programmatic replacement doesn't always reach the delegate; sync
        // explicitly (the delegate's work is idempotent).
        textView.delegate?.textViewDidChange?(textView)
    }
}
