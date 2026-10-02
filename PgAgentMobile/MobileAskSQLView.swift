import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileAskSQLView — "Ask": describe the data you want in plain English, get
// one PostgreSQL statement written on this device (Apple Intelligence,
// grounded in the current schema by PgSchemaContextBuilder). The SQL is shown
// for reading first and only lands in the editor on "Use" — it is never run
// for you, and a statement that would change data says so.
// =============================================================================
struct MobileAskSQLView: View {
    let connectionId: String
    let defaultSchema: String
    let onUse: (String) -> Void

    @StateObject private var store = PgAINLToSQLStore()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var promptFocused: Bool

    private var trimmedPrompt: String {
        store.naturalLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "e.g. customers who ordered in the last 7 days",
                        text: $store.naturalLanguage,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                    .focused($promptFocused)
                    .submitLabel(.go)
                    .onSubmit(generate)
                } footer: {
                    Text("Written on this device from your “\(defaultSchema)” schema. Nothing runs until you press Run.")
                }

                phaseContent
            }
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .result(let result) = store.phase {
                        Button("Use") {
                            onUse(result.sql)
                            dismiss()
                        }
                        .disabled(result.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button("Write SQL", action: generate)
                            .disabled(trimmedPrompt.isEmpty || store.phase == .thinking)
                    }
                }
            }
            .onAppear { promptFocused = true }
            // Editing the request makes the previous answer stale.
            .onChange(of: store.naturalLanguage) { _, _ in
                if case .result = store.phase { store.present() }
            }
        }
        // Cancel / swipe-down: stop the model and the schema lookups.
        .onDisappear { store.dismiss() }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch store.phase {
        case .composing:
            EmptyView()
        case .thinking:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Writing SQL…")
                        .foregroundStyle(.secondary)
                }
            }
        case .result(let result):
            Section {
                HighlightedSQLText(sql: result.sql)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                if !PgReadOnlyGuard.isReadOnly(result.sql) {
                    Label {
                        Text("This statement changes data. Run will ask before running it.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("SQL")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.explanation)
                    Button("Try Again", action: generate)
                        .font(.footnote)
                }
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func generate() {
        guard !trimmedPrompt.isEmpty else { return }
        promptFocused = false
        store.generate(connectionId: connectionId, defaultSchema: defaultSchema)
    }
}
