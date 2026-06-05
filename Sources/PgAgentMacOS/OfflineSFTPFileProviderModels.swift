import Foundation

public enum OfflineSFTPFileProviderIdentifier: Hashable, Sendable {
    private static let rootPrefix = "offline-root:"
    private static let itemPrefix = "offline-item:"

    case root
    case offlineRoot(folderId: String)
    case item(folderId: String, remotePath: String)

    public init?(rawValue: String) {
        if rawValue == "root" {
            self = .root
            return
        }
        if rawValue.hasPrefix(Self.rootPrefix) {
            let folderId = String(rawValue.dropFirst(Self.rootPrefix.count))
            guard !folderId.isEmpty else { return nil }
            self = .offlineRoot(folderId: folderId)
            return
        }
        if rawValue.hasPrefix(Self.itemPrefix) {
            let payload = String(rawValue.dropFirst(Self.itemPrefix.count))
            let parts = payload.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let remotePath = Self.decode(parts[1]) else { return nil }
            self = .item(folderId: parts[0], remotePath: remotePath)
            return
        }
        return nil
    }

    public var rawValue: String {
        switch self {
        case .root:
            return "root"
        case .offlineRoot(let folderId):
            return Self.rootPrefix + folderId
        case .item(let folderId, let remotePath):
            return Self.itemPrefix + folderId + ":" + Self.encode(remotePath)
        }
    }

    private static func encode(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ value: String) -> String? {
        var padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public struct OfflineSFTPCacheItemRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String { itemIdentifier }
    public var folderId: String
    public var remotePath: String
    public var parentRemotePath: String
    public var name: String
    public var fileType: FileType
    public var size: UInt64
    public var modifiedAt: Date?
    public var localCachePath: String?
    public var contentVersion: String
    public var metadataVersion: String
    public var lastSyncedAt: Date?

    public init(
        folderId: String,
        remotePath: String,
        parentRemotePath: String? = nil,
        name: String? = nil,
        fileType: FileType,
        size: UInt64 = 0,
        modifiedAt: Date? = nil,
        localCachePath: String? = nil,
        contentVersion: String? = nil,
        metadataVersion: String? = nil,
        lastSyncedAt: Date? = nil
    ) {
        let normalized = Self.normalizedRemotePath(remotePath)
        self.folderId = folderId
        self.remotePath = normalized
        self.parentRemotePath = parentRemotePath.map(Self.normalizedRemotePath)
            ?? Self.parentPath(for: normalized)
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : Self.defaultName(for: normalized)
        self.fileType = fileType
        self.size = size
        self.modifiedAt = modifiedAt
        self.localCachePath = localCachePath
        let versionSeed = "\(normalized):\(size):\(modifiedAt?.timeIntervalSince1970 ?? 0)"
        self.contentVersion = contentVersion ?? Self.versionComponent(for: versionSeed)
        self.metadataVersion = metadataVersion ?? Self.versionComponent(for: "\(normalized):\(self.name):\(fileType.rawValue)")
        self.lastSyncedAt = lastSyncedAt
    }

    public var itemIdentifier: String {
        OfflineSFTPFileProviderIdentifier.item(folderId: folderId, remotePath: remotePath).rawValue
    }

    public var parentIdentifier: String {
        if parentRemotePath == remotePath || parentRemotePath == "/" {
            return OfflineSFTPFileProviderIdentifier.offlineRoot(folderId: folderId).rawValue
        }
        return OfflineSFTPFileProviderIdentifier.item(folderId: folderId, remotePath: parentRemotePath).rawValue
    }

    public static func normalizedRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        let collapsed = trimmed.replacingOccurrences(of: "//+", with: "/", options: .regularExpression)
        return collapsed.hasPrefix("/") ? collapsed : "/\(collapsed)"
    }

