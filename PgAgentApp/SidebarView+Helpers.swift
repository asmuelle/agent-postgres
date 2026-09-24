import AppKit
import PgAgentMacOS
import SwiftUI

// =============================================================================
// SidebarView helpers — node-id parsers, the open-tab notification
// bridge, profile filtering, and small formatting utilities.
//
// Extracted from SidebarView.swift; behavior-preserving.
// =============================================================================

extension SidebarView {
    func findNodeAcrossStores(id: String) -> PgSchemaNode? {
        for store in connectionManager.schemaStores.values {
            if let found = store.findNode(byId: id) {
                return found
            }
        }
        return nil
    }

    func postOpenTabNotification(profile: PostgresProfile, node: PgSchemaNode, details: [String: Any]) {
        var info = details
        info["profileId"] = profile.id
        info["node"] = node
        NotificationCenter.default.post(
            name: .openPostgresObjectTab,
            object: nil,
            userInfo: info
        )
    }

    /// (database, schema, bare name) of a schema-content node, via the
    /// shared escape-aware `PgNodeID` parser — the one parser every
    /// platform uses, so names containing dots resolve correctly.
    func parseContentNode(_ node: PgSchemaNode) -> (database: String, schema: String, name: String)? {
        switch node.kind {
        case .relation, .sequence, .routine, .objectType:
            guard let t = PgNodeID.target(for: node) else { return nil }
            return (t.database, t.schema, t.name)
        default:
            return nil
        }
    }

    func presentForeignDatabaseAlert(profile: PostgresProfile, database: String) {
        let alert = NSAlert()
        alert.messageText = "“\(database)” isn't connected"
        alert.informativeText = "This profile is connected to “\(profile.database)”. To open a query tab against “\(database)”, edit the profile (or create a new one) with that database selected."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func formatRowCount(_ rows: Float) -> String {
        let n = Int(rows)
        if n < 1_000 { return "\(n) rows" }
        if n < 1_000_000 { return String(format: "%.1fK rows", rows / 1_000) }
        if n < 1_000_000_000 { return String(format: "%.1fM rows", rows / 1_000_000) }
        return String(format: "%.1fB rows", rows / 1_000_000_000)
    }

    func filteredPostgresProfiles() -> [PostgresProfile] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else {
            return postgresStore.profiles
        }
        let needle = search.lowercased()
        return postgresStore.profiles.filter {
            $0.name.lowercased().contains(needle)
                || $0.host.lowercased().contains(needle)
                || $0.user.lowercased().contains(needle)
                || $0.database.lowercased().contains(needle)
        }
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    static let openPostgresObjectTab = Notification.Name("openPostgresObjectTab")
}
