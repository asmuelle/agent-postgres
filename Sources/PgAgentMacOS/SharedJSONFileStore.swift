import Foundation

public enum SharedAppStorageConfiguration {
    public static let appGroupIdentifier = "group.com.pgagent.pgagent"
    public static let integrationsFileName = "platform-integrations.json"
    public static let backgroundOperationsFileName = "background-ssh-operations.json"
    public static let portForwardRuntimeFileName = "port-forward-runtime.json"
    public static let liveActivitySnapshotsFileName = "live-activity-snapshots.json"
    public static let watchStatusSnapshotFileName = "watch-status-snapshot.json"
    public static let cloudServerInventoryFileName = "cloud-server-inventory.json"
    public static let offlineCacheManifestFileName = "offline-sftp-cache-manifest.json"
    public static let cloudSyncSnapshotFileName = "cloud-sync-snapshot.json"
    public static let offlineCacheDirectoryName = "offline-sftp-cache"
    public static let shortcutDownloadsDirectoryName = "shortcut-downloads"
    public static let stagedUploadsDirectoryName = "staged-uploads"
}

public enum SharedJSONFileStoreError: LocalizedError, Equatable {
    case appGroupContainerUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .appGroupContainerUnavailable(let identifier):
            return "App Group container is unavailable for \(identifier)."
        }
    }
}

public final class SharedJSONFileStore<Value: Codable & Sendable>: @unchecked Sendable {
    private let appGroupIdentifier: String
    private let fileName: String
    private let fileManager: FileManager
    private let directoryOverride: URL?

    public init(
        appGroupIdentifier: String = SharedAppStorageConfiguration.appGroupIdentifier,
        fileName: String,
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.fileName = fileName
        self.fileManager = fileManager
        self.directoryOverride = directoryURL
    }

    public var fileURL: URL {
        get throws {
            try directoryURL().appendingPathComponent(fileName)
        }
    }

    public func load() throws -> Value? {
        let url = try fileURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(Value.self, from: data)
    }

    public func load(default defaultValue: @autoclosure () -> Value) throws -> Value {
        try load() ?? defaultValue()
    }

    public func save(_ value: Value) throws {
        let target = try fileURL
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try Self.encoder.encode(value)
        let temporaryURL = target
            .deletingLastPathComponent()
            .appendingPathComponent("\(target.lastPathComponent).\(UUID().uuidString).tmp")

        try data.write(to: temporaryURL, options: [.atomic])
        do {
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(
                    target,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: target)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func directoryURL() throws -> URL {
        if let directoryOverride {
            return directoryOverride
        }
        guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw SharedJSONFileStoreError.appGroupContainerUnavailable(appGroupIdentifier)
        }
        return url
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
