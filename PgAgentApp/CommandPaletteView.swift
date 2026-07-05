import AppKit
import SwiftUI

// =============================================================================
// CommandPaletteView — the ⌘K palette. A floating, keyboard-first launcher
// overlaid on the main window (presented from ContentView, the same way the
// workspace layers its other transient chrome — no extra NSWindow/NSPanel).
//
// Sources: connections (focus + connect), tables/views of the active
// connection ("Open schema.table" through the sidebar's existing
// `.openPostgresObjectTab` routing), saved queries (open in a new tab,
// never auto-executed), and app actions.
//
// Keyboard: type to filter (FuzzyMatcher subsequence scoring), ↑/↓ + ↩ to
// run, ⎋ to dismiss. Arrows/return/escape are consumed by a local NSEvent
// monitor that only lives while the palette is on screen — nothing leaks
// into the palette's text field or the window behind it.
// =============================================================================

struct CommandPaletteItem: Identifiable {
    enum Section: String, CaseIterable {
        case connections = "Connections"
        case tables = "Tables & Views"
        case saved = "Saved Queries"
        case actions = "Actions"
    }

    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let section: Section
    let action: @MainActor () -> Void
}

// MARK: - Item building

@MainActor
enum CommandPaletteItems {
    /// Assemble the palette's entries from live app state. Rebuilt each time
    /// the palette opens — cheap (reads already-loaded stores only).
    static func build(
        selectedProfileId: String?,
        selectProfile: @escaping @MainActor (PostgresProfile) -> Void
    ) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        let manager = PostgresConnectionManager.shared

        // Connections — focus the profile and connect if needed (the same
        // path a sidebar click takes).
        for profile in PostgresProfileStore.shared.profiles {
            let isConnected = manager.activeConnections[profile.id] != nil
            items.append(CommandPaletteItem(
                id: "conn:\(profile.id)",
                title: profile.name,
                subtitle: isConnected
                    ? "Connected · \(profile.host)/\(profile.database)"
                    : "Connect · \(profile.host)/\(profile.database)",
                systemImage: isConnected ? "cylinder.split.1x2.fill" : "cylinder.split.1x2",
                section: .connections,
                action: { selectProfile(profile) }
            ))
        }

        // Tables & views of the active connection — routed through the same
        // notification the sidebar/ERD use, so dedupe/autorun behavior is
        // identical to a sidebar double-click.
        if let profileId = selectedProfileId,
           let profile = PostgresProfileStore.shared.profile(withId: profileId),
           let store = manager.schemaStores[profileId] {
            let catalog = store.completionCatalog(database: profile.database)
            let sorted = catalog.relations.sorted {
                ($0.schema, $0.name) < ($1.schema, $1.name)
            }
            for rel in sorted {
                items.append(CommandPaletteItem(
                    id: "rel:\(rel.schema).\(rel.name)",
                    title: "\(rel.schema).\(rel.name)",
                    subtitle: rel.isView ? "Open view" : "Open table",
                    systemImage: rel.isView ? "rectangle.stack" : "tablecells",
                    section: .tables,
                    action: {
                        NotificationCenter.default.post(
                            name: .openPostgresObjectTab,
                            object: nil,
                            userInfo: [
                                "profileId": profileId,
                                "kind": "relation",
                                "schema": rel.schema,
                                "name": rel.name,
                                "autoRun": true,
                            ]
                        )
                    }
                ))
            }

            // Saved queries — open in a new tab for review; never executed
            // from the palette.
            for entry in PostgresSavedQueriesStore.shared.entries(forProfile: profileId) {
                items.append(CommandPaletteItem(
                    id: "saved:\(entry.id.uuidString)",
                    title: entry.name,
                    subtitle: "Saved query · open in new tab",
                    systemImage: "bookmark",
                    section: .saved,
                    action: {
                        NotificationCenter.default.post(
                            name: .openPostgresObjectTab,
                            object: nil,
                            userInfo: [
                                "profileId": profileId,
                                "kind": "sql",
                                "title": entry.name,
                                "sql": entry.sql,
                            ]
                        )
                    }
                ))
            }
        }

