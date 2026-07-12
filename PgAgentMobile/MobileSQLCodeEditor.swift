import SwiftUI
import UIKit

// =============================================================================
// MobileSQLCodeEditor — UITextView-backed SQL/plpgsql editor with the same
// syntax highlighting as the macOS PostgresSQLEditor (shared
// SQLSyntaxHighlighting over NSTextStorage), plus an optional error underline
// at a server-reported character offset.
//
// Deliberately lighter than the mac editor: no autocomplete popover, no
// snippet placeholders — those are keyboard-driven affordances. Highlighting
// re-runs on every edit; the shared regex passes are fast enough for routine
// bodies (same per-keystroke strategy as macOS).
// =============================================================================
struct MobileSQLCodeEditor: UIViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    /// 0-based character offset to underline in red (server error position),
    /// or `nil` for none. The underline extends to the end of the word.
    var errorCharOffset: Int? = nil

    private static let baseFont = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = Self.baseFont
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardType = .asciiCapable
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.isEditable = isEditable
        if view.text != text {
            // External change (load/revert) — replace and re-highlight while
            // preserving the caret where possible.
            let selected = view.selectedRange
            view.text = text
            context.coordinator.highlight(view)
            let caret = min(selected.location, (text as NSString).length)
            view.selectedRange = NSRange(location: caret, length: 0)
        }
        context.coordinator.applyErrorUnderline(view, at: errorCharOffset)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: MobileSQLCodeEditor

        init(_ parent: MobileSQLCodeEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            highlight(view)
        }

        func highlight(_ view: UITextView) {
            // Re-coloring must not move the caret.
            let selected = view.selectedRange
            SQLSyntaxHighlighting.highlight(view.textStorage, baseFont: MobileSQLCodeEditor.baseFont)
            view.selectedRange = selected
        }

        /// Red squiggle from `offset` to the end of the token (mirrors the mac
        /// editor's error underline). Highlighting resets attributes on every
        /// edit, so stale underlines clear themselves.
        func applyErrorUnderline(_ view: UITextView, at offset: Int?) {
            guard let offset else { return }
            let nsText = view.text as NSString
            guard offset >= 0, offset < nsText.length else { return }
            var end = offset
            let alphanumerics = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
            while end < nsText.length,
                  let scalar = Unicode.Scalar(nsText.character(at: end)),
                  alphanumerics.contains(scalar) {
                end += 1
            }
            let range = NSRange(location: offset, length: max(1, end - offset))
            view.textStorage.addAttributes(
                [
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: UIColor.systemRed,
                ],
                range: range
            )
            view.scrollRangeToVisible(range)
        }
    }
}
