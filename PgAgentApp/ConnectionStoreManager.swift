import Foundation
import OSLog
import PgAgentMacOS

/// Observable object that owns the connection database, persists it to
/// `Application Support/com.mc-ssh/connections.json`, and provides CRUD.
@MainActor
class ConnectionStoreManager: ObservableObject {
    static let shared = ConnectionStoreManager()
    private let logger = Logger(subsystem: "com.mc-ssh", category: "connection-store")

    @Published var connections: [ConnectionProfile] = []
    @Published var folders: [ConnectionFolder] = []

    enum SyncError: LocalizedError {
        case noSnapshot

        var errorDescription: String? {
            switch self {
            case .noSnapshot:
                return "No iCloud sync snapshot is available yet."
            }
        }
    }

    private static var storeFileURL: URL {
        // Application Support always resolves in practice; fall back to the
        // temp directory (same idiom as SSHKeyVault) rather than crashing
        // connection persistence on an exotic sandbox state.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("com.mc-ssh")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json")
    }

    private init() {
        load()
    }

    // MARK: - CRUD

    func saveOrUpdate(_ profile: ConnectionProfile) {
        if let idx = connections.firstIndex(where: { $0.id == profile.id }) {
            let previous = connections[idx]
            deleteStaleCredentials(previous: previous, updated: profile)
            connections[idx] = profile
        } else {
            connections.append(profile)
        }
        save()
    }

    func delete(_ profile: ConnectionProfile) {
        connections.removeAll { $0.id == profile.id }
        deleteCredentials(for: profile)
        save()
    }

    func connection(withId id: String) -> ConnectionProfile? {
        connections.first { $0.id == id }
    }

    func connections(inFolder path: String?) -> [ConnectionProfile] {
        connections.filter { $0.folderPath == path }
    }

    func markConnected(_ profile: ConnectionProfile) {
        var updated = profile
        updated.lastConnected = Date()
        saveOrUpdate(updated)
    }

    /// Update the saved kind for a profile in place. Used by the
    /// SSH→SFTP fallback alert when the user opts to make the
    /// demotion permanent. Other fields stay untouched so this
    /// can't accidentally overwrite an in-flight edit.
    func setKind(profileId: String, kind: ConnectionKind) {
        guard let idx = connections.firstIndex(where: { $0.id == profileId }) else { return }
        if connections[idx].kind == kind { return }
        connections[idx].kind = kind
        save()
        logger.info("Profile \(profileId, privacy: .public) kind → \(kind.rawValue, privacy: .public)")
    }

    func monitoredSystemdServices(profileId: String?) -> [String] {
        guard let profileId,
              let profile = connections.first(where: { $0.id == profileId })
        else { return [] }
        return profile.monitoredSystemdServices
    }

    func isMonitoringSystemdService(_ serviceName: String, profileId: String?) -> Bool {
        monitoredSystemdServices(profileId: profileId).contains(serviceName)
    }

    func setMonitoringSystemdService(_ enabled: Bool, serviceName: String, profileId: String?) {
        guard let profileId,
              let idx = connections.firstIndex(where: { $0.id == profileId })
        else { return }

        var services = Set(connections[idx].monitoredSystemdServices)
        if enabled {
            services.insert(serviceName)
        } else {
            services.remove(serviceName)
        }

        var updated = connections
        updated[idx].monitoredSystemdServices = sortedServiceNames(Array(services))
        connections = updated
        save()
    }

    func setMonitoredSystemdServices(_ services: [String], profileId: String) {
        guard let idx = connections.firstIndex(where: { $0.id == profileId }) else { return }
        var updated = connections
        updated[idx].monitoredSystemdServices = sortedServiceNames(services)
        connections = updated
        save()
    }

    private func deleteStaleCredentials(previous: ConnectionProfile, updated: ConnectionProfile) {
        if previous.keychainAccount != updated.keychainAccount {
            deleteCredentials(for: previous)
            return
        }

        switch updated.authMethod {
        case .password:
            KeychainManager.shared.deletePassword(kind: .sshKeyPassphrase, account: updated.keychainAccount)
        case .publicKey:
            KeychainManager.shared.deletePassword(kind: .sshPassword, account: updated.keychainAccount)
            if previous.sshKeyReference != updated.sshKeyReference || updated.sshKeyReference?.needsStoredPassphrase == false {
                KeychainManager.shared.deletePassword(kind: .sshKeyPassphrase, account: updated.keychainAccount)
            }
        }
    }

    private func deleteCredentials(for profile: ConnectionProfile) {
        KeychainManager.shared.deletePassword(kind: .sshPassword, account: profile.keychainAccount)
        KeychainManager.shared.deletePassword(kind: .sshKeyPassphrase, account: profile.keychainAccount)
    }

    // MARK: - Folder CRUD

