import SwiftUI

// =============================================================================
// PgAINLToSQLView — "Generate SQL from a description" sheet.
//
// A persistent prompt area at the top (so the user can iterate), and below it
// the generated statement with a read/write badge, explanation, the tables it
// touches, and a one-tap insert into the editor. The read/write badge is
// computed locally with PgReadOnlyGuard — the authoritative answer, not the
// model's self-report — so the user knows before running whether it writes.
// =============================================================================

struct PgAINLToSQLView: View {
    @ObservedObject var store: PgAINLToSQLStore
    let connectionId: String
    let defaultSchema: String
    /// Replace the editor's SQL with the generated statement.
    let onInsert: (String) -> Void

    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    promptArea
                    resultArea
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 540)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { promptFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Generate SQL")
                    .font(.headline)
                Text("On-device · private · grounded in your schema")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Prompt

    private var promptArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe the query")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if store.naturalLanguage.isEmpty {
                    Text("e.g. top 10 customers by total order value in the last 30 days")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $store.naturalLanguage)
                    .font(.body)
                    .focused($promptFocused)
                    .frame(height: 72)
                    .scrollContentBackground(.hidden)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.25), lineWidth: 1)
            )

            HStack {
                Spacer()
                Button {
                    store.generate(connectionId: connectionId, defaultSchema: defaultSchema)
                } label: {
                    Label(isFollowUp ? "Regenerate" : "Generate", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canGenerate)
                .help("Generate SQL (⌘↵)")
            }
        }
    }

    private var canGenerate: Bool {
        if case .thinking = store.phase { return false }
        return !store.naturalLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isFollowUp: Bool {
        switch store.phase {
        case .result, .failed: return true
        default: return false
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultArea: some View {
        switch store.phase {
        case .composing:
            EmptyView()
        case .thinking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading your schema and writing SQL…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        case .result(let result):
            resultDetail(result)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resultDetail(_ result: PgGeneratedSQLResult) -> some View {
        let isReadOnly = PgReadOnlyGuard.isReadOnly(result.sql)
        return VStack(alignment: .leading, spacing: 14) {
            Divider()

            HStack(spacing: 8) {
                accessBadge(isReadOnly: isReadOnly)
                if !result.tablesUsed.isEmpty {
                    Text(result.tablesUsed.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text(result.explanation)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Text(result.sql)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.tint.opacity(0.25), lineWidth: 1)
                )

            if !isReadOnly {
                Label("This statement modifies data. Review it before running.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button {
                    onInsert(result.sql)
                    store.dismiss()
                } label: {
                    Label("Insert into editor", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func accessBadge(isReadOnly: Bool) -> some View {
        Label(
            isReadOnly ? "Read-only" : "Modifies data",
            systemImage: isReadOnly ? "lock.shield" : "pencil.circle"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(isReadOnly ? Color.green : Color.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill((isReadOnly ? Color.green : Color.orange).opacity(0.12))
        )
    }
}
