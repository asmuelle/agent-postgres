import SwiftUI

// =============================================================================
// PostgresSnippetsPopover — the snippet library: insert-at-caret plus a
// lightweight manager (add / edit / delete), anchored to the "Snippets"
// button in the SQL editor's toolbar. Deliberately *not* part of
// SettingsView — snippets belong next to the editor that consumes them.
//
// Clicking a snippet inserts its body at the editor caret and starts the
// placeholder session (Tab between `${n:default}` stops — see
// PostgresSnippetPlaceholders / PgSQLTextView).
// =============================================================================

struct PostgresSnippetsPopover: View {
    /// Invoked when the user picks a snippet — the host routes the body to
    /// the editor's snippet channel.
    let onInsert: (PostgresSnippet) -> Void
    let onDismiss: () -> Void

    @ObservedObject var store: PostgresSnippetsStore = .shared

    @State private var filter: String = ""
    @State private var editingSnippet: PostgresSnippet? = nil
    @State private var isCreating: Bool = false

    private var snippets: [PostgresSnippet] {
        let all = store.all()
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.title.lowercased().contains(needle)
                || $0.body.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.all().count > 5 {
                Divider()
                filterField
            }
            Divider()
            if snippets.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(snippets) { snippet in
                        row(snippet)
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 240, idealHeight: 320, maxHeight: 480)
            }
            Divider()
            footerHint
        }
        .frame(width: 460)
        .sheet(item: $editingSnippet) { snippet in
            PostgresSnippetEditSheet(
                title: "Edit snippet",
                initialTitle: snippet.title,
                initialBody: snippet.body
            ) { newTitle, newBody in
                var updated = snippet
                updated.title = newTitle
                updated.body = newBody
                store.update(updated)
            }
        }
        .sheet(isPresented: $isCreating) {
            PostgresSnippetEditSheet(
                title: "New snippet",
                initialTitle: "",
                initialBody: ""
            ) { newTitle, newBody in
                store.add(title: newTitle, body: newBody)
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "curlybraces")
                .foregroundStyle(.tint)
            Text("Snippets")
                .font(.headline)
            Spacer()
            Button {
                isCreating = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New snippet")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Filter title or body", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "curlybraces")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No snippets")
                .font(.callout)
            Text("Use the + button to add one. Bodies support ${1:placeholder} tab stops.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var footerHint: some View {
        Text("Click to insert at the caret · Tab jumps between ${n:placeholders} · Esc exits")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ snippet: PostgresSnippet) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(snippet.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if PostgresSnippetPlaceholders.containsPlaceholders(snippet.body) {
                    Image(systemName: "arrow.right.to.line")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Contains tab-stop placeholders")
                }
            }
            Text(preview(snippet.body))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onInsert(snippet)
            onDismiss()
        }
        .contextMenu {
            Button("Insert") {
                onInsert(snippet)
                onDismiss()
            }
            Button("Edit…") {
                editingSnippet = snippet
            }
            Button("Copy Body") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snippet.body, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.remove(id: snippet.id)
            }
        }
    }

    private func preview(_ body: String) -> String {
        body.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// =============================================================================
// PostgresSnippetEditSheet — add/edit form. Title + body with a syntax hint;
// shared by the create and edit flows.
// =============================================================================

struct PostgresSnippetEditSheet: View {
    let title: String
    let initialTitle: String
    let initialBody: String
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftTitle: String = ""
    @State private var draftBody: String = ""

    private var canSave: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField("Title", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $draftBody)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
            Text("Placeholders: ${1:default} tab stops in number order, $0 marks the final caret, \\$ for a literal dollar sign.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draftTitle, draftBody)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            draftTitle = initialTitle
            draftBody = initialBody
        }
    }
}