    /// Outcome of a folder mutation. The sidebar surfaces failures via
    /// an alert — name collisions are the common one (two siblings
    /// can't share a path) so the user gets an actionable message.
    enum FolderError: LocalizedError {
        case emptyName
        case duplicate(String)
        case notFound

        var errorDescription: String? {
            switch self {
            case .emptyName: return "Folder name can't be empty."
            case .duplicate(let path): return "A folder named \"\(path)\" already exists at this level."
            case .notFound: return "Folder not found."
            }
        }
    }

    /// Immediate children of a folder. `parent == nil` returns
    /// top-level folders. Used by the sidebar's recursive render so
    /// each level only sees its own slice.
    func childFolders(of parent: String?) -> [ConnectionFolder] {
        folders
            .filter { $0.parentPath == parent }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// All distinct folder paths in dotted-list form. Used by the
    /// connection editor's folder picker. `nil` represents root.
    func allFolderPaths() -> [String] {
        folders
            .map(\.path)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Create a new folder. `parent == nil` makes a top-level folder.
    /// Path is computed as `parent/name` (or just `name` at root) and
    /// must not collide with an existing folder at the same level.
    @discardableResult
    func createFolder(
        name: String,
        in parent: String? = nil
    ) throws -> ConnectionFolder {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw FolderError.emptyName }

        let path = composedPath(name: trimmed, parent: parent)
        if folders.contains(where: { $0.path == path }) {
            throw FolderError.duplicate(path)
        }

        let folder = ConnectionFolder(
            name: trimmed,
            path: path,
            parentPath: parent,
            createdAt: Date()
        )
        folders.append(folder)
        save()
        logger.info("Created folder \(path, privacy: .public)")
        return folder
    }

    /// Rename a folder. Rewrites `path` on the folder itself plus
    /// every descendant folder's `path` / `parentPath` and every
    /// profile's `folderPath` so the hierarchy stays internally
    /// consistent. No-ops if the new name matches the current one.
    func renameFolder(id: String, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw FolderError.emptyName }

        guard let idx = folders.firstIndex(where: { $0.id == id }) else {
            throw FolderError.notFound
        }
        let folder = folders[idx]
        if folder.name == trimmed { return }

        let newPath = composedPath(name: trimmed, parent: folder.parentPath)
        if folders.contains(where: { $0.path == newPath && $0.id != id }) {
            throw FolderError.duplicate(newPath)
        }

        // Rewrite children before mutating the folder itself so
        // `oldPrefix` matches the descendants' current paths.
        rewritePathPrefix(from: folder.path, to: newPath)
        folders[idx].name = trimmed
        folders[idx].path = newPath
        save()
        logger.info("Renamed folder \(folder.path, privacy: .public) → \(newPath, privacy: .public)")
    }

    /// Move a folder to a new parent (or to root with `nil`). Refuses
    /// to move a folder into its own descendant — that would create a
    /// cycle and make the recursive renderer loop forever. Path is
    /// recomputed and all descendants are rewritten in lock-step.
    func moveFolder(id: String, to newParent: String?) throws {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else {
            throw FolderError.notFound
        }
        let folder = folders[idx]
        if folder.parentPath == newParent { return }

        // Cycle guard: refuse if `newParent` is the folder itself or
        // any path nested beneath it. Without this, dragging "Work"
        // into "Work/Production" would corrupt the parent chain.
        if let target = newParent {
            if target == folder.path || target.hasPrefix(folder.path + "/") {
                throw FolderError.duplicate(target)  // reuse the alert path
            }
        }

        let newPath = composedPath(name: folder.name, parent: newParent)
        if folders.contains(where: { $0.path == newPath && $0.id != id }) {
            throw FolderError.duplicate(newPath)
        }

        rewritePathPrefix(from: folder.path, to: newPath)
        folders[idx].parentPath = newParent
        folders[idx].path = newPath
        save()
        logger.info("Moved folder \(folder.path, privacy: .public) → \(newPath, privacy: .public)")
    }

    /// Delete a folder. Children (sub-folders and profiles) move up
    /// to the deleted folder's parent, never to root unless that's
    /// where the deleted folder lived. Picks the gentle option —
    /// users can always re-organise after, but losing connections
    /// on an accidental delete is irreversible.
    func deleteFolder(id: String) throws {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else {
            throw FolderError.notFound
        }
        let folder = folders[idx]

        // Re-parent direct child folders.
        for child in folders where child.parentPath == folder.path {
            try? moveFolder(id: child.id, to: folder.parentPath)
        }
        // Move profiles up.
        for i in connections.indices where connections[i].folderPath == folder.path {
            connections[i].folderPath = folder.parentPath
        }
        folders.removeAll { $0.id == id }
        save()
        logger.info("Deleted folder \(folder.path, privacy: .public); children re-parented")
    }

