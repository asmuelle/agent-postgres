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

    /// Recover a constraint/key's bare name from its node id —
    /// `loadMeta` bakes the human-readable definition into
    /// `node.name` ("pk_users (PRIMARY KEY (id))"), which is wrong
    /// for generated DDL.
    func bareMetaName(id: String, prefix: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
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

    func parseRelationId(_ id: String) -> (database: String, schema: String, name: String)? {
        let prefix = "rel:"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        guard let firstDot = rest.firstIndex(of: ".") else { return nil }
        let database = String(rest[rest.startIndex..<firstDot])
        let afterDb = String(rest[rest.index(after: firstDot)...])
        guard let lastDot = afterDb.lastIndex(of: ".") else { return nil }
        let schema = String(afterDb[afterDb.startIndex..<lastDot])
        let name = String(afterDb[afterDb.index(after: lastDot)...])
        return (database, schema, name)
    }

    func parseSequenceId(_ id: String) -> (database: String, schema: String, name: String)? {
        let prefix = "seq:"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        guard let firstDot = rest.firstIndex(of: ".") else { return nil }
        let database = String(rest[rest.startIndex..<firstDot])
        let afterDb = String(rest[rest.index(after: firstDot)...])
        guard let lastDot = afterDb.lastIndex(of: ".") else { return nil }
        let schema = String(afterDb[afterDb.startIndex..<lastDot])
        let name = String(afterDb[afterDb.index(after: lastDot)...])
        return (database, schema, name)
    }

    func parseRoutineId(_ id: String) -> (database: String, schema: String, name: String)? {
        let prefix = "fn:"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        guard let firstDot = rest.firstIndex(of: ".") else { return nil }
        let database = String(rest[rest.startIndex..<firstDot])
        let afterDb = String(rest[rest.index(after: firstDot)...])
        guard let parenStart = afterDb.firstIndex(of: "(") else { return nil }
        let nameAndSchema = String(afterDb[afterDb.startIndex..<parenStart])
        guard let lastDot = nameAndSchema.lastIndex(of: ".") else { return nil }
        let schema = String(nameAndSchema[nameAndSchema.startIndex..<lastDot])
        let name = String(nameAndSchema[nameAndSchema.index(after: lastDot)...])
        return (database, schema, name)
    }

    func parseObjectTypeId(_ id: String) -> (database: String, schema: String, name: String)? {
        let prefix = "type:"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        guard let firstDot = rest.firstIndex(of: ".") else { return nil }
        let database = String(rest[rest.startIndex..<firstDot])
        let afterDb = String(rest[rest.index(after: firstDot)...])
        guard let lastDot = afterDb.lastIndex(of: ".") else { return nil }
        let schema = String(afterDb[afterDb.startIndex..<lastDot])
        let name = String(afterDb[afterDb.index(after: lastDot)...])
        return (database, schema, name)
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
