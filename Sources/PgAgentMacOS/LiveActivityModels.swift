import Foundation

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

public enum LiveActivitySnapshotConfiguration {
    public static let fileName = SharedAppStorageConfiguration.liveActivitySnapshotsFileName
    public static let schemaVersion = 1
    public static let maximumSnapshots = 24
}

public enum LiveActivityOperationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case command
    case transfer
    case tunnel
    case offlineSync
    case shortcut
    case fileProvider
    case shareUpload
    case other
}

public enum LiveActivityOperationState: String, Codable, CaseIterable, Hashable, Sendable {
    case queued
    case waitingForApproval
    case running
    case completed
    case failed
    case cancelled
    case stale

    public var isActive: Bool {
        switch self {
        case .queued, .waitingForApproval, .running:
            return true
        case .completed, .failed, .cancelled, .stale:
            return false
        }
    }
}

public struct LiveActivitySnapshot: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var profileId: String?
    public var connectionId: String?
    public var kind: LiveActivityOperationKind
    public var title: String
    public var subtitle: String?
    public var state: LiveActivityOperationState
    public var progress: Double?
    public var createdAt: Date
    public var startedAt: Date?
    public var updatedAt: Date
    public var endedAt: Date?
    public var errorMessage: String?
    public var openURL: String?
    public var metadata: [String: String]

    public init(
        id: String,
        profileId: String? = nil,
        connectionId: String? = nil,
        kind: LiveActivityOperationKind,
        title: String,
        subtitle: String? = nil,
        state: LiveActivityOperationState,
        progress: Double? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        updatedAt: Date = Date(),
        endedAt: Date? = nil,
        errorMessage: String? = nil,
        openURL: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.profileId = profileId?.nilIfBlank
        self.connectionId = connectionId?.nilIfBlank
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).fallback("Midnight SSH")
        self.subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.state = state
        self.progress = progress.map { min(1, max(0, $0)) }
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.endedAt = endedAt
        self.errorMessage = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.openURL = openURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.metadata = metadata.filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var isActive: Bool {
        state.isActive
    }

    public var progressPercentText: String? {
        guard let progress else { return nil }
        return "\(Int((progress * 100).rounded()))%"
    }

    public static func backgroundOperation(
        _ operation: BackgroundSSHOperationRecord,
        now: Date = Date()
    ) -> LiveActivitySnapshot {
        LiveActivitySnapshot(
            id: "background:\(operation.id)",
            profileId: operation.profileId,
            connectionId: operation.metadata?["connectionId"],
            kind: liveActivityKind(for: operation.kind),
            title: operation.title,
            subtitle: operation.detail ?? subtitle(for: operation),
            state: liveActivityState(for: operation.status),
            progress: operation.progress.fractionCompleted,
            createdAt: operation.createdAt,
            startedAt: operation.startedAt,
            updatedAt: operation.updatedAt,
            endedAt: operation.completedAt,
            errorMessage: operation.errorMessage,
            openURL: "pgAgent://automation/\(operation.id)",
            metadata: operation.metadata ?? [:]
        )
    }

    public static func portForward(
        _ record: PortForwardRuntimeRecord,
        now: Date = Date()
    ) -> LiveActivitySnapshot {
        LiveActivitySnapshot(
            id: "tunnel:\(record.id)",
            profileId: record.profileId,
            connectionId: record.connectionId,
            kind: .tunnel,
            title: record.name,
            subtitle: record.summary,
            state: liveActivityState(for: record.state),
            createdAt: record.startedAt ?? record.updatedAt,
            startedAt: record.startedAt,
            updatedAt: record.updatedAt,
            endedAt: record.state.isActive ? nil : record.updatedAt,
            errorMessage: record.lastError,
            openURL: "pgAgent://monitoring/\(record.profileId)",
            metadata: [
                "portForwardId": record.id,
                "kind": record.kind.rawValue,
                "bindHost": record.bindHost,
                "boundPort": String(record.effectiveBindPort),
                "bytesIn": String(record.bytesIn),
                "bytesOut": String(record.bytesOut),
                "connectionCount": String(record.connectionCount),
            ]
        )
    }

    public static func shellIntegration(
        _ command: ShellIntegrationCommand,
        connectionId: String?,
        now: Date = Date()
    ) -> LiveActivitySnapshot {
        LiveActivitySnapshot(
            id: "shell:\(command.id ?? UUID().uuidString)",
            profileId: command.metadata["profileId"],
            connectionId: connectionId,
            kind: LiveActivityOperationKind(rawValue: command.metadata["kind"] ?? "") ?? .command,
            title: command.title ?? "Remote command",
            subtitle: command.body,
            state: LiveActivityOperationState(rawValue: command.state ?? "") ?? .running,
            progress: command.progress,
            createdAt: now,
            startedAt: now,
            updatedAt: now,
            endedAt: (LiveActivityOperationState(rawValue: command.state ?? "")?.isActive == false) ? now : nil,
            errorMessage: command.metadata["error"],
            openURL: command.openURL,
            metadata: command.metadata
        )
    }

    private static func liveActivityKind(for kind: BackgroundSSHOperationKind) -> LiveActivityOperationKind {
        switch kind {
        case .runCommand:
            return .command
        case .sftpUpload, .sftpDownload, .sftpDelete, .sftpCreateDirectory, .sftpRename:
            return .transfer
        case .offlineFolderSync:
            return .offlineSync
        case .fileProviderFetch:
            return .fileProvider
        case .shareUpload:
            return .shareUpload
        case .shortcutRun:
            return .shortcut
        case .portForward:
            return .tunnel
        }
    }

    private static func liveActivityState(for status: BackgroundSSHOperationStatus) -> LiveActivityOperationState {
        switch status {
        case .queued:
            return .queued
        case .waitingForApproval:
            return .waitingForApproval
        case .running:
            return .running
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        }
    }

    private static func liveActivityState(for state: PortForwardRuntimeState) -> LiveActivityOperationState {
        switch state {
        case .starting, .running:
            return .running
        case .stopped:
            return .cancelled
        case .failed, .unsupported:
            return .failed
        }
    }

    private static func subtitle(for operation: BackgroundSSHOperationRecord) -> String? {
        if let remotePath = operation.remotePath?.nilIfBlank {
            return remotePath
        }
        if let localFilePath = operation.localFilePath?.nilIfBlank {
            return URL(fileURLWithPath: localFilePath).lastPathComponent
        }
        return operation.errorMessage
    }
}