    /// Move a profile into a folder by path (`nil` = root). The folder
    /// must already exist; create it first via `createFolder` if not.
    func moveProfile(id: String, to folderPath: String?) {
        guard let idx = connections.firstIndex(where: { $0.id == id }) else { return }
        if connections[idx].folderPath == folderPath { return }
        connections[idx].folderPath = folderPath
        save()
    }

    // MARK: - Path helpers

    private func composedPath(name: String, parent: String?) -> String {
        if let parent, !parent.isEmpty {
            return "\(parent)/\(name)"
        }
        return name
    }

    private func sortedServiceNames(_ services: [String]) -> [String] {
        Array(Set(services.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }))
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Rewrite `path` / `parentPath` on every folder and `folderPath`
    /// on every profile that sits at or below `oldPrefix`. Called from
    /// rename / move so descendants follow the parent atomically.
    private func rewritePathPrefix(from oldPrefix: String, to newPrefix: String) {
        for i in folders.indices {
            let p = folders[i].path
            if p == oldPrefix {
                // The folder itself — caller updates this, skip here.
                continue
            }
            if p.hasPrefix(oldPrefix + "/") {
                let suffix = String(p.dropFirst(oldPrefix.count))
                folders[i].path = newPrefix + suffix
                // parentPath is the path minus the last segment.
                folders[i].parentPath = parentOf(folders[i].path)
            }
        }
        for i in connections.indices {
            guard let fp = connections[i].folderPath else { continue }
            if fp == oldPrefix {
                connections[i].folderPath = newPrefix
            } else if fp.hasPrefix(oldPrefix + "/") {
                let suffix = String(fp.dropFirst(oldPrefix.count))
                connections[i].folderPath = newPrefix + suffix
            }
        }
    }

