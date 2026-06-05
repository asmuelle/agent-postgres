import Foundation
import OSLog
import PgAgentMacOS

/// Handles importing connections from the Tauri app's localStorage export.
///
/// The Tauri app stores connections in localStorage under `mc-ssh-connections`.
/// The user can export this via the Tauri app's UI, or we can read the
/// WebView's storage file directly if the Tauri app is still installed.
///
/// Import sources (in priority order):
/// 1. Direct JSON file drag-and-drop or file picker
/// 2. Automatic scan of the Tauri app's Application Support directory
class ImportManager {
    static let shared = ImportManager()
    private let logger = Logger(subsystem: "com.mc-ssh", category: "import")

    private init() {}

    // MARK: - Tauri app storage paths

    /// Possible locations for the Tauri app's localStorage data.
    /// Tauri 2 stores WebView data under `{bundle_identifier}/Default/Local Storage/`.
    private var tauriStorageCandidates: [URL] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let home = FileManager.default.homeDirectoryForCurrentUser

        return [
            // Tauri 2 — bundle identifier from tauri.conf.json
            appSupport.appendingPathComponent("com.aiden.mc-ssh/default/Local Storage/leveldb"),
            // Chromium-based WebView storage
            home.appendingPathComponent("Library/Application Support/com.aiden.mc-ssh/Default/Local Storage/leveldb"),
        ]
    }

    // MARK: - Import from JSON file

    /// Import connections from a Tauri-format JSON file.
    /// Returns the imported profiles.
    func importFromJSON(url: URL) throws -> ConnectionStoreData {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let container = try decoder.decode(TauriImportContainer.self, from: data)
        return convertTauriEntries(container)
    }

    /// Import from raw JSON string (for drag-and-drop or clipboard).
    func importFromJSONString(_ string: String) throws -> ConnectionStoreData {
        guard let data = string.data(using: .utf8) else {
            throw ImportError.invalidEncoding
        }
        let decoder = JSONDecoder()
        let container = try decoder.decode(TauriImportContainer.self, from: data)
        return convertTauriEntries(container)
    }

    // MARK: - Auto-detect Tauri app data

    /// Scan Tauri app storage directories for saved connections.
    /// Returns nil if none found.
    func scanTauriStorage() -> ConnectionStoreData? {
        for candidate in tauriStorageCandidates {
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            logger.info("Found Tauri storage directory: \(candidate.path)")
            // We'd need to parse the leveldb to extract the localStorage values.
            // For now, require explicit export from the Tauri app.
        }
        return nil
    }

    // MARK: - Conversion

    private func convertTauriEntries(_ container: TauriImportContainer) -> ConnectionStoreData {
        var profiles: [ConnectionProfile] = []
        var folders: [ConnectionFolder] = []

        // Convert folders
        if let folderEntries = container.folders {
            for f in folderEntries {
                folders.append(ConnectionFolder(
                    id: f.id ?? UUID().uuidString,
                    name: f.name ?? "Folder",
                    path: f.path ?? f.name ?? "Folder",
                    parentPath: f.parentPath,
                    createdAt: parseDate(f.createdAt) ?? Date()
                ))
            }
        }

        // Convert connections
        for entry in container.connections {
            let auth: AuthMethod
            switch entry.authMethod?.lowercased() {
            case "publickey", "publickey": auth = .publicKey
            default: auth = .password
            }

            // Tauri exports use `protocol: "SSH" | "SFTP" | "FTP" | …`.
            // Map SFTP to `.sftp`; everything else (including unknowns
            // and missing fields) falls through to `.ssh` so the import
            // is non-destructive when the field is absent. FTP is not
            // supported on macOS yet — bring it across as `.sftp` so it
            // at least lands in the file-only path rather than silently
            // becoming a broken terminal target.
            let kind: ConnectionKind
            switch entry.protocol?.lowercased() {
            case "sftp", "ftp": kind = .sftp
            default: kind = .ssh
            }

            let profile = ConnectionProfile(
                id: entry.id ?? UUID().uuidString,
                name: entry.name ?? entry.host ?? "Unknown",
                host: entry.host ?? "localhost",
                port: entry.port ?? 22,
                username: entry.username ?? "root",
                authMethod: auth,
                kind: kind,
                folderPath: entry.folder,
                privateKeyPath: entry.privateKeyPath,
                createdAt: parseDate(entry.createdAt) ?? Date(),
                lastConnected: parseDate(entry.lastConnected),
                favorite: entry.favorite ?? false,
                tags: entry.tags ?? [],
                color: entry.color,
                notes: entry.description
            )
            profiles.append(profile)
        }

        return ConnectionStoreData(connections: profiles, folders: folders)
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let s = string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: s) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: s)
    }
}

// MARK: - Import container (flexible envelope)

struct TauriImportContainer: Codable {
    var connections: [TauriConnectionEntry]
    var folders: [TauriFolderEntry]?

    // Also accept direct array
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let entries = try? container.decode([TauriConnectionEntry].self) {
            self.connections = entries
            self.folders = nil
        } else {
            let obj = try decoder.container(keyedBy: CodingKeys.self)
            self.connections = try obj.decode([TauriConnectionEntry].self, forKey: .connections)
            self.folders = try obj.decodeIfPresent([TauriFolderEntry].self, forKey: .folders)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case connections, folders
    }
}

enum ImportError: LocalizedError {
    case invalidEncoding
    case noDataFound

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "The imported data is not valid UTF-8 text."
        case .noDataFound: return "No saved connections were found in the Tauri app data."
        }
    }
}
