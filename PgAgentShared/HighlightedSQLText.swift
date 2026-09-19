import SwiftUI

/// Read-only, syntax-highlighted SQL (e.g. the Property Inspector's "DDL
/// Source" tab). Highlights once per distinct `sql` value rather than on every
/// body evaluation, and shows the plain text until that pass lands so a
/// change never flashes an empty view.
struct HighlightedSQLText: View {
    let sql: String

    @State private var highlighted = AttributedString()
    @State private var highlightedSource: String?

    var body: some View {
        Group {
            if highlightedSource == sql {
                Text(highlighted)
            } else {
                Text(sql)
            }
        }
        .task(id: sql) {
            highlighted = SQLSyntaxHighlighting.attributedString(sql)
            highlightedSource = sql
        }
    }
}
