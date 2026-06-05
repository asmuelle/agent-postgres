import Foundation

// MARK: - Widget snapshot configuration

public enum WidgetSnapshotConfiguration {
    public static let appGroupIdentifier = "group.com.pgagent.pgagent"
    public static let fileName = "monitoring-snapshots.json"
    public static let preferencesFileName = "monitoring-widget-preferences.json"
    public static let schemaVersion = 1
    public static let widgetKind = "MidnightSSHMonitoringWidget"
    public static let iOSWidgetKind = "MidnightSSHMobileMonitoringWidget"
}

// MARK: - Snapshot state

public enum WidgetMonitorState: String, Codable, CaseIterable, Hashable, Sendable {
    case up
    case down
    case degraded
    case unknown
    case stale
    case paused

    public var isConfirmedFailure: Bool {
        self == .down
    }
}

public enum WidgetMonitorKind: String, Codable, CaseIterable, Hashable, Sendable {
    case host
    case tunnel
    case postgres
    case sftp
    case port
    case custom
}

public enum WidgetSnapshotFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case aging
    case stale
    case neverChecked
}

public struct WidgetSnapshotFreshnessPolicy: Equatable, Sendable {
    public var freshInterval: TimeInterval
    public var staleInterval: TimeInterval

    public static let `default` = WidgetSnapshotFreshnessPolicy(
        freshInterval: 15 * 60,
        staleInterval: 60 * 60
    )

    public init(freshInterval: TimeInterval, staleInterval: TimeInterval) {
        precondition(freshInterval >= 0, "freshInterval must be non-negative")
        precondition(staleInterval >= freshInterval, "staleInterval must be greater than or equal to freshInterval")
        self.freshInterval = freshInterval
        self.staleInterval = staleInterval
    }
}

public struct WidgetMonitorSnapshot: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var kind: WidgetMonitorKind
    public var state: WidgetMonitorState
    public var lastCheckedAt: Date?
    public var lastChangedAt: Date?
    public var summary: String
    public var detail: String?
    public var openURL: String?

    public init(
        id: String,
        displayName: String,
        kind: WidgetMonitorKind,
        state: WidgetMonitorState,
        lastCheckedAt: Date?,
        lastChangedAt: Date? = nil,
        summary: String,
        detail: String? = nil,
        openURL: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.state = state
        self.lastCheckedAt = lastCheckedAt
        self.lastChangedAt = lastChangedAt
        self.summary = summary
        self.detail = detail
        self.openURL = openURL
    }

    public func freshness(
        now: Date = Date(),
        policy: WidgetSnapshotFreshnessPolicy = .default
    ) -> WidgetSnapshotFreshness {
        guard let lastCheckedAt else { return .neverChecked }
        let age = max(0, now.timeIntervalSince(lastCheckedAt))
        if age < policy.freshInterval {
            return .fresh
        }
        if age <= policy.staleInterval {
            return .aging
        }
        return .stale
    }

    public func displayState(
        now: Date = Date(),
        policy: WidgetSnapshotFreshnessPolicy = .default
    ) -> WidgetMonitorState {
        switch state {
        case .paused:
            return .paused
        case .unknown:
            return .unknown
        case .stale:
            return .stale
        case .up, .down, .degraded:
            switch freshness(now: now, policy: policy) {
            case .neverChecked:
                return .unknown
            case .stale:
                return .stale
            case .fresh, .aging:
                return state
            }
        }
    }

    public static func placeholder(now: Date = Date()) -> WidgetMonitorSnapshot {
        WidgetMonitorSnapshot(
            id: "monitoring-placeholder",
            displayName: "Monitoring",
            kind: .custom,
            state: .unknown,
            lastCheckedAt: nil,
            lastChangedAt: now,
            summary: "Monitoring not configured",
            detail: "Choose watched hosts in Midnight SSH.",
            openURL: nil
        )
    }

    public static func filteredPlaceholder(now: Date = Date()) -> WidgetMonitorSnapshot {
        WidgetMonitorSnapshot(
            id: "monitoring-filtered-placeholder",
            displayName: "Monitoring",
            kind: .custom,
            state: .unknown,
            lastCheckedAt: nil,
            lastChangedAt: now,
            summary: "No matching checks",
            detail: "Adjust widget scope in Midnight SSH.",
            openURL: WidgetSnapshotPresenter.monitoringOverviewURL
        )
    }

    public static func portForward(
        _ record: PortForwardRuntimeRecord,
        now: Date = Date()
    ) -> WidgetMonitorSnapshot {
        let state: WidgetMonitorState
        switch record.state {
        case .running:
            state = .up
        case .starting:
            state = .unknown
        case .stopped:
            state = .paused
        case .failed:
            state = .down
        case .unsupported:
            state = .degraded
        }

        return WidgetMonitorSnapshot(
            id: "port-forward:\(record.id)",
            displayName: record.name,
            kind: .tunnel,
            state: state,
            lastCheckedAt: record.state == .starting ? nil : now,
            lastChangedAt: record.updatedAt,
            summary: record.summary,
            detail: record.lastError,
            openURL: "pgAgent://monitoring/\(record.profileId)"
        )
    }
}

