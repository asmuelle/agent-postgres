import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let integrationStore = PlatformIntegrationStore()
    private let operationStore = BackgroundSSHOperationStore()
    private let stagingStore = SharedUploadStagingStore()

    override func viewDidLoad() {
        super.viewDidLoad()
        queueSharedItems()
    }

    private func queueSharedItems() {
        guard let inputItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            complete()
            return
        }

        let providers = inputItems.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            complete()
            return
        }

        let group = DispatchGroup()
        var queuedCount = 0
        let lock = NSLock()

        for provider in providers {
            guard let typeIdentifier = preferredTypeIdentifier(for: provider) else { continue }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
                defer { group.leave() }
                guard let self else { return }
                if let url {
                    do {
                        try self.queueUpload(sourceURL: url, contentType: typeIdentifier)
                        lock.lock()
                        queuedCount += 1
                        lock.unlock()
                    } catch {
                        self.recordFailure(error.localizedDescription, contentType: typeIdentifier)
                    }
                } else {
                    self.recordFailure(error?.localizedDescription ?? "Shared item did not provide a file representation.", contentType: typeIdentifier)
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            if queuedCount == 0 {
                self?.recordFailure("No shared files could be queued.", contentType: nil)
            }
            self?.complete()
        }
    }

    private func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return UTType.fileURL.identifier
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
            return provider.registeredTypeIdentifiers.first { type in
                UTType(type)?.conforms(to: .item) == true
            } ?? UTType.item.identifier
        }
        return provider.registeredTypeIdentifiers.first
    }

    private func queueUpload(sourceURL: URL, contentType: String?) throws {
        let staged = try stagingStore.stageFile(from: sourceURL)
        let integrations = (try? integrationStore.load()) ?? .empty
        let destination = integrations.preferredShareDestination(contentType: contentType)
            ?? integrations.preferredShareDestination()
        let remotePath = remoteUploadPath(basePath: destination?.remotePath ?? "/", fileName: staged.fileName)

        let operation = BackgroundSSHOperationRecord(
            profileId: destination?.profileId ?? "unassigned",
            kind: .shareUpload,
            requester: .shareExtension,
            status: destination == nil ? .waitingForApproval : .queued,
            title: "Upload \(staged.fileName)",
            detail: destination == nil ? "Choose a server and destination in Midnight SSH." : nil,
            localFilePath: staged.localPath,
            remotePath: remotePath,
            metadata: [
                "stagedUploadId": staged.id,
                "fileName": staged.fileName,
                "contentType": contentType ?? "",
                "size": String(staged.size),
            ]
        )
        try operationStore.upsert(operation)
    }

    private func recordFailure(_ message: String, contentType: String?) {
        let operation = BackgroundSSHOperationRecord(
            profileId: "unassigned",
            kind: .shareUpload,
            requester: .shareExtension,
            status: .failed,
            title: "Shared upload failed",
            detail: message,
            errorMessage: message,
            metadata: ["contentType": contentType ?? ""]
        )
        try? operationStore.upsert(operation)
    }

    private func remoteUploadPath(basePath: String, fileName: String) -> String {
        let base = ShareUploadDestinationRecord.normalizedRemotePath(basePath)
        return base == "/" ? "/\(fileName)" : "\(base)/\(fileName)"
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
