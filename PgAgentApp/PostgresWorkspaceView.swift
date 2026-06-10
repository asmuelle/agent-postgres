import PgAgentMacOS
import SwiftUI

// =============================================================================
// PostgresWorkspaceView — the top-level surface for one Postgres profile.
//
// Layout: HSplitView with the schema browser on the left (320pt ideal)
// and the query tabs container on the right. Connection identity is
// owned by the browser (it runs the connect/disconnect lifecycle) but
// surfaced here via a @State so query tabs can read it. New tabs come
// from two paths:
//   - Sidebar's "+" button → blank tab.
//   - Double-click on a relation → tab populated with
//     `SELECT * FROM "schema"."name" LIMIT 200`.
// =============================================================================

struct PostgresWorkspaceView: View {
    let profile: PostgresProfile
    @Binding var connectionId: String?
    @Binding var selectedNode: PgSchemaNode?
    @Binding var schemaStore: PgSchemaStore?

    @StateObject private var queryStore = PostgresQueryTabsStore()
    @State private var isPresentingWizard = false
    @State private var isPresentingBackupRestore = false
    @State private var wizardDefaultSchema = "public"

    /// Close a tab and release its session's pooled connection.
    /// Closes any active cursor first so the connection returns to
    /// idle in a clean state — important so the next session that
    /// leases this connection doesn't inherit a stuck transaction.
    private func closeTab(_ tab: PostgresQueryTab) {
        if let connId = connectionId {
            let sessionId = tab.id.uuidString
            let cursorId = tab.lastResult?.cursorId
            let shouldCancel: Bool
            if case .running = tab.execState {
                shouldCancel = true
            } else {
                shouldCancel = false
            }
            Task.detached {
                if shouldCancel {
                    _ = await BridgeManager.shared.pgCancel(
                        connectionId: connId,
                        sessionId: sessionId
                    )
                }
                if let cursorId {
                    _ = await BridgeManager.shared.pgCloseQuery(
                        connectionId: connId,
                        sessionId: sessionId,
                        cursorId: cursorId
                    )
                }
                _ = await BridgeManager.shared.pgReleaseSession(
                    connectionId: connId,
                    sessionId: sessionId
                )
            }
        }
        queryStore.closeTab(id: tab.id)
    }