    public static func parentPath(for path: String) -> String {
        let normalized = normalizedRemotePath(path)
        guard normalized != "/" else { return "/" }
        let parent = URL(fileURLWithPath: normalized).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private static func defaultName(for path: String) -> String {
        let normalized = normalizedRemotePath(path)
        return normalized == "/" ? "/" : URL(fileURLWithPath: normalized).lastPathComponent
    }

    private static func versionComponent(for value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct OfflineSFTPCacheManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var items: [OfflineSFTPCacheItemRecord]

    public static let empty = OfflineSFTPCacheManifest()

    public init(
        schemaVersion: Int = PlatformIntegrationSchema.currentVersion,
        generatedAt: Date = Date(),
        items: [OfflineSFTPCacheItemRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.items = items
    }

    public func item(folderId: String, remotePath: String) -> OfflineSFTPCacheItemRecord? {
        let normalized = OfflineSFTPCacheItemRecord.normalizedRemotePath(remotePath)
        return items.first { $0.folderId == folderId && $0.remotePath == normalized }
    }

    public func children(folderId: String, parentRemotePath: String) -> [OfflineSFTPCacheItemRecord] {
        let normalized = OfflineSFTPCacheItemRecord.normalizedRemotePath(parentRemotePath)
        return items
            .filter { $0.folderId == folderId && $0.parentRemotePath == normalized && $0.remotePath != normalized }
            .sorted { lhs, rhs in
                if lhs.fileType == .directory, rhs.fileType != .directory { return true }
                if lhs.fileType != .directory, rhs.fileType == .directory { return false }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}

public struct FileProviderCatalogItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var parentId: String
    public var folderId: String?
    public var remotePath: String?
    public var filename: String
    public var fileType: FileType
    public var size: UInt64
    public var modifiedAt: Date?
    public var localCachePath: String?
    public var contentVersion: String
    public var metadataVersion: String

    public var isDirectory: Bool { fileType == .directory }
}

public struct FileProviderCatalog: Sendable {
    public var integrations: PlatformIntegrationStoreData
    public var manifest: OfflineSFTPCacheManifest

    public init(
        integrations: PlatformIntegrationStoreData,
        manifest: OfflineSFTPCacheManifest
    ) {
        self.integrations = integrations
        self.manifest = manifest
    }

    public func item(rawIdentifier: String) -> FileProviderCatalogItem? {
        guard let identifier = OfflineSFTPFileProviderIdentifier(rawValue: rawIdentifier) else { return nil }
        switch identifier {
        case .root:
            return rootItem
        case .offlineRoot(let folderId):
            guard let folder = integrations.offlineFolders.first(where: { $0.id == folderId }) else { return nil }
            return item(for: folder)
        case .item(let folderId, let remotePath):
            guard let record = manifest.item(folderId: folderId, remotePath: remotePath) else { return nil }
            return item(for: record)
        }
    }

    public func children(rawIdentifier: String) -> [FileProviderCatalogItem] {
        guard let identifier = OfflineSFTPFileProviderIdentifier(rawValue: rawIdentifier) else { return [] }
        switch identifier {
        case .root:
            return integrations.offlineFolders.map(item(for:)).sorted {
                $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
        case .offlineRoot(let folderId):
            guard let folder = integrations.offlineFolders.first(where: { $0.id == folderId }) else { return [] }
            return manifest.children(folderId: folderId, parentRemotePath: folder.remotePath).map(item(for:))
        case .item(let folderId, let remotePath):
            return manifest.children(folderId: folderId, parentRemotePath: remotePath).map(item(for:))
        }
    }

    public func remotePath(forParent rawParentIdentifier: String, filename: String) -> (folderId: String, remotePath: String)? {
        guard let parent = item(rawIdentifier: rawParentIdentifier), let folderId = parent.folderId else { return nil }
        let base = parent.remotePath ?? "/"
        let normalizedBase = OfflineSFTPCacheItemRecord.normalizedRemotePath(base)
        let cleanName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        let remotePath = normalizedBase == "/" ? "/\(cleanName)" : "\(normalizedBase)/\(cleanName)"
        return (folderId, remotePath)
    }

    private var rootItem: FileProviderCatalogItem {
        return FileProviderCatalogItem(
            id: OfflineSFTPFileProviderIdentifier.root.rawValue,
            parentId: OfflineSFTPFileProviderIdentifier.root.rawValue,
            folderId: nil,
            remotePath: nil,
            filename: "Midnight SSH",
            fileType: .directory,
            size: 0,
            modifiedAt: nil,
            localCachePath: nil,
            contentVersion: "root",
            metadataVersion: "root"
        )
    }

    private func item(for folder: OfflineSFTPFolderRecord) -> FileProviderCatalogItem {
        return FileProviderCatalogItem(
            id: OfflineSFTPFileProviderIdentifier.offlineRoot(folderId: folder.id).rawValue,
            parentId: OfflineSFTPFileProviderIdentifier.root.rawValue,
            folderId: folder.id,
            remotePath: folder.remotePath,
            filename: folder.displayName,
            fileType: .directory,
            size: 0,
            modifiedAt: folder.lastSyncedAt,
            localCachePath: folder.localCachePath,
            contentVersion: folder.syncState.rawValue,
            metadataVersion: "\(folder.displayName):\(folder.remotePath):\(folder.syncState.rawValue)"
        )
    }

    private func item(for record: OfflineSFTPCacheItemRecord) -> FileProviderCatalogItem {
        let rootRemotePath = integrations.offlineFolders.first(where: { $0.id == record.folderId })?.remotePath
        let parentId = rootRemotePath == record.parentRemotePath
            ? OfflineSFTPFileProviderIdentifier.offlineRoot(folderId: record.folderId).rawValue
            : record.parentIdentifier
        return FileProviderCatalogItem(
            id: record.itemIdentifier,
            parentId: parentId,
            folderId: record.folderId,
            remotePath: record.remotePath,
            filename: record.name,
            fileType: record.fileType,
            size: record.size,
            modifiedAt: record.modifiedAt,
            localCachePath: record.localCachePath,
            contentVersion: record.contentVersion,
            metadataVersion: record.metadataVersion
        )
    }
}

public final class OfflineSFTPCacheManifestStore: @unchecked Sendable {
    private let store: SharedJSONFileStore<OfflineSFTPCacheManifest>

    public init(
        fileName: String = SharedAppStorageConfiguration.offlineCacheManifestFileName,
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.store = SharedJSONFileStore(
            fileName: fileName,
            fileManager: fileManager,
            directoryURL: directoryURL
        )
    }

    public func load() throws -> OfflineSFTPCacheManifest {
        try store.load(default: .empty)
    }

    public func save(_ manifest: OfflineSFTPCacheManifest) throws {
        try store.save(manifest)
    }
}
