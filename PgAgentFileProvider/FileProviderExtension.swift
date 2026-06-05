import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let integrationStore = PlatformIntegrationStore()
    private let manifestStore = OfflineSFTPCacheManifestStore()
    private let operationStore = BackgroundSSHOperationStore()
    private let stagingStore = SharedUploadStagingStore()

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> any NSFileProviderEnumerator {
        let rawIdentifier = rawCatalogIdentifier(containerItemIdentifier)
        guard catalog().item(rawIdentifier: rawIdentifier)?.isDirectory == true else {
            throw NSFileProviderError(.noSuchItem)
        }

        if case .offlineRoot(let folderId) = OfflineSFTPFileProviderIdentifier(rawValue: rawIdentifier) {
            queueSync(folderId: folderId, remotePath: catalog().item(rawIdentifier: rawIdentifier)?.remotePath)
        }

        return FileProviderEnumerator(
            containerIdentifier: rawIdentifier,
            catalogProvider: { [weak self] in self?.catalog() ?? FileProviderCatalog(integrations: .empty, manifest: .empty) }
        )
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let rawIdentifier = rawCatalogIdentifier(identifier)
        guard let catalogItem = catalog().item(rawIdentifier: rawIdentifier) else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        }
        completionHandler(FileProviderItem(item: catalogItem), nil)
        progress.completedUnitCount = 1
        return progress
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let rawIdentifier = rawCatalogIdentifier(itemIdentifier)
        guard let catalogItem = catalog().item(rawIdentifier: rawIdentifier), !catalogItem.isDirectory else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        }

        if let localCachePath = catalogItem.localCachePath,
           FileManager.default.fileExists(atPath: localCachePath) {
            completionHandler(URL(fileURLWithPath: localCachePath), FileProviderItem(item: catalogItem), nil)
        } else {
            queueFetch(for: catalogItem)
            completionHandler(nil, FileProviderItem(item: catalogItem), NSFileProviderError(.serverUnreachable))
        }

        progress.completedUnitCount = 1
        return progress
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let parentRaw = rawCatalogIdentifier(itemTemplate.parentItemIdentifier)
        guard let target = catalog().remotePath(forParent: parentRaw, filename: itemTemplate.filename) else {
            completionHandler(nil, fields, false, NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        }

        if let url {
            queueUpload(
                localURL: url,
                profileId: profileId(forFolderId: target.folderId),
                remotePath: target.remotePath,
                title: "Upload \(itemTemplate.filename)",
                itemIdentifier: itemTemplate.itemIdentifier.rawValue
            )
        } else {
            queueDirectoryCreate(
                profileId: profileId(forFolderId: target.folderId),
                remotePath: target.remotePath,
                itemIdentifier: itemTemplate.itemIdentifier.rawValue
            )
        }

        completionHandler(itemTemplate, [], false, nil)
        progress.completedUnitCount = 1
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let rawIdentifier = rawCatalogIdentifier(item.itemIdentifier)
        guard let catalogItem = catalog().item(rawIdentifier: rawIdentifier),
              let profileId = catalogItem.folderId.map(profileId(forFolderId:)),
              let remotePath = catalogItem.remotePath else {
            completionHandler(nil, changedFields, false, NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        }

        if let newContents {
            queueUpload(
                localURL: newContents,
                profileId: profileId,
                remotePath: remotePath,
                title: "Update \(item.filename)",
                itemIdentifier: item.itemIdentifier.rawValue
            )
        } else {
            queueMetadataChange(
                profileId: profileId,
                remotePath: remotePath,
                itemIdentifier: item.itemIdentifier.rawValue,
                filename: item.filename
            )
        }

        completionHandler(item, [], false, nil)
        progress.completedUnitCount = 1
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let rawIdentifier = rawCatalogIdentifier(identifier)
        guard let catalogItem = catalog().item(rawIdentifier: rawIdentifier),
              let profileId = catalogItem.folderId.map(profileId(forFolderId:)),
              let remotePath = catalogItem.remotePath else {
            completionHandler(nil)
            progress.completedUnitCount = 1
            return progress
        }

        let operation = BackgroundSSHOperationRecord(
            profileId: profileId,
            kind: .sftpDelete,
            requester: .fileProvider,
            status: .queued,
            title: "Delete \(catalogItem.filename)",
            remotePath: remotePath,
            itemIdentifier: identifier.rawValue
        )
        try? operationStore.upsert(operation)
        completionHandler(nil)
        progress.completedUnitCount = 1
        return progress
    }

    private func catalog() -> FileProviderCatalog {
        let integrations = (try? integrationStore.load()) ?? .empty
        let manifest = (try? manifestStore.load()) ?? .empty
        return FileProviderCatalog(integrations: integrations, manifest: manifest)
    }

    private func rawCatalogIdentifier(_ identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? OfflineSFTPFileProviderIdentifier.root.rawValue : identifier.rawValue
    }

    private func profileId(forFolderId folderId: String) -> String {
        catalog().integrations.offlineFolders.first(where: { $0.id == folderId })?.profileId ?? folderId
    }

    private func queueSync(folderId: String, remotePath: String?) {
        let operation = BackgroundSSHOperationRecord(
            profileId: profileId(forFolderId: folderId),
            kind: .offlineFolderSync,
            requester: .fileProvider,
            status: .queued,
            title: "Sync offline folder",
            remotePath: remotePath,
            itemIdentifier: OfflineSFTPFileProviderIdentifier.offlineRoot(folderId: folderId).rawValue
        )
        try? operationStore.upsert(operation)
    }

    private func queueFetch(for item: FileProviderCatalogItem) {
        let operation = BackgroundSSHOperationRecord(
            profileId: item.folderId.map(profileId(forFolderId:)) ?? "unassigned",
            kind: .fileProviderFetch,
            requester: .fileProvider,
            status: .queued,
            title: "Fetch \(item.filename)",
            remotePath: item.remotePath,
            itemIdentifier: item.id
        )
        try? operationStore.upsert(operation)
    }

    private func queueUpload(
        localURL: URL,
        profileId: String,
        remotePath: String,
        title: String,
        itemIdentifier: String
    ) {
        let staged = try? stagingStore.stageFile(from: localURL)
        let operation = BackgroundSSHOperationRecord(
            profileId: profileId,
            kind: .sftpUpload,
            requester: .fileProvider,
            status: .queued,
            title: title,
            localFilePath: staged?.localPath ?? localURL.path,
            remotePath: remotePath,
            itemIdentifier: itemIdentifier,
            metadata: staged.map { ["stagedUploadId": $0.id, "fileName": $0.fileName] }
        )
        try? operationStore.upsert(operation)
    }

    private func queueDirectoryCreate(profileId: String, remotePath: String, itemIdentifier: String) {
        let operation = BackgroundSSHOperationRecord(
            profileId: profileId,
            kind: .sftpCreateDirectory,
            requester: .fileProvider,
            status: .queued,
            title: "Create folder",
            remotePath: remotePath,
            itemIdentifier: itemIdentifier
        )
        try? operationStore.upsert(operation)
    }

    private func queueMetadataChange(profileId: String, remotePath: String, itemIdentifier: String, filename: String) {
        let operation = BackgroundSSHOperationRecord(
            profileId: profileId,
            kind: .sftpRename,
            requester: .fileProvider,
            status: .queued,
            title: "Update \(filename)",
            remotePath: remotePath,
            itemIdentifier: itemIdentifier,
            metadata: ["filename": filename]
        )
        try? operationStore.upsert(operation)
    }
}

