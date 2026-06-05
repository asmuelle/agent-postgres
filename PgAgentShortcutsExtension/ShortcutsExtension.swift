import AppIntents
import ExtensionFoundation
import Foundation

@main
struct PgAgentShortcutsExtension: AppIntentsExtension {}

struct MidnightSSHAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListMidnightSSHServersIntent(),
            phrases: ["List servers in \(.applicationName)"],
            shortTitle: "List Servers",
            systemImageName: "server.rack"
        )
        AppShortcut(
            intent: RunMidnightSSHCommandIntent(),
            phrases: ["Run command in \(.applicationName)"],
            shortTitle: "Run Command",
            systemImageName: "terminal"
        )
        AppShortcut(
            intent: UploadMidnightSSHFileIntent(),
            phrases: ["Upload file with \(.applicationName)"],
            shortTitle: "Upload File",
            systemImageName: "square.and.arrow.up"
        )
        AppShortcut(
            intent: DownloadMidnightSSHFileIntent(),
            phrases: ["Download file with \(.applicationName)"],
            shortTitle: "Download File",
            systemImageName: "square.and.arrow.down"
        )
        AppShortcut(
            intent: OpenMidnightSSHTerminalIntent(),
            phrases: ["Open terminal in \(.applicationName)"],
            shortTitle: "Open Terminal",
            systemImageName: "terminal.fill"
        )
        AppShortcut(
            intent: SyncMidnightSSHOfflineFolderIntent(),
            phrases: ["Sync offline folder in \(.applicationName)"],
            shortTitle: "Sync Folder",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: TailMidnightSSHLogsIntent(),
            phrases: ["Tail logs in \(.applicationName)"],
            shortTitle: "Tail Logs",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: StartMidnightSSHMonitorIntent(),
            phrases: ["Start monitor in \(.applicationName)"],
            shortTitle: "Start Monitor",
            systemImageName: "chart.xyaxis.line"
        )
    }
}

struct MidnightSSHServerEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Midnight SSH Server")
    static var defaultQuery = MidnightSSHServerQuery()

    var id: String
    var name: String
    var endpoint: String
    var kind: String
    var supportsTerminal: Bool

    init(record: ShortcutServerRecord) {
        id = record.id
        name = record.displayName
        endpoint = record.endpoint
        kind = record.kind
        supportsTerminal = record.supportsTerminal
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(endpoint)"
        )
    }
}

struct MidnightSSHServerQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MidnightSSHServerEntity] {
        let data = try ShortcutIntentSupport.loadIntegrations()
        return identifiers.compactMap { id in
            data.shortcutServer(id: id).map(MidnightSSHServerEntity.init(record:))
        }
    }

    func entities(matching string: String) async throws -> [MidnightSSHServerEntity] {
        try ShortcutIntentSupport.loadIntegrations()
            .shortcutServers(matching: string)
            .map(MidnightSSHServerEntity.init(record:))
    }

    func suggestedEntities() async throws -> [MidnightSSHServerEntity] {
        try ShortcutIntentSupport.loadIntegrations()
            .shortcutServers(matching: "")
            .prefix(12)
            .map(MidnightSSHServerEntity.init(record:))
    }
}

struct MidnightSSHOfflineFolderEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Midnight SSH Offline Folder")
    static var defaultQuery = MidnightSSHOfflineFolderQuery()

    var id: String
    var profileId: String
    var displayName: String
    var remotePath: String

    init(record: OfflineSFTPFolderRecord) {
        id = record.id
        profileId = record.profileId
        displayName = record.displayName
        remotePath = record.remotePath
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: "\(remotePath)"
        )
    }
}

struct MidnightSSHOfflineFolderQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MidnightSSHOfflineFolderEntity] {
        let folders = try ShortcutIntentSupport.loadIntegrations().offlineFolders
        return identifiers.compactMap { id in
            folders.first(where: { $0.id == id }).map(MidnightSSHOfflineFolderEntity.init(record:))
        }
    }

    func entities(matching string: String) async throws -> [MidnightSSHOfflineFolderEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let folders = try ShortcutIntentSupport.loadIntegrations().offlineFolders
        return folders
            .filter { folder in
                needle.isEmpty
                    || folder.displayName.lowercased().contains(needle)
                    || folder.remotePath.lowercased().contains(needle)
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map(MidnightSSHOfflineFolderEntity.init(record:))
    }

    func suggestedEntities() async throws -> [MidnightSSHOfflineFolderEntity] {
        try await entities(matching: "")
    }
}

enum MidnightSSHAutomationPolicyOption: String, AppEnum {
    case manual
    case biometricPerRun
    case allowBackground

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Automation Approval Policy")
    static var caseDisplayRepresentations: [MidnightSSHAutomationPolicyOption: DisplayRepresentation] = [
        .manual: "Manual Approval",
        .biometricPerRun: "Biometric Approval Per Run",
        .allowBackground: "Allow Background",
    ]

    var policy: AutomationApprovalPolicy {
        switch self {
        case .manual:
            return .manual
        case .biometricPerRun:
            return .biometricPerRun
        case .allowBackground:
            return .allowBackground
        }
    }
}

struct ListMidnightSSHServersIntent: AppIntent {
    static var title: LocalizedStringResource = "List Midnight SSH Servers"
    static var description = IntentDescription("Returns the saved Midnight SSH servers available to Shortcuts.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let data = try ShortcutIntentSupport.loadIntegrations()
        let servers = data.shortcutServers(matching: "")
        let output = servers.isEmpty
            ? "No Midnight SSH servers are available to Shortcuts. Open the app once to publish saved servers."
            : servers.map { "\($0.displayName) - \($0.endpoint)" }.joined(separator: "\n")

        try ShortcutIntentSupport.recordCompletedShortcut(
            title: "List servers shortcut",
            metadata: ["serverCount": String(servers.count)]
        )

        return .result(value: output, dialog: "\(servers.count) server\(servers.count == 1 ? "" : "s") available.")
    }
}

struct UploadMidnightSSHFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Upload File with Midnight SSH"
    static var description = IntentDescription("Queues a file upload to a saved Midnight SSH server.")

    @Parameter(title: "Server")
    var server: MidnightSSHServerEntity

    @Parameter(title: "File")
    var file: IntentFile

    @Parameter(title: "Remote Path")
    var remotePath: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let data = try ShortcutIntentSupport.loadIntegrations()
        let record = try ShortcutIntentSupport.serverRecord(for: server, in: data)
        let staged = try ShortcutIntentSupport.stage(file)
        let destination = ShortcutIntentSupport.remoteUploadPath(
            basePath: remotePath,
            fileName: staged.fileName
        )
        let operation = try ShortcutIntentSupport.queueOperation(
            profileId: record.id,
            kind: .sftpUpload,
            title: "Upload \(staged.fileName)",
            detail: "Shortcut upload to \(destination)",
            localFilePath: staged.localPath,
            remotePath: destination,
            metadata: [
                "action": "uploadFile",
                "stagedUploadId": staged.id,
                "fileName": staged.fileName,
                "size": String(staged.size),
            ],
            integrations: data
        )

        return .result(
            value: operation.id,
            dialog: ShortcutIntentSupport.dialog(for: operation, queuedVerb: "queued", approvalVerb: "needs approval")
        )
    }
}

struct DownloadMidnightSSHFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Download File with Midnight SSH"
    static var description = IntentDescription("Queues a remote file download from a saved Midnight SSH server.")

    @Parameter(title: "Server")
    var server: MidnightSSHServerEntity

    @Parameter(title: "Remote Path")
    var remotePath: String

    @Parameter(title: "Suggested Filename")
    var suggestedFilename: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let data = try ShortcutIntentSupport.loadIntegrations()
        let record = try ShortcutIntentSupport.serverRecord(for: server, in: data)
        let destination = try ShortcutIntentSupport.shortcutDownloadURL(
            suggestedFilename: suggestedFilename,
            remotePath: remotePath
        )
        let operation = try ShortcutIntentSupport.queueOperation(
            profileId: record.id,
            kind: .sftpDownload,
            title: "Download \(destination.lastPathComponent)",
            detail: "Shortcut download from \(remotePath)",
            localFilePath: destination.path,
            remotePath: remotePath,
            metadata: [
                "action": "downloadFile",
                "fileName": destination.lastPathComponent,
            ],
            integrations: data
        )

        return .result(
            value: operation.id,
            dialog: ShortcutIntentSupport.dialog(for: operation, queuedVerb: "queued", approvalVerb: "needs approval")
        )
    }
}

