import Foundation

// MARK: - File entry model

public enum FileType: String, Codable, Sendable {
    case file
    case directory
    case symlink
}

public struct FileEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(path):\(name)" }
    public var name: String
    public var path: String
    public var size: UInt64
    public var modified: Date?
    public var permissions: String?
    public var owner: String?
    public var group: String?
    public var type: FileType
    public var isExpanded: Bool = false
    public var children: [FileEntry]?
    public var error: String?

    public init(
        name: String,
        path: String,
        size: UInt64 = 0,
        modified: Date? = nil,
        permissions: String? = nil,
        owner: String? = nil,
        group: String? = nil,
        type: FileType = .file,
        children: [FileEntry]? = nil
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.type = type
        self.children = children
    }
}

// MARK: - Browser state

public enum FileBrowserSide: String, Codable, Sendable {
    case local
    case remote
}

public struct FileBrowserState: Codable, Sendable {
    public var localPath: String
    public var remotePath: String
    public var localFiles: [FileEntry]
    public var remoteFiles: [FileEntry]
    public var selectedLocal: Set<String>
    public var selectedRemote: Set<String>
    public var isLoading: Bool
    public var error: String?

    public static let initial = FileBrowserState(
        localPath: NSHomeDirectory(),
        remotePath: "/",
        localFiles: [],
        remoteFiles: [],
        selectedLocal: [],
        selectedRemote: [],
        isLoading: false
    )

    public init(
        localPath: String,
        remotePath: String,
        localFiles: [FileEntry],
        remoteFiles: [FileEntry],
        selectedLocal: Set<String>,
        selectedRemote: Set<String>,
        isLoading: Bool,
        error: String? = nil
    ) {
        self.localPath = localPath
        self.remotePath = remotePath
        self.localFiles = localFiles
        self.remoteFiles = remoteFiles
        self.selectedLocal = selectedLocal
        self.selectedRemote = selectedRemote
        self.isLoading = isLoading
        self.error = error
    }
}

// MARK: - Transfer item

public enum TransferDirection: String, Codable, Sendable {
    case upload
    case download
}

public enum TransferStatus: String, Codable, Sendable {
    case queued
    case inProgress
    case completed
    case failed
}

public struct TransferItem: Codable, Identifiable, Sendable {
    public var id: String
    public var direction: TransferDirection
    public var localPath: String
    public var remotePath: String
    public var size: UInt64
    public var bytesTransferred: UInt64
    public var status: TransferStatus
    public var error: String?
    public var connectionId: String

    public init(
        id: String,
        direction: TransferDirection,
        localPath: String,
        remotePath: String,
        size: UInt64,
        bytesTransferred: UInt64,
        status: TransferStatus,
        error: String? = nil,
        connectionId: String
    ) {
        self.id = id
        self.direction = direction
        self.localPath = localPath
        self.remotePath = remotePath
        self.size = size
        self.bytesTransferred = bytesTransferred
        self.status = status
        self.error = error
        self.connectionId = connectionId
    }

    public var progress: Double {
        size > 0 ? Double(bytesTransferred) / Double(size) : 0
    }

    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

// MARK: - Formatters

public func formatFileSize(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
}

public func formatTimestamp(_ date: Date?) -> String {
    guard let date else { return "—" }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}