public struct WidgetMonitorSnapshotFile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var snapshots: [WidgetMonitorSnapshot]

    public init(
        schemaVersion: Int = WidgetSnapshotConfiguration.schemaVersion,
        generatedAt: Date = Date(),
        snapshots: [WidgetMonitorSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.snapshots = snapshots
    }
}

public enum WidgetSnapshotReducer {
    public static func overallState(
        for snapshots: [WidgetMonitorSnapshot],
        now: Date = Date(),
        policy: WidgetSnapshotFreshnessPolicy = .default
    ) -> WidgetMonitorState {
        guard !snapshots.isEmpty else { return .unknown }
        let states = snapshots.map { $0.displayState(now: now, policy: policy) }
        if states.contains(.down) { return .down }
        if states.contains(.degraded) { return .degraded }
        if states.contains(.stale) { return .stale }
        if states.contains(.unknown) { return .unknown }
        if states.allSatisfy({ $0 == .paused }) { return .paused }
        return .up
    }
}

public enum WidgetSnapshotStateClassifier {
    public static func state(forTerminalStatus status: TerminalConnectionStatus) -> WidgetMonitorState {
        switch status {
        case .connected:
            return .up
        case .connecting:
            return .unknown
        case .disconnected, .error:
            return .down
        }
    }

    public static func stateForPostgresStatus(_ status: String) -> WidgetMonitorState {
        switch status.lowercased() {
        case "connected":
            return .up
        case "connecting":
            return .unknown
        case "disconnected", "error":
            return .down
        default:
            return .unknown
        }
    }

    public static func stateForSystemdService(active: String, sub: String) -> WidgetMonitorState {
        let active = active.lowercased()
        let sub = sub.lowercased()

        if active == "active" && sub != "failed" {
            return .up
        }
        if active == "failed" || sub == "failed" {
            return .down
        }
        if active == "activating" || active == "deactivating" || active == "reloading" {
            return .degraded
        }
        if active == "unknown" || active == "inactive" || active.isEmpty {
            return .unknown
        }
        return .down
    }
}

// MARK: - Snapshot store

public enum WidgetSnapshotStoreError: LocalizedError, Equatable {
    case appGroupContainerUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .appGroupContainerUnavailable(let identifier):
            return "App Group container is unavailable for \(identifier)."
        }
    }
}

public final class WidgetSnapshotStore {
    private let appGroupIdentifier: String
    private let fileName: String
    private let fileManager: FileManager
    private let directoryOverride: URL?

    public init(
        appGroupIdentifier: String = WidgetSnapshotConfiguration.appGroupIdentifier,
        fileName: String = WidgetSnapshotConfiguration.fileName,
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.fileName = fileName
        self.fileManager = fileManager
        self.directoryOverride = directoryURL
    }

    public var snapshotsURL: URL {
        get throws {
            try snapshotsDirectoryURL().appendingPathComponent(fileName)
        }
    }

    public func loadSnapshotFile() throws -> WidgetMonitorSnapshotFile? {
        let url = try snapshotsURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(WidgetMonitorSnapshotFile.self, from: data)
    }

    public func loadSnapshots() throws -> [WidgetMonitorSnapshot] {
        try loadSnapshotFile()?.snapshots ?? []
    }

    public func save(_ snapshotFile: WidgetMonitorSnapshotFile) throws {
        let target = try snapshotsURL
        let data = try Self.encoder.encode(snapshotFile)
        try write(data, to: target)
        try mirrorToMacOSWidgetContainerIfNeeded(data: data, primaryTarget: target)
        try? WatchStatusSnapshotStore(directoryURL: directoryOverride).refresh(monitoringSnapshotFile: snapshotFile)
    }

    public func saveSnapshots(
        _ snapshots: [WidgetMonitorSnapshot],
        generatedAt: Date = Date()
    ) throws {
        try save(WidgetMonitorSnapshotFile(generatedAt: generatedAt, snapshots: snapshots))
    }

    public func savePlaceholderIfNeeded(now: Date = Date()) throws {
        if let existing = try loadSnapshotFile(), !existing.snapshots.isEmpty {
            return
        }
        try saveSnapshots([.placeholder(now: now)], generatedAt: now)
    }

    private func snapshotsDirectoryURL() throws -> URL {
        if let directoryOverride {
            return directoryOverride
        }
        guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw WidgetSnapshotStoreError.appGroupContainerUnavailable(appGroupIdentifier)
        }
        return url
    }

    private func write(_ data: Data, to target: URL) throws {
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

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

    private func mirrorToMacOSWidgetContainerIfNeeded(data: Data, primaryTarget: URL) throws {
        #if os(macOS)
        guard directoryOverride == nil else { return }
        let mirrorTarget = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("com.pgagent.macos.widgets")
            .appendingPathComponent("Data")
            .appendingPathComponent("Library")
            .appendingPathComponent("Group Containers")
            .appendingPathComponent(appGroupIdentifier)
            .appendingPathComponent(fileName)

        guard primaryTarget.standardizedFileURL != mirrorTarget.standardizedFileURL else { return }
        try? write(data, to: mirrorTarget)
        #endif
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
