import SwiftUI

/// The suggestion bar under the SQL editor: schema-aware completions from
/// SQLCompletionEngine, one tap to insert.
struct MobileCompletionBar: View {
    let items: [SQLCompletionItem]
    let onPick: (SQLCompletionItem) -> Void

    /// Same height empty or full, so the controls below never jump.
    private static let minimumHeight: CGFloat = 52

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button {
                        onPick(item)
                    } label: {
                        Label(item.insertText, systemImage: symbol(for: item.kind))
                            .font(.callout.monospaced())
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityLabel("Insert \(item.insertText)")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        // New suggestions start scrolled to the best match.
        .id(items.map(\.insertText))
        .frame(minHeight: Self.minimumHeight)
        .background(MidnightColors.recessedFill)
    }

    private func symbol(for kind: SQLCompletionItem.Kind) -> String {
        switch kind {
        case .keyword: return "textformat"
        case .function: return "function"
        case .type: return "number"
        case .schema: return "square.stack.3d.up"
        case .relation: return "tablecells"
        case .column: return "list.bullet"
        case .alias: return "at"
        }
    }
}
