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

    // MARK: - Highlighting

    /// Forwards to the platform-neutral highlighter (PgAgentShared), which the
    /// iPad code editor shares. Kept for existing call sites and tests.
    static func highlight(_ storage: NSTextStorage, baseFont: NSFont) {
        SQLSyntaxHighlighting.highlight(storage, baseFont: baseFont)
    }
}