        items.append(contentsOf: actionItems(selectedProfileId: selectedProfileId))
        return items
    }

    private static func actionItems(selectedProfileId: String?) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        if let profileId = selectedProfileId {
            items.append(CommandPaletteItem(
                id: "action:new-query-tab",
                title: "New Query Tab",
                subtitle: "⌘T",
                systemImage: "plus.rectangle.on.rectangle",
                section: .actions,
                action: {
                    NotificationCenter.default.post(
                        name: .openPostgresObjectTab,
                        object: nil,
                        userInfo: ["profileId": profileId, "kind": "blank"]
                    )
                }
            ))
            items.append(CommandPaletteItem(
                id: "action:explain-last-query",
                title: "Explain Last Query",
                subtitle: "Visual plan for the active tab's SQL",
                systemImage: "chart.bar.doc.horizontal",
                section: .actions,
                action: {
                    NotificationCenter.default.post(
                        name: .postgresExplainActiveTab, object: nil)
                }
            ))
        }

        items.append(CommandPaletteItem(
            id: "action:open-settings",
            title: "Open Settings",
            subtitle: "⌘,",
            systemImage: "gearshape",
            section: .actions,
            action: { openSettingsWindow() }
        ))
        items.append(CommandPaletteItem(
            id: "action:open-audit-log",
            title: "Open Audit Log",
            subtitle: "Settings · Audit",
            systemImage: "list.bullet.rectangle",
            section: .actions,
            action: {
                SettingsPanelRouter.shared.selectedTab = .audit
                openSettingsWindow()
            }
        ))
        return items
    }

    private static func openSettingsWindow() {
        // SwiftUI's Settings scene has no public programmatic opener on
        // macOS 13; the app-level responder action is the supported bridge.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    /// Ask the frontmost query tab to open its visual EXPLAIN sheet.
    static let postgresExplainActiveTab = Notification.Name("postgresExplainActiveTab")
}

// MARK: - Palette view

struct CommandPaletteView: View {
    let items: [CommandPaletteItem]
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectionIndex = 0
    @State private var keyMonitor: Any?
    @FocusState private var searchFocused: Bool

    /// Rows visible before the list scrolls.
    private static let visibleRows = 12
    private static let rowHeight: CGFloat = 34

    private struct Row: Identifiable {
        enum Kind {
            case header(String)
            case item(CommandPaletteItem, flatIndex: Int)
        }

        let id: String
        let kind: Kind
    }

    /// Section-grouped, fuzzy-filtered items. Section order is fixed;
    /// within a section, matches sort by score.
    private var filteredBySection: [(CommandPaletteItem.Section, [CommandPaletteItem])] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matched: [CommandPaletteItem]
        if trimmed.isEmpty {
            matched = items
        } else {
            matched = items
                .compactMap { item in
                    FuzzyMatcher.score(query: trimmed, candidate: item.title)
                        .map { (item, $0) }
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        return CommandPaletteItem.Section.allCases.compactMap { section in
            let inSection = matched.filter { $0.section == section }
            return inSection.isEmpty ? nil : (section, inSection)
        }
    }

    private var flatItems: [CommandPaletteItem] {
        filteredBySection.flatMap(\.1)
    }

    private var rows: [Row] {
        var rows: [Row] = []
        var flatIndex = 0
        for (section, sectionItems) in filteredBySection {
            rows.append(Row(id: "header:\(section.rawValue)", kind: .header(section.rawValue)))
            for item in sectionItems {
                rows.append(Row(id: item.id, kind: .item(item, flatIndex: flatIndex)))
                flatIndex += 1
            }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if flatItems.isEmpty {
                emptyState
            } else {
                resultsList
            }
            Divider()
            footer
        }
        .frame(width: 580)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 28, y: 10)
        .onAppear {
            searchFocused = true
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: query) { _ in selectionIndex = 0 }
    }

    // MARK: Subviews

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                "Search connections, tables, saved queries, actions…",
                text: $query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .focused($searchFocused)
            Text("⌘K")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        switch row.kind {
                        case .header(let title):
                            Text(title.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                        case .item(let item, let flatIndex):
                            itemRow(item, isSelected: flatIndex == selectionIndex)
                                .id(row.id)
                                .onTapGesture { activate(item) }
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: CGFloat(Self.visibleRows) * Self.rowHeight)
            .onChange(of: selectionIndex) { newIndex in
                guard flatItems.indices.contains(newIndex) else { return }
                proxy.scrollTo(flatItems[newIndex].id, anchor: nil)
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: CommandPaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .font(.system(size: 13))
                .frame(width: 20)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 12)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text("No matches")
                .font(.callout)
            Text("Try a connection name, schema.table, a saved query, or an action like “New Query Tab”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label("navigate", systemImage: "arrow.up.arrow.down")
            Label("open", systemImage: "return")
            Label("dismiss", systemImage: "escape")
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: // ↓
                moveSelection(by: 1)
                return nil
            case 126: // ↑
                moveSelection(by: -1)
                return nil
            case 36, 76: // ↩ / keypad enter
                activateSelection()
                return nil
            case 53: // ⎋
                onDismiss()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func moveSelection(by delta: Int) {
        let count = flatItems.count
        guard count > 0 else { return }
        selectionIndex = (selectionIndex + delta + count) % count
    }

    private func activateSelection() {
        guard flatItems.indices.contains(selectionIndex) else { return }
        activate(flatItems[selectionIndex])
    }

    private func activate(_ item: CommandPaletteItem) {
        onDismiss()
        item.action()
    }
}
