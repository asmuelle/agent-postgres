import Foundation

public enum BackgroundSSHOperationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case runCommand
    case sftpUpload
    case sftpDownload
    case sftpDelete
    case sftpCreateDirectory
    case sftpRename
    case offlineFolderSync
    case fileProviderFetch
    case shareUpload
    case shortcutRun
    case portForward
}

public enum BackgroundSSHOperationStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case queued
    case waitingForApproval
    case running
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .waitingForApproval, .running:
            return false
        }
    }
}

public struct BackgroundSSHOperationProgress: Codable, Equatable, Sendable {
    public var completedUnitCount: Int64
    public var totalUnitCount: Int64?

    public init(completedUnitCount: Int64 = 0, totalUnitCount: Int64? = nil) {
        self.completedUnitCount = max(0, completedUnitCount)
        if let totalUnitCount {
            self.totalUnitCount = max(0, totalUnitCount)
        } else {
            self.totalUnitCount = nil
        }
    }

    public var fractionCompleted: Double? {
        guard let totalUnitCount, totalUnitCount > 0 else { return nil }
        return min(1, Double(completedUnitCount) / Double(totalUnitCount))
    }
}

public struct BackgroundSSHOperationRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var profileId: String
    public var kind: BackgroundSSHOperationKind
    public var requester: PlatformIntegrationRequester
    public var approvalPolicy: AutomationApprovalPolicy
    public var status: BackgroundSSHOperationStatus
    public var title: String
    public var detail: String?
    public var progress: BackgroundSSHOperationProgress
    public var createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var errorMessage: String?
    public var localFilePath: String?
    public var remotePath: String?
    public var itemIdentifier: String?
    public var metadata: [String: String]?

    public init(
        id: String = UUID().uuidString,
        profileId: String,
        kind: BackgroundSSHOperationKind,
        requester: PlatformIntegrationRequester,
        approvalPolicy: AutomationApprovalPolicy = .manual,
        status: BackgroundSSHOperationStatus = .queued,
        title: String,
        detail: String? = nil,
        progress: BackgroundSSHOperationProgress = BackgroundSSHOperationProgress(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        errorMessage: String? = nil,
        localFilePath: String? = nil,
        remotePath: String? = nil,
        itemIdentifier: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.kind = kind
        self.requester = requester
        self.approvalPolicy = approvalPolicy
        self.status = status
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail
        self.progress = progress
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.localFilePath = localFilePath
        self.remotePath = remotePath
        self.itemIdentifier = itemIdentifier
        self.metadata = metadata
    }

    public func updating(
        status: BackgroundSSHOperationStatus,
        progress: BackgroundSSHOperationProgress? = nil,
        errorMessage: String? = nil,
        now: Date = Date()
    ) -> BackgroundSSHOperationRecord {
        var copy = self
        copy.status = status
        if let progress {
            copy.progress = progress
        }
        copy.updatedAt = now
        copy.errorMessage = errorMessage
        if status == .running, copy.startedAt == nil {
            copy.startedAt = now
        }
        if status.isTerminal {
            copy.completedAt = now
        }
        return copy
    }
}

public struct BackgroundSSHOperationStoreData: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var operations: [BackgroundSSHOperationRecord]

    public static let empty = BackgroundSSHOperationStoreData()

    public init(
        schemaVersion: Int = PlatformIntegrationSchema.currentVersion,
        operations: [BackgroundSSHOperationRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.operations = operations
    }
}

public final class BackgroundSSHOperationStore: @unchecked Sendable {
    private let store: SharedJSONFileStore<BackgroundSSHOperationStoreData>

    public init(
        fileName: String = SharedAppStorageConfiguration.backgroundOperationsFileName,
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.store = SharedJSONFileStore(
            fileName: fileName,
            fileManager: fileManager,
            directoryURL: directoryURL
        )
    }

    public func load() throws -> BackgroundSSHOperationStoreData {
        try store.load(default: .empty)
    }

    public func save(_ data: BackgroundSSHOperationStoreData) throws {
        try store.save(data)
    }

    public func upsert(_ operation: BackgroundSSHOperationRecord) throws {
        var data = try load()
        if let index = data.operations.firstIndex(where: { $0.id == operation.id }) {
            data.operations[index] = operation
        } else {
            data.operations.append(operation)
        }
        data.operations.sort { $0.createdAt > $1.createdAt }
        try save(data)
        NotificationCenter.default.post(name: .backgroundSSHOperationDidChange, object: operation)
    }

    public func update(
        id: String,
        status: BackgroundSSHOperationStatus,
        progress: BackgroundSSHOperationProgress? = nil,
        errorMessage: String? = nil,
        now: Date = Date()
    ) throws {
        var data = try load()
        guard let index = data.operations.firstIndex(where: { $0.id == id }) else { return }
        data.operations[index] = data.operations[index].updating(
            status: status,
            progress: progress,
            errorMessage: errorMessage,
            now: now
        )
        try save(data)
        NotificationCenter.default.post(name: .backgroundSSHOperationDidChange, object: data.operations[index])
    }

    public func remove(id: String) throws {
        var data = try load()
        data.operations.removeAll { $0.id == id }
        try save(data)
        NotificationCenter.default.post(name: .backgroundSSHOperationWasRemoved, object: id)
    }
}