struct RunMidnightSSHCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Midnight SSH Command"
    static var description = IntentDescription("Queues a command for a saved Midnight SSH server.")

    @Parameter(title: "Server")
    var server: MidnightSSHServerEntity

    @Parameter(title: "Command")
    var command: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let data = try ShortcutIntentSupport.loadIntegrations()
        let record = try ShortcutIntentSupport.serverRecord(for: server, in: data)
        try ShortcutIntentSupport.requireTerminal(record)
        let operation = try ShortcutIntentSupport.queueOperation(
            profileId: record.id,
            kind: .runCommand,
            title: "Run shortcut command",
            detail: command,
            metadata: [
                "action": "runCommand",
                "command": command,
            ],
            integrations: data
        )

        return .result(
            value: operation.id,
            dialog: ShortcutIntentSupport.dialog(for: operation, queuedVerb: "queued", approvalVerb: "needs approval")
        )
    }
}

struct OpenMidnightSSHTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Midnight SSH Terminal"
    static var description = IntentDescription("Opens Midnight SSH and queues a terminal focus request for a saved server.")
    static var openAppWhenRun = true

    @Parameter(title: "Server")
    var server: MidnightSSHServerEntity

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let data = try ShortcutIntentSupport.loadIntegrations()
        let record = try ShortcutIntentSupport.serverRecord(for: server, in: data)
        try ShortcutIntentSupport.requireTerminal(record)
        let operation = try ShortcutIntentSupport.queueOperation(
            profileId: record.id,
            kind: .shortcutRun,
            title: "Open terminal",
            detail: record.displayName,
            metadata: [
                "action": "openTerminal",
                "url": "pgAgent://terminal/\(record.id)",
            ],
            integrations: data,
            forceQueued: true
        )

        return .result(value: operation.id, dialog: "Opening Midnight SSH for \(record.displayName).")
    }
}

struct SyncMidnightSSHOfflineFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Midnight SSH Offline Folder"
    static var description = IntentDescription("Queues a refresh for an offline SFTP folder.")

    @Parameter(title: "Folder")
    var folder: MidnightSSHOfflineFolderEntity

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let data = try ShortcutIntentSupport.loadIntegrations()
        guard data.offlineFolders.contains(where: { $0.id == folder.id }) else {
            throw ShortcutIntentError.notFound("Offline folder")
        }
        let operation = try ShortcutIntentSupport.queueOperation(
            profileId: folder.profileId,
            kind: .offlineFolderSync,
            title: "Sync \(folder.displayName)",
            detail: folder.remotePath,
            remotePath: folder.remotePath,
            itemIdentifier: OfflineSFTPFileProviderIdentifier.offlineRoot(folderId: folder.id).rawValue,
            metadata: ["action": "syncOfflineFolder", "folderId": folder.id],
            integrations: data
        )

        return .result(
            value: operation.id,
            dialog: ShortcutIntentSupport.dialog(for: operation, queuedVerb: "queued", approvalVerb: "needs approval")
        )
    }
}

struct TailMidnightSSHLogsIntent: AppIntent {
    static var title: LocalizedStringResource = "Tail Midnight SSH Logs"
    static var description = IntentDescription("Queues a portable recent-log command for a saved server.")

    @Parameter(title: "Server")
    var server: MidnightSSHServerEntity