private final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerIdentifier: String
    private let catalogProvider: () -> FileProviderCatalog

    init(containerIdentifier: String, catalogProvider: @escaping () -> FileProviderCatalog) {
        self.containerIdentifier = containerIdentifier
        self.catalogProvider = catalogProvider
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let items = catalogProvider()
            .children(rawIdentifier: containerIdentifier)
            .map(FileProviderItem.init(item:))
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from syncAnchor: NSFileProviderSyncAnchor
    ) {
        observer.finishEnumeratingChanges(upTo: currentSyncAnchor(), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(currentSyncAnchor())
    }

    private func currentSyncAnchor() -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8))
    }
}

private final class FileProviderItem: NSObject, NSFileProviderItem {
    let item: FileProviderCatalogItem

    init(item: FileProviderCatalogItem) {
        self.item = item
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        item.id == OfflineSFTPFileProviderIdentifier.root.rawValue
            ? .rootContainer
            : NSFileProviderItemIdentifier(item.id)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        item.parentId == OfflineSFTPFileProviderIdentifier.root.rawValue
            ? .rootContainer
            : NSFileProviderItemIdentifier(item.parentId)
    }

    var filename: String { item.filename }

    var typeIdentifier: String {
        switch item.fileType {
        case .directory:
            return UTType.folder.identifier
        case .symlink:
            return UTType.symbolicLink.identifier
        case .file:
            return UTType(filenameExtension: (item.filename as NSString).pathExtension)?.identifier
                ?? UTType.data.identifier
        }
    }

    var documentSize: NSNumber? {
        item.fileType == .file ? NSNumber(value: item.size) : nil
    }

    var contentModificationDate: Date? {
        item.modifiedAt
    }

    var capabilities: NSFileProviderItemCapabilities {
        if item.fileType == .directory {
            return [.allowsReading, .allowsWriting, .allowsAddingSubItems, .allowsRenaming, .allowsDeleting]
        }
        return [.allowsReading, .allowsWriting, .allowsRenaming, .allowsDeleting]
    }
}
