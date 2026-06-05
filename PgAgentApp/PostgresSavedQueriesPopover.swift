import SwiftUI

// =============================================================================
// PostgresSavedQueriesPopover — bookmarks for SQL the user wants to keep.
//
// Anchored to a "Saved" toolbar button on the query tab, just like the
// history popover. Header has a "+" that toggles an inline name field
// for saving the editor's current SQL.
// =============================================================================

struct PostgresSavedQueriesPopover: View {
    let profileId: String
    /// Current editor text — used as the body of a new "Save current"
    /// entry. Read-only for the popover; the user can save it under
    /// any name.
    let currentSql: String
    /// Invoked when the user picks a saved entry — typically to
    /// replace the editor's text.
    let onPick: (PostgresSavedQuery) -> Void
    let onDismiss: () -> Void

    @ObservedObject var store: PostgresSavedQueriesStore = .shared

    @State private var showSaveField: Bool = false
    @State private var newName: String = ""
    @State private var filter: String = ""
    @State private var editingEntry: PostgresSavedQuery? = nil
    @FocusState private var saveFieldFocused: Bool

    private var entries: [PostgresSavedQuery] {
        let all = store.entries(forProfile: profileId)
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(needle)
                || $0.sql.lowercased().contains(needle)
        }
    }

    private var canSaveCurrent: Bool {
        !currentSql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        rootContent
            .sheet(item: $editingEntry) { entry in
                PostgresSavedQueryEditSheet(original: entry) { updated in
                    store.update(updated)
                }
            }
    }

    private var rootContent: some View {
        VStack(spacing: 0) {
            header
            if showSaveField {
                Divider()
                saveForm
            }
            // Show the filter only when there are enough entries to
            // make scanning awkward — same threshold as the history
            // popover for consistency.
            if store.entries(forProfile: profileId).count > 5 {
                Divider()
                filterField
            }
            Divider()
            if entries.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 240, idealHeight: 320, maxHeight: 480)
            }
        }
        .frame(width: 460)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.tint)
            Text("Saved queries")
                .font(.headline)
            Spacer()
            Button {
                showSaveField.toggle()
                if showSaveField {
                    newName = ""
                    // Defer focus to the next runloop so the field
                    // is mounted before we ask for first responder.
                    DispatchQueue.main.async { saveFieldFocused = true }
                }
            } label: {
                Image(systemName: showSaveField ? "xmark" : "plus")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(canSaveCurrent
                  ? (showSaveField ? "Cancel save" : "Save current SQL")
                  : "Type SQL in the editor to save it")
            .disabled(!canSaveCurrent && !showSaveField)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var saveForm: some View {
        HStack(spacing: 6) {
            TextField("Name (e.g. \"list locks\")", text: $newName)
                .textFieldStyle(.roundedBorder)
                .focused($saveFieldFocused)
                .onSubmit { commitSave() }
            Button("Save") { commitSave() }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !canSaveCurrent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Filter name or SQL", text: $filter)
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
            Image(systemName: "bookmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No saved queries yet")
                .font(.callout)
            Text("Use the + button to bookmark the SQL above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func row(_ entry: PostgresSavedQuery) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(relativeTime(entry.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(preview(entry.sql))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onPick(entry)
            onDismiss()
        }
        .contextMenu {
            Button("Use") {
                onPick(entry)
                onDismiss()
            }
            Button("Edit…") {
                editingEntry = entry
            }
            Button("Copy SQL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.sql, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.remove(entryId: entry.id, fromProfile: profileId)
            }
        }
    }

    // MARK: - Actions

    private func commitSave() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canSaveCurrent else { return }
        store.add(profileId: profileId, name: trimmed, sql: currentSql)
        newName = ""
        showSaveField = false
    }

    // MARK: - Formatting

    private func preview(_ sql: String) -> String {
        sql.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
