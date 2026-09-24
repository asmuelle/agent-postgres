import Foundation

// =============================================================================
// PostgresSessionPreamble — the text `pgExecute` actually submits: the user's
// SQL behind a `SET default_transaction_read_only = …;` preamble.
//
// The core runs multi-statement input through its smart split: everything up
// to the last top-level `;` goes through `batch_execute`, and the final
// statement through the cursor path. When nothing real follows that last
// `;` (e.g. `SELECT * FROM t;`) the split fails and the whole text falls
// back to the bulk path — no cursor, no column type names, no paging. So
// the user's trailing `;` / whitespace / comment tail is dropped here, and
// server error positions are mapped back onto the user's original text.
//
// Platform-neutral: compiled into both the macOS and iOS apps.
// =============================================================================

struct PostgresSessionPreamble: Sendable, Equatable {
    /// The SQL to submit.
    let sql: String
    /// Characters the preamble adds in front of the user's text.
    private let prefixLength: Int
    /// User-text offset (0-based) and length of the statement that runs on
    /// the cursor path; server positions inside it are relative to it.
    private let mainStart: Int
    private let mainLength: Int
    /// Offset of the first submitted user character in the original text.
    private let submittedStart: Int

    static func wrap(_ userSQL: String, readOnly: Bool) -> PostgresSessionPreamble {
        let statements = PostgresStatementSplitter.split(userSQL)
        guard let first = statements.first, let last = statements.last else {
            // Nothing executable — send as-is so the server reports on it.
            return PostgresSessionPreamble(
                sql: userSQL, prefixLength: 0, mainStart: 0,
                mainLength: userSQL.count, submittedStart: 0
            )
        }
        let prefix = "SET default_transaction_read_only = \(readOnly ? "on" : "off");\n"
        let chars = Array(userSQL)
        let end = last.startCharOffset + last.text.count
        let body = String(chars[first.startCharOffset..<end])
        return PostgresSessionPreamble(
            sql: prefix + body,
            prefixLength: prefix.count,
            mainStart: last.startCharOffset,
            mainLength: last.text.count,
            submittedStart: first.startCharOffset
        )
    }

    /// Map a server-reported 1-based position onto the user's original text.
    /// A position inside the final statement is relative to that statement
    /// (cursor path); anything else is relative to the preamble batch. When
    /// both readings are possible the final statement wins — that is where
    /// errors almost always originate.
    func userPosition(fromServer position: UInt32) -> UInt32? {
        let p = Int(position)
        guard p >= 1 else { return nil }
        if prefixLength == 0 { return position }
        if p <= mainLength { return UInt32(mainStart + p) }
        let batchOffset = p - prefixLength
        guard batchOffset >= 1 else { return nil }
        return UInt32(submittedStart + batchOffset)
    }
}