    private func parentOf(_ path: String) -> String? {
        guard let lastSlash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<lastSlash])
    }

    // MARK: - Import

    func importFromTauriJSON(url: URL) -> Int {
        do {
            let data = try ImportManager.shared.importFromJSON(url: url)
            var count = 0
            for profile in data.connections where !connections.contains(where: { $0.id == profile.id }) {
                connections.append(profile)
                count += 1
            }
            for folder in data.folders where !folders.contains(where: { $0.id == folder.id }) {
                folders.append(folder)
            }
            save()
            logger.info("Imported \(count) connections from Tauri export")
            return count
        } catch {
            logger.error("Import failed: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - CSV import/export

    func exportConnectionsCSV() -> String {
        ConnectionCSVCodec.encode(profiles: connections)
    }

    func previewCSVImport(url: URL) throws -> ConnectionCSVImportPlan {
        let csv = try String(contentsOf: url, encoding: .utf8)
        return try ConnectionCSVImportPlanner.plan(existing: connections, csv: csv)
    }

    @discardableResult
    func applyCSVImport(_ plan: ConnectionCSVImportPlan) -> ConnectionCSVImportPlan {
        connections = ConnectionCSVImportPlanner.apply(plan, to: connections)
        ensureFolders(for: connections)
        save()
        return plan
    }

    // MARK: - Cloud provider import

    @discardableResult
    func importCloudServerProfiles(
        _ servers: [CloudServerRecord],
        account: CloudServerAccountRecord,
        options: CloudServerProfileGenerationOptions = CloudServerProfileGenerationOptions()
    ) -> CloudServerProfileImportReport {
        var report = CloudServerProfileImportReport()
        var byId = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })

        for server in servers {
            let generatedId = "cloud-\(server.provider.rawValue)-\(server.accountId)-\(server.providerServerId)"
            let existing = byId[generatedId]
            guard let profile = CloudServerProfileGenerator.profile(
                from: server,
                account: account,
                options: options,
                preserving: existing
            ) else {
                report.skippedServers += 1
                continue
            }

            if existing == nil {
                report.insertedProfiles += 1
            } else if profile != existing {
                report.updatedProfiles += 1
            }
            byId[profile.id] = profile
        }

        connections = byId.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        ensureFolders(for: connections)
        save()
        return report
    }

    // MARK: - Cloud sync

    func makeCloudSyncSnapshot(
        terminalSettings: SyncedTerminalSettingsRecord? = nil,
        generatedAt: Date = Date()
    ) throws -> CloudSyncSnapshot {
        let integrations = try PlatformIntegrationStore().load()
        return CloudSyncSnapshot(
            generatedAt: generatedAt,
            profiles: connections.map { SyncedConnectionProfileRecord(profile: $0, updatedAt: generatedAt) },
            snippets: integrations.snippets.filter(\.syncEnabled),
            terminalSettings: terminalSettings
        )
    }

    @discardableResult
    func publishCloudSync(
        terminalSettings: SyncedTerminalSettingsRecord? = nil,
        store: CloudSyncStore = CloudSyncStore()
    ) throws -> CloudSyncMergeReport {
        let local = try makeCloudSyncSnapshot(terminalSettings: terminalSettings)
        let existing = try store.loadLatest() ?? .empty
        let (merged, report) = CloudSyncMergeEngine.merge(local: existing, incoming: local)
        try store.save(merged)
        return report
    }

    @discardableResult
    func applyLatestCloudSync(
        store: CloudSyncStore = CloudSyncStore()
    ) throws -> (report: CloudSyncMergeReport, terminalSettings: SyncedTerminalSettingsRecord?) {
        guard let snapshot = try store.loadLatest() else {
            throw SyncError.noSnapshot
        }
        return try applyCloudSyncSnapshot(snapshot)
    }

    @discardableResult
    func applyCloudSyncSnapshot(
        _ snapshot: CloudSyncSnapshot
    ) throws -> (report: CloudSyncMergeReport, terminalSettings: SyncedTerminalSettingsRecord?) {
        var report = CloudSyncMergeReport()
        var byId = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })

        for record in snapshot.profiles {
            if let existing = byId[record.id] {
                let updated = record.connectionProfile(preserving: existing)
                if updated == existing {
                    report.skippedProfiles += 1
                } else {
                    byId[record.id] = updated
                    report.updatedProfiles += 1
                }
            } else {
                byId[record.id] = record.connectionProfile()
                report.insertedProfiles += 1
            }
        }

        for tombstone in snapshot.tombstones where tombstone.collection == .profile {
            if byId.removeValue(forKey: tombstone.recordId) != nil {
                report.deletedRecords += 1
            }
        }

        connections = byId.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        ensureFolders(for: connections)
        try mergeSyncedSnippets(snapshot.snippets, tombstones: snapshot.tombstones, report: &report)
        save()
        return (report, snapshot.terminalSettings)
    }

    // MARK: - Persistence

    /// Atomically replace the on-disk store so a crash mid-write never
    /// leaves a zero-length or truncated file. Write to a temp file
    /// first, then use `replaceItemAt` (Atomic rename on APFS/HFS+).
    private func save() {
        do {
            let data = try JSONEncoder().encode(ConnectionStoreData(connections: connections, folders: folders))
            let target = Self.storeFileURL
            let tmp = target.appendingPathExtension("tmp")
            try data.write(to: tmp, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp, backupItemName: nil, options: [])
        } catch {
            logger.error("Failed to save connections: \(error.localizedDescription)")
        }
    }

    private func mergeSyncedSnippets(
        _ incoming: [SharedSnippetRecord],
        tombstones: [CloudSyncTombstoneRecord],
        report: inout CloudSyncMergeReport
    ) throws {
        let store = PlatformIntegrationStore()
        var data = try store.load()
        var byId = Dictionary(uniqueKeysWithValues: data.snippets.map { ($0.id, $0) })

        for snippet in incoming {
            if tombstones.contains(where: {
                $0.collection == .snippet && $0.recordId == snippet.id && $0.deletedAt >= snippet.updatedAt
            }) {
                report.skippedSnippets += 1
                continue
            }
            if let existing = byId[snippet.id] {
                if snippet.updatedAt > existing.updatedAt {
                    byId[snippet.id] = snippet
                    report.updatedSnippets += 1
                } else {
                    report.skippedSnippets += 1
                }
            } else {
                byId[snippet.id] = snippet
                report.insertedSnippets += 1
            }
        }

        for tombstone in tombstones where tombstone.collection == .snippet {
            if byId.removeValue(forKey: tombstone.recordId) != nil {
                report.deletedRecords += 1
            }
        }

        data.snippets = byId.values.sorted { $0.updatedAt > $1.updatedAt }
        try store.save(data)
    }

    private func ensureFolders(for profiles: [ConnectionProfile]) {
        let paths = Set(profiles.compactMap(\.folderPath))
        for path in paths.sorted() {
            ensureFolderPath(path)
        }
    }

    private func ensureFolderPath(_ path: String) {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let parts = path.split(separator: "/").map(String.init)
        var parent: String?
        var current = ""
        for part in parts {
            current = current.isEmpty ? part : "\(current)/\(part)"
            if !folders.contains(where: { $0.path == current }) {
                folders.append(
                    ConnectionFolder(
                        name: part,
                        path: current,
                        parentPath: parent
                    )
                )
            }
            parent = current
        }
    }

    private func load() {
        do {
            let data = try Data(contentsOf: Self.storeFileURL)
            let store = try JSONDecoder().decode(ConnectionStoreData.self, from: data)
            connections = store.connections
            folders = store.folders
        } catch {
            connections = []
            folders = []
        }
    }
}