    @Parameter(title: "Lines", default: 160)
    var lines: Int

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let data = try ShortcutIntentSupport.loadIntegrations()
        let record = try ShortcutIntentSupport.serverRecord(for: server, in: data)
        try ShortcutIntentSupport.requireTerminal(record)
        let clampedLines = min(1_000, max(20, lines))
        let command = ShortcutIntentSupport.tailLogsCommand(lines: clampedLines)
        let operation = try ShortcutIntentSupport.queueOperation(
            profileId: record.id,
            kind: .runCommand,
            title: "Tail recent logs",
            detail: "\(clampedLines) lines",
            metadata: [
                "action": "tailLogs",
                "command": command,
                "lines": String(clampedLines),
            ],
            integrations: data
        )

        return .result(
            value: operation.id,
            dialog: ShortcutIntentSupport.dialog(for: operation, queuedVerb: "queued", approvalVerb: "needs approval")
        )
    }
}

struct StartMidnightSSHMonitorIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Midnight SSH Monitor"
    static var description = IntentDescription("Queues a monitor refresh for a saved server.")

    @Parameter(title: "Server")
    var server: MidnightSSHServerEntity

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let data = try ShortcutIntentSupport.loadIntegrations()
        let record = try ShortcutIntentSupport.serverRecord(for: server, in: data)
        let operation = try ShortcutIntentSupport.queueOperation(
            profileId: record.id,
            kind: .shortcutRun,
            title: "Start monitor",
            detail: record.displayName,
            metadata: ["action": "startMonitor"],
            integrations: data
        )

        return .result(
            value: operation.id,
            dialog: ShortcutIntentSupport.dialog(for: operation, queuedVerb: "queued", approvalVerb: "needs approval")
        )
    }
}

struct SetMidnightSSHAutomationPolicyIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Midnight SSH Automation Policy"
    static var description = IntentDescription("Sets how Shortcuts may use saved credentials for a server.")
    static var openAppWhenRun = true

    @Parameter(title: "Server")
    var server: MidnightSSHServerEntity

    @Parameter(title: "Policy")
    var policy: MidnightSSHAutomationPolicyOption

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = PlatformIntegrationStore()
        var data = try store.load()
        let record = try ShortcutIntentSupport.serverRecord(for: server, in: data)
        data.automationPolicies.removeAll { $0.profileId == record.id }
        data.automationPolicies.append(
            AutomationCredentialPolicyRecord(
                profileId: record.id,
                approvalPolicy: policy.policy,
                allowedRequesters: [.shortcuts]
            )
        )
        try store.save(data)

        let output = "\(record.displayName): \(policy.rawValue)"
        return .result(value: output, dialog: "Updated automation policy for \(record.displayName).")
    }
}

private enum ShortcutIntentSupport {
    static func loadIntegrations() throws -> PlatformIntegrationStoreData {
        try PlatformIntegrationStore().load()
    }

    static func serverRecord(
        for entity: MidnightSSHServerEntity,
        in data: PlatformIntegrationStoreData
    ) throws -> ShortcutServerRecord {
        guard let record = data.shortcutServer(id: entity.id) else {
            throw ShortcutIntentError.notFound("Server")
        }
        return record
    }

    static func requireTerminal(_ server: ShortcutServerRecord) throws {
        guard server.supportsTerminal else {
            throw ShortcutIntentError.unsupported("\(server.displayName) is configured for SFTP only.")
        }
    }

    static func recordCompletedShortcut(title: String, metadata: [String: String]) throws {
        let now = Date()
        try BackgroundSSHOperationStore().upsert(
            BackgroundSSHOperationRecord(
                profileId: "unassigned",
                kind: .shortcutRun,
                requester: .shortcuts,
                approvalPolicy: .allowBackground,
                status: .completed,
                title: title,
                createdAt: now,
                updatedAt: now,
                completedAt: now,
                metadata: metadata
            )
        )
    }

