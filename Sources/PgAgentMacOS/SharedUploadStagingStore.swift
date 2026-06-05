import Foundation

public struct SharedStagedUpload: Codable, Equatable, Sendable {
    public var id: String
    public var fileName: String
    public var localPath: String
    public var stagedAt: Date
    public var size: UInt64

    public init(
        id: String = UUID().uuidString,
        fileName: String,
        localPath: String,
        stagedAt: Date = Date(),
        size: UInt64
    ) {
        self.id = id
        self.fileName = fileName
        self.localPath = localPath
        self.stagedAt = stagedAt
        self.size = size
    }
}

public final class SharedUploadStagingStore: @unchecked Sendable {
    private let appGroupIdentifier: String
    private let fileManager: FileManager
    private let directoryOverride: URL?

    public init(
        appGroupIdentifier: String = SharedAppStorageConfiguration.appGroupIdentifier,
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.fileManager = fileManager
        self.directoryOverride = directoryURL
    }

    public func stageFile(from sourceURL: URL, suggestedName: String? = nil, now: Date = Date()) throws -> SharedStagedUpload {
        let directory = try stagingDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = sanitizedFileName(suggestedName ?? sourceURL.lastPathComponent)
        let destination = directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(fileName)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)

        let attrs = try fileManager.attributesOfItem(atPath: destination.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        return SharedStagedUpload(
            fileName: fileName,
            localPath: destination.path,
            stagedAt: now,
            size: size
        )
    }

    private func stagingDirectoryURL() throws -> URL {
        if let directoryOverride {
            return directoryOverride.appendingPathComponent(SharedAppStorageConfiguration.stagedUploadsDirectoryName, isDirectory: true)
        }
        guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw SharedJSONFileStoreError.appGroupContainerUnavailable(appGroupIdentifier)
        }
        return url.appendingPathComponent(SharedAppStorageConfiguration.stagedUploadsDirectoryName, isDirectory: true)
    }

    private func sanitizedFileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "upload" : trimmed
        return fallback
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}