    var body: some View {
        queryArea
            .frame(minWidth: 360)
            .frame(minWidth: 700, minHeight: 480)
            .sheet(isPresented: $isPresentingWizard) {
                PostgresObjectWizardView(
                    connectionId: connectionId,
                    defaultSchema: wizardDefaultSchema,
                    onCompleted: {
                        isPresentingWizard = false
                    }
                )
                .frame(minWidth: 750, minHeight: 550)
            }
            .sheet(isPresented: $isPresentingBackupRestore) {
                PostgresBackupRestoreView(profile: profile)
                    .frame(minWidth: 600, minHeight: 500)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openPostgresObjectTab)) { notification in
                handleOpenTabNotification(notification)
            }
    }

    private func handleOpenTabNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let profileId = userInfo["profileId"] as? String,
              profileId == profile.id else { return }

        guard let kind = userInfo["kind"] as? String else { return }

        switch kind {
        case "relation":
            if let schema = userInfo["schema"] as? String,
               let name = userInfo["name"] as? String {
                // FK navigation passes a pre-built filter; plain
                // browses leave it absent.
                let whereClause = userInfo["whereClause"] as? String
                queryStore.openRelationTab(schema: schema, name: name, whereClause: whereClause)
            }
        case "routine":
            if let schema = userInfo["schema"] as? String,
               let name = userInfo["name"] as? String,
               let signature = userInfo["signature"] as? String {
                queryStore.openRoutineTab(schema: schema, name: name, signature: signature)
            }
        case "sequence":
            if let schema = userInfo["schema"] as? String,
               let name = userInfo["name"] as? String {
                queryStore.openSequenceTab(schema: schema, name: name)
            }
        case "objectType":
            if let schema = userInfo["schema"] as? String,
               let name = userInfo["name"] as? String,
               let typeKind = userInfo["typeKind"] as? String {
                queryStore.openObjectTypeTab(schema: schema, name: name, typeKind: typeKind)
            }
        case "properties":
            if let node = userInfo["node"] as? PgSchemaNode {
                queryStore.openPropertyTab(node: node)
            }
        case "sql":
            // Context-menu generated SQL (DROP / TRUNCATE / VACUUM …)
            // arrives here as a pre-filled tab; the user reviews and
            // runs it explicitly.
            if let title = userInfo["title"] as? String,
               let sql = userInfo["sql"] as? String {
                queryStore.openSqlTab(title: title, sql: sql)
            }
        case "wizard":
            wizardDefaultSchema = (userInfo["schema"] as? String) ?? "public"
            isPresentingWizard = true
        case "backupRestore":
            isPresentingBackupRestore = true
        default:
            break
        }
    }

    @ViewBuilder
    private var queryArea: some View {
        VStack(spacing: 0) {
            queryTabBar
            Divider()
            if let activeId = queryStore.activeTabId {
                PostgresQueryTabView(
                    store: queryStore,
                    tabId: activeId,
                    profileId: profile.id,
                    connectionId: connectionId
                )
            } else {
                emptyQueryArea
            }
        }
    }

    // MARK: - Tab bar

    @ViewBuilder
    private var queryTabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(queryStore.tabs) { tab in
                        tabChip(tab)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }
            Spacer(minLength: 0)
            
            Button {
                queryStore.openActivityTab()
            } label: {
                Image(systemName: "pulse.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Postgres Activity Monitor")
            .padding(.trailing, 4)

            Button {
                wizardDefaultSchema = "public"
                isPresentingWizard = true
            } label: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("DDL & Schema Creation Wizard")
            .disabled(connectionId == nil)
            .padding(.trailing, 4)

            Button {
                isPresentingBackupRestore = true
            } label: {
                Image(systemName: "arrow.up.doc.fill.and.arrow.down.doc.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Database Backup & Restore")
            .disabled(connectionId == nil)
            .padding(.trailing, 4)
            
            Button {
                queryStore.openBlankTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New query tab (⌘T)")
            .keyboardShortcut("t", modifiers: .command)
            .padding(.trailing, 6)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private func tabChip(_ tab: PostgresQueryTab) -> some View {
        let isActive = tab.id == queryStore.activeTabId
        HStack(spacing: 6) {
            Image(systemName: tabIcon(tab))
                .font(.system(size: 10))
                .foregroundStyle(tabIconColor(tab))
            Text(tab.title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
            Button {
                closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive
                      ? Color.accentColor.opacity(0.18)
                      : Color(NSColor.controlBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isActive ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { queryStore.setActive(tab.id) }
    }

    private func tabIcon(_ tab: PostgresQueryTab) -> String {
        switch tab.kind {
        case .routine:
            return "f.sign"
        case .sequence:
            return "number"
        case .objectType:
            return "cube"
        case .activity:
            return "pulse.circle.fill"
        case .properties:
            return "info.circle"
        case .query:
            switch tab.execState {
            case .running:    return "circle.dotted"
            case .completed:  return "checkmark.circle.fill"
            case .failed:     return "exclamationmark.triangle.fill"
            case .cancelled:  return "stop.circle"
            case .idle:       return "doc.text"
            }
        }
    }

    private func tabIconColor(_ tab: PostgresQueryTab) -> Color {
        switch tab.kind {
        case .routine:
            return .purple
        case .sequence:
            return .orange
        case .objectType:
            return .teal
        case .activity:
            return .pink
        case .properties:
            return .cyan
        case .query:
            switch tab.execState {
            case .running:    return .accentColor
            case .completed:  return .green
            case .failed:     return .red
            case .cancelled:  return .orange
            case .idle:       return .secondary
            }
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyQueryArea: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("No query open")
                .font(.headline)
            Text("Double-click a table on the left, or press ⌘T to start a new query.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                queryStore.openBlankTab()
            } label: {
                Label("New Query", systemImage: "plus")
            }
            .keyboardShortcut("t", modifiers: .command)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