    static func queueOperation(
        profileId: String,
        kind: BackgroundSSHOperationKind,
        title: String,
        detail: String? = nil,
        localFilePath: String? = nil,
        remotePath: String? = nil,
        itemIdentifier: String? = nil,
        metadata: [String: String],
        integrations: PlatformIntegrationStoreData,
        forceQueued: Bool = false
    ) throws -> BackgroundSSHOperationRecord {
        let policy = integrations.automationPolicy(profileId: profileId)
        let status: BackgroundSSHOperationStatus = forceQueued
            ? .queued
            : integrations.automationStatus(profileId: profileId)
        let operation = BackgroundSSHOperationRecord(
            profileId: profileId,
            kind: kind,
            requester: .shortcuts,
            approvalPolicy: policy,
            status: status,
            title: title,
            detail: detail,
            localFilePath: localFilePath,
            remotePath: remotePath.map(normalizedRemotePath),
            itemIdentifier: itemIdentifier,
            metadata: metadata
        )
        try BackgroundSSHOperationStore().upsert(operation)
        return operation
    }

    static func dialog(
        for operation: BackgroundSSHOperationRecord,
        queuedVerb: String,
        approvalVerb: String
    ) -> IntentDialog {
        switch operation.status {
        case .queued:
            return "Operation \(queuedVerb). ID: \(operation.id)"
        case .waitingForApproval:
            return "Operation \(approvalVerb) in Midnight SSH. ID: \(operation.id)"
        case .running, .completed, .failed, .cancelled:
            return "Operation recorded. ID: \(operation.id)"
        }
    }

    static func stage(_ file: IntentFile) throws -> SharedStagedUpload {
        if let fileURL = file.fileURL {
            return try SharedUploadStagingStore().stageFile(
                from: fileURL,
                suggestedName: file.filename
            )
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(safeFileName(file.filename))")
        try file.data.write(to: temporaryURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        return try SharedUploadStagingStore().stageFile(
            from: temporaryURL,
            suggestedName: file.filename
        )
    }

    static func remoteUploadPath(basePath: String, fileName: String) -> String {
        let normalized = normalizedRemotePath(basePath)
        if normalized.hasSuffix("/") {
            return normalized + safeFileName(fileName)
        }
        let lastComponent = URL(fileURLWithPath: normalized).lastPathComponent
        if lastComponent.contains(".") {
            return normalized
        }
        return normalized == "/" ? "/\(safeFileName(fileName))" : "\(normalized)/\(safeFileName(fileName))"
    }

    static func shortcutDownloadURL(suggestedFilename: String?, remotePath: String) throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedAppStorageConfiguration.appGroupIdentifier
        ) else {
            throw SharedJSONFileStoreError.appGroupContainerUnavailable(
                SharedAppStorageConfiguration.appGroupIdentifier
            )
        }
        let directory = container.appendingPathComponent(
            SharedAppStorageConfiguration.shortcutDownloadsDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidate = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = URL(fileURLWithPath: remotePath).lastPathComponent
        let filename = safeFileName(candidate?.isEmpty == false ? candidate! : fallback)
        return directory.appendingPathComponent(filename.isEmpty ? "download" : filename)
    }

    static func tailLogsCommand(lines: Int) -> String {
        """
        set +e
        if command -v journalctl >/dev/null 2>&1; then
          journalctl -n \(lines) --no-pager -o short-iso 2>&1
        elif [ -r /var/log/syslog ]; then
          tail -n \(lines) /var/log/syslog
        elif [ -r /var/log/system.log ]; then
          tail -n \(lines) /var/log/system.log
        else
          echo "No readable journalctl, /var/log/syslog, or /var/log/system.log source found."
        fi
        """
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        let collapsed = trimmed.replacingOccurrences(of: "//+", with: "/", options: .regularExpression)
        return collapsed.hasPrefix("/") ? collapsed : "/\(collapsed)"
    }

    private static func safeFileName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty ? "file" : cleaned
    }
}

private enum ShortcutIntentError: LocalizedError {
    case notFound(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name):
            return "\(name) was not found in the shared Midnight SSH Shortcuts index."
        case .unsupported(let detail):
            return detail
        }
    }
}
