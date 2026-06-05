import Foundation

public struct WidgetMonitoringPreferences: Codable, Equatable, Sendable {
    public var includedKinds: Set<WidgetMonitorKind>
    public var pinnedSnapshotIds: [String]
    public var showOnlyPinnedWhenConfigured: Bool

    public static let `default` = WidgetMonitoringPreferences()

    public init(
        includedKinds: Set<WidgetMonitorKind> = Set(WidgetMonitorKind.allCases),
        pinnedSnapshotIds: [String] = [],
        showOnlyPinnedWhenConfigured: Bool = false
    ) {
        self.includedKinds = includedKinds
        self.pinnedSnapshotIds = Self.normalizedPinnedIds(pinnedSnapshotIds)
        self.showOnlyPinnedWhenConfigured = showOnlyPinnedWhenConfigured
    }

    public func includes(_ snapshot: WidgetMonitorSnapshot) -> Bool {
        guard includedKinds.contains(snapshot.kind) else { return false }
        guard showOnlyPinnedWhenConfigured, !pinnedSnapshotIds.isEmpty else { return true }
        return pinnedSnapshotIds.contains(snapshot.id)
    }

    public func filteredSnapshots(_ snapshots: [WidgetMonitorSnapshot]) -> [WidgetMonitorSnapshot] {
        snapshots.filter(includes)
    }

    private static func normalizedPinnedIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
    }
}

public final class WidgetMonitoringPreferencesStore {
    private let appGroupIdentifier: String
    private let fileName: String
    private let fileManager: FileManager
    private let directoryOverride: URL?

    public init(
        appGroupIdentifier: String = WidgetSnapshotConfiguration.appGroupIdentifier,
        fileName: String = WidgetSnapshotConfiguration.preferencesFileName,
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.fileName = fileName
        self.fileManager = fileManager
        self.directoryOverride = directoryURL
    }

    public var preferencesURL: URL {
        get throws {
            try preferencesDirectoryURL().appendingPathComponent(fileName)
        }
    }

    public func loadPreferences() throws -> WidgetMonitoringPreferences {
        let url = try preferencesURL
        guard fileManager.fileExists(atPath: url.path) else { return .default }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(WidgetMonitoringPreferences.self, from: data)
    }

    public func save(_ preferences: WidgetMonitoringPreferences) throws {
        let target = try preferencesURL
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try Self.encoder.encode(preferences)
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

    private func preferencesDirectoryURL() throws -> URL {
        if let directoryOverride {
            return directoryOverride
        }
        guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw WidgetSnapshotStoreError.appGroupContainerUnavailable(appGroupIdentifier)
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
