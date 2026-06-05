import SwiftUI

// =============================================================================
// PostgresHistoryPopover — recent SQL list anchored to a query tab's
// editor toolbar.
//
// Click an entry → fills the editor (replaces current text). Right-click →
// "Run again" / "Insert without replacing" / "Delete" / "Clear all".
// Newest entries on top; the popover is read-only otherwise (no inline
// editing of stored SQL).
// =============================================================================

struct PostgresHistoryPopover: View {
    let profileId: String
    @ObservedObject var store: PostgresHistoryStore = .shared

    /// Invoked when the user picks an entry. The host view decides
    /// whether to replace the editor contents, append, or run
    /// immediately. Sprint 8 default: replace.
    let onPick: (PostgresHistoryEntry) -> Void
    /// Closes the popover. Wired to a binding from the host so item
    /// taps dismiss without bubbling through `dismiss`.
    let onDismiss: () -> Void

    @State private var filter: String = ""
    /// When true, the filter searches across every profile's history
    /// (not just the current one). Useful for "I ran this against
    /// some database last week" style recall.
    @State private var searchAllProfiles: Bool = false

    @ObservedObject private var profileStore = PostgresProfileStore.shared

    private var entries: [PostgresHistoryEntry] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if searchAllProfiles {
            // Cross-profile search only makes sense with a needle —
            // an empty filter would dump every entry from every
            // profile. The "Search all profiles" toggle is hidden
            // until the user types a filter.
            guard !needle.isEmpty else { return [] }
            return store.searchAcrossProfiles(needle: needle)
        }
        let all = store.entries(forProfile: profileId)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.sql.lowercased().contains(needle) }
    }

    /// Resolve a profile id → display name for cross-profile rows.
    /// Falls back to the id if the profile was deleted but its
    /// history file lingered.
    private func profileName(forId id: String) -> String {
        profileStore.profile(withId: id)?.name ?? "(unknown)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Filter only appears when there's enough history to
            // benefit from it. Below the threshold the user can
            // eyeball the list directly.
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
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.tint)
            Text("Query history")
                .font(.headline)
            Spacer()
            if !entries.isEmpty {
                Button("Clear", role: .destructive) {
                    store.clear(profileId: profileId)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.red)
                .help("Delete all history for this profile")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var filterField: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Filter SQL", text: $filter)
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
            // Cross-profile search only appears once the user is
            // typing — it's an opt-in widening for "find that query
            // I ran on some other DB" recall.
            if !filter.isEmpty {
                HStack(spacing: 6) {
                    Toggle("Search all profiles", isOn: $searchAllProfiles)
                        .toggleStyle(.checkbox)
                        .controlSize(.mini)
                        .font(.system(size: 11))
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No history yet")
                .font(.callout)
            Text("Successful queries will show up here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func row(_ entry: PostgresHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if searchAllProfiles && entry.profileId != profileId {
                    // Tag cross-profile rows so the user knows
                    // they'd be loading SQL meant for a different
                    // database.
                    Text(profileName(forId: entry.profileId))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                Text(relativeTime(entry.executedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let ms = entry.durationMs {
                    Text(formatDuration(ms))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let rows = entry.rowsReturned {
                    Text(rows == 1 ? "1 row" : "\(rows) rows")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(preview(entry.sql))
                .font(.system(.caption, design: .monospaced))
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

    // MARK: - Formatting

    /// Compact preview — collapse newlines so the row reads as one
    /// thought, even for `SELECT … \n FROM …` style SQL.
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

    private func formatDuration(_ ms: UInt32) -> String {
        if ms < 1_000 { return "\(ms)ms" }
        let s = Double(ms) / 1_000.0
        if s < 60 { return String(format: "%.2fs", s) }
        return String(format: "%.0fs", s)
    }
}