public struct LiveActivitySnapshotFile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var snapshots: [LiveActivitySnapshot]

    public static let empty = LiveActivitySnapshotFile()

    public init(
        schemaVersion: Int = LiveActivitySnapshotConfiguration.schemaVersion,
        generatedAt: Date = Date(),
        snapshots: [LiveActivitySnapshot] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.snapshots = snapshots
    }
}

public final class LiveActivitySnapshotStore: @unchecked Sendable {
    private let store: SharedJSONFileStore<LiveActivitySnapshotFile>
    private let directoryURL: URL?

    public init(
        fileName: String = LiveActivitySnapshotConfiguration.fileName,
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.store = SharedJSONFileStore(
            fileName: fileName,
            fileManager: fileManager,
            directoryURL: directoryURL
        )
    }

    public func load() throws -> LiveActivitySnapshotFile {
        try store.load(default: .empty)
    }

    public func save(_ snapshotFile: LiveActivitySnapshotFile) throws {
        let pruned = snapshotFile.pruned()
        try store.save(pruned)
        try? WatchStatusSnapshotStore(directoryURL: directoryURL).refresh(liveActivitySnapshotFile: pruned)
    }

    public func upsert(_ snapshot: LiveActivitySnapshot) throws {
        var file = try load()
        if let index = file.snapshots.firstIndex(where: { $0.id == snapshot.id }) {
            file.snapshots[index] = snapshot
        } else {
            file.snapshots.append(snapshot)
        }
        file.generatedAt = Date()
        try save(file)
    }

    public func remove(id: String) throws {
        var file = try load()
        file.snapshots.removeAll { $0.id == id }
        file.generatedAt = Date()
        try save(file)
    }
}

public enum LiveActivityPresenter {
    public static func stateLabel(for state: LiveActivityOperationState) -> String {
        switch state {
        case .queued:
            return "Queued"
        case .waitingForApproval:
            return "Approval"
        case .running:
            return "Running"
        case .completed:
            return "Done"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Stopped"
        case .stale:
            return "Stale"
        }
    }
}

public extension Notification.Name {
    static let backgroundSSHOperationDidChange = Notification.Name("com.mc-ssh.background-ssh-operation.changed")
    static let backgroundSSHOperationWasRemoved = Notification.Name("com.mc-ssh.background-ssh-operation.removed")
}

#if os(iOS) && canImport(ActivityKit)
@available(iOS 16.1, *)
public struct MidnightSSHOperationActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var subtitle: String?
        public var state: LiveActivityOperationState
        public var progress: Double?
        public var updatedAt: Date
        public var errorMessage: String?

        public init(
            subtitle: String? = nil,
            state: LiveActivityOperationState,
            progress: Double? = nil,
            updatedAt: Date = Date(),
            errorMessage: String? = nil
        ) {
            self.subtitle = subtitle
            self.state = state
            self.progress = progress
            self.updatedAt = updatedAt
            self.errorMessage = errorMessage
        }
    }

    public var snapshotId: String
    public var kind: LiveActivityOperationKind
    public var title: String
    public var openURL: String?

    public init(snapshotId: String, kind: LiveActivityOperationKind, title: String, openURL: String? = nil) {
        self.snapshotId = snapshotId
        self.kind = kind
        self.title = title
        self.openURL = openURL
    }
}

@available(iOS 16.1, *)
public extension MidnightSSHOperationActivityAttributes.ContentState {
    init(snapshot: LiveActivitySnapshot) {
        self.init(
            subtitle: snapshot.subtitle,
            state: snapshot.state,
            progress: snapshot.progress,
            updatedAt: snapshot.updatedAt,
            errorMessage: snapshot.errorMessage
        )
    }
}

@available(iOS 16.1, *)
public extension MidnightSSHOperationActivityAttributes {
    init(snapshot: LiveActivitySnapshot) {
        self.init(
            snapshotId: snapshot.id,
            kind: snapshot.kind,
            title: snapshot.title,
            openURL: snapshot.openURL
        )
    }
}
#endif

private extension LiveActivitySnapshotFile {
    func pruned(now: Date = Date()) -> LiveActivitySnapshotFile {
        let active = snapshots.filter(\.isActive)
        let recentTerminal = snapshots
            .filter { !$0.isActive }
            .filter { snapshot in
                guard let endedAt = snapshot.endedAt else { return true }
                return now.timeIntervalSince(endedAt) < 24 * 60 * 60
            }

        let sorted = (active + recentTerminal)
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive {
                    return lhs.isActive && !rhs.isActive
                }
                return lhs.updatedAt > rhs.updatedAt
            }

        return LiveActivitySnapshotFile(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            snapshots: Array(sorted.prefix(LiveActivitySnapshotConfiguration.maximumSnapshots))
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func fallback(_ value: String) -> String {
        isEmpty ? value : self
    }
}
