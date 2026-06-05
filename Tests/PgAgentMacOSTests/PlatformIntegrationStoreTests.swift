import XCTest
@testable import PgAgentMacOS

final class PlatformIntegrationModelTests: XCTestCase {
    func testSnippetNormalizesTagsAndTitle() {
        let snippet = SharedSnippetRecord(
            title: "  Deploy  ",
            body: "systemctl restart app",
            tags: [" prod ", "Prod", "", "ops"]
        )

        XCTAssertEqual(snippet.title, "Deploy")
        XCTAssertEqual(snippet.tags, ["prod", "ops"])
    }

    func testOfflineFolderNormalizesRemotePathAndName() {
        let folder = OfflineSFTPFolderRecord(
            profileId: "profile-1",
            remotePath: "var/log"
        )

        XCTAssertEqual(folder.remotePath, "/var/log")
        XCTAssertEqual(folder.displayName, "log")
        XCTAssertEqual(folder.syncState, .pending)
    }

    func testBackgroundOperationProgressFraction() {
        let progress = BackgroundSSHOperationProgress(
            completedUnitCount: 25,
            totalUnitCount: 100
        )

        XCTAssertEqual(progress.fractionCompleted ?? -1, 0.25, accuracy: 0.001)
    }

    func testBackgroundOperationMarksTerminalStatus() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let completedAt = createdAt.addingTimeInterval(10)
        let operation = BackgroundSSHOperationRecord(
            profileId: "profile-1",
            kind: .sftpUpload,
            requester: .shareExtension,
            title: "Upload report",
            createdAt: createdAt,
            updatedAt: createdAt
        )

        let completed = operation.updating(status: .completed, now: completedAt)

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.completedAt, completedAt)
        XCTAssertEqual(completed.updatedAt, completedAt)
    }

    func testShortcutServerSearchAndPolicy() {
        let data = PlatformIntegrationStoreData(
            automationPolicies: [
                AutomationCredentialPolicyRecord(
                    profileId: "prod",
                    approvalPolicy: .allowBackground,
                    allowedRequesters: [.shortcuts]
                ),
            ],
            shortcutServers: [
                ShortcutServerRecord(
                    id: "prod",
                    name: "Production API",
                    host: "api.example.com",
                    port: 22,
                    username: "deploy",
                    kind: "ssh",
                    supportsTerminal: true,
                    tags: ["prod", "api"]
                ),
                ShortcutServerRecord(
                    id: "files",
                    name: "Files",
                    host: "files.example.com",
                    port: 2222,
                    username: "sftp",
                    kind: "sftp",
                    supportsTerminal: false
                ),
            ]
        )

        XCTAssertEqual(data.shortcutServers(matching: "api").map(\.id), ["prod"])
        XCTAssertEqual(data.automationPolicy(profileId: "prod"), .allowBackground)
        XCTAssertEqual(data.automationStatus(profileId: "prod"), .queued)
        XCTAssertEqual(data.automationStatus(profileId: "files"), .waitingForApproval)
    }

    func testAdvancedAuthIdentityNormalizesAndExposesAgentHint() {
        let identity = AdvancedAuthIdentityRecord(
            kind: .sshCertificate,
            displayName: "  Prod Cert  ",
            publicKey: "ssh-ed25519-cert-v01@openssh.com AAAAB3Nz prod",
            publicKeyFingerprint: "SHA256:abc",
            agentApprovalWindow: .fiveMinutes
        )

        XCTAssertEqual(identity.displayName, "Prod Cert")
        XCTAssertEqual(identity.identityHint, "AAAAB3Nz")
        XCTAssertEqual(identity.agentApprovalWindow.expirationDate(now: Date(timeIntervalSince1970: 0)), Date(timeIntervalSince1970: 300))
        XCTAssertTrue(identity.kind.canAuthenticateThroughAgent)
    }

    func testAdvancedAuthIdentityDecodesLegacyRecordWithDefaults() throws {
        let json = #"{"id":"enclave","kind":"secureEnclaveKey","displayName":"Touch ID"}"#
        let identity = try JSONDecoder().decode(AdvancedAuthIdentityRecord.self, from: Data(json.utf8))

        XCTAssertEqual(identity.id, "enclave")
        XCTAssertEqual(identity.displayName, "Touch ID")
        XCTAssertEqual(identity.agentApprovalWindow, .once)
        XCTAssertFalse(identity.requiresBiometricApproval)
        XCTAssertFalse(identity.isExpired())
    }

    func testFileProviderIdentifierRoundTripsRemotePath() {
        let identifier = OfflineSFTPFileProviderIdentifier.item(
            folderId: "folder-1",
            remotePath: "/var/log/nginx/access.log"
        )

        XCTAssertEqual(
            OfflineSFTPFileProviderIdentifier(rawValue: identifier.rawValue),
            identifier
        )
    }

    func testFileProviderCatalogBuildsRootAndCachedChildren() {
        let folder = OfflineSFTPFolderRecord(
            id: "logs",
            profileId: "profile-1",
            remotePath: "/var/log",
            displayName: "Logs"
        )
        let manifest = OfflineSFTPCacheManifest(
            items: [
                OfflineSFTPCacheItemRecord(
                    folderId: "logs",
                    remotePath: "/var/log/nginx",
                    fileType: .directory
                ),
                OfflineSFTPCacheItemRecord(
                    folderId: "logs",
                    remotePath: "/var/log/syslog",
                    fileType: .file,
                    size: 128
                ),
            ]
        )
        let catalog = FileProviderCatalog(
            integrations: PlatformIntegrationStoreData(offlineFolders: [folder]),
            manifest: manifest
        )

        let rootChildren = catalog.children(rawIdentifier: OfflineSFTPFileProviderIdentifier.root.rawValue)
        XCTAssertEqual(rootChildren.map(\.filename), ["Logs"])

        let folderChildren = catalog.children(rawIdentifier: OfflineSFTPFileProviderIdentifier.offlineRoot(folderId: "logs").rawValue)
        XCTAssertEqual(folderChildren.map(\.filename), ["nginx", "syslog"])
        XCTAssertEqual(folderChildren.first?.fileType, .directory)
        XCTAssertEqual(
            folderChildren.first?.parentId,
            OfflineSFTPFileProviderIdentifier.offlineRoot(folderId: "logs").rawValue
        )
    }
}

final class PlatformIntegrationStoreTests: XCTestCase {
    func testPlatformIntegrationStoreRoundTripsFromExplicitDirectory() throws {
        let directory = temporaryDirectory("platform-integration-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let data = PlatformIntegrationStoreData(
            snippets: [
                SharedSnippetRecord(
                    id: "deploy",
                    title: "Deploy",
                    body: "deploy.sh",
                    tags: ["prod"],
                    updatedAt: now
                ),
            ],
            offlineFolders: [
                OfflineSFTPFolderRecord(
                    id: "logs",
                    profileId: "profile-1",
                    remotePath: "/var/log"
                ),
            ],
            portForwards: [
                PortForwardProfileRecord(
                    id: "pg",
                    profileId: "profile-1",
                    name: "Postgres",
                    kind: .local,
                    bindPort: 15432,
                    destinationHost: "127.0.0.1",
                    destinationPort: 5432
                ),
            ],
            cloudAccounts: [
                CloudServerAccountRecord(
                    id: "do",
                    provider: .digitalOcean,
                    displayName: "DigitalOcean",
                    keychainAccount: "cloud:do"
                ),
            ],
            authIdentities: [
                AdvancedAuthIdentityRecord(
                    id: "enclave",
                    kind: .secureEnclaveKey,
                    displayName: "Secure Enclave",
                    createdAt: now,
                    updatedAt: now
                ),
            ],
            automationPolicies: [
                AutomationCredentialPolicyRecord(
                    profileId: "profile-1",
                    approvalPolicy: .biometricPerRun,
                    allowedRequesters: [.shortcuts],
                    updatedAt: now
                ),
            ],
            shortcutServers: [
                ShortcutServerRecord(
                    id: "profile-1",
                    name: "Production",
                    host: "example.com",
                    port: 22,
                    username: "deploy",
                    kind: "ssh",
                    supportsTerminal: true,
                    updatedAt: now
                ),
            ],
            shareDestinations: [
                ShareUploadDestinationRecord(
                    id: "share",
                    profileId: "profile-1",
                    remotePath: "/uploads",
                    contentType: "public.item",
                    updatedAt: now
                ),
            ]
        )

        let store = PlatformIntegrationStore(directoryURL: directory)
        try store.save(data)

        let loaded = try store.load()
        XCTAssertEqual(loaded.schemaVersion, PlatformIntegrationSchema.currentVersion)
        XCTAssertEqual(loaded, data)
    }

    func testBackgroundOperationStoreUpsertsAndUpdates() throws {
        let directory = temporaryDirectory("background-operation-store")
        defer { try? FileManager.default.removeItem(at: directory) }

        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = createdAt.addingTimeInterval(30)
        let operation = BackgroundSSHOperationRecord(
            id: "op-1",
            profileId: "profile-1",
            kind: .shortcutRun,
            requester: .shortcuts,
            approvalPolicy: .allowBackground,
            title: "Run uptime",
            createdAt: createdAt,
            updatedAt: createdAt
        )

        let store = BackgroundSSHOperationStore(directoryURL: directory)
        try store.upsert(operation)
        try store.update(
            id: operation.id,
            status: .running,
            progress: BackgroundSSHOperationProgress(completedUnitCount: 1, totalUnitCount: 2),
            now: updatedAt
        )

        let loaded = try store.load()
        XCTAssertEqual(loaded.operations.count, 1)
        XCTAssertEqual(loaded.operations[0].status, .running)
        XCTAssertEqual(loaded.operations[0].startedAt, updatedAt)
        XCTAssertEqual(loaded.operations[0].progress.fractionCompleted ?? -1, 0.5, accuracy: 0.001)
    }

    func testSharedJSONStoreReturnsDefaultWhenMissing() throws {
        let directory = temporaryDirectory("shared-json-store-default")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SharedJSONFileStore<PlatformIntegrationStoreData>(
            fileName: "missing.json",
            directoryURL: directory
        )

        XCTAssertEqual(try store.load(default: .empty), .empty)
    }

    func testPlatformIntegrationStoreDecodesMissingNewCollections() throws {
        let json = #"{"schemaVersion":1,"offlineFolders":[]}"#
        let decoded = try JSONDecoder().decode(PlatformIntegrationStoreData.self, from: Data(json.utf8))

        XCTAssertTrue(decoded.snippets.isEmpty)
        XCTAssertTrue(decoded.shareDestinations.isEmpty)
        XCTAssertTrue(decoded.automationPolicies.isEmpty)
        XCTAssertTrue(decoded.shortcutServers.isEmpty)
    }

    func testOfflineCacheManifestStoreRoundTrips() throws {
        let directory = temporaryDirectory("offline-cache-manifest")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = OfflineSFTPCacheManifest(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            items: [
                OfflineSFTPCacheItemRecord(
                    folderId: "logs",
                    remotePath: "/var/log/syslog",
                    fileType: .file,
                    size: 42
                ),
            ]
        )

        let store = OfflineSFTPCacheManifestStore(directoryURL: directory)
        try store.save(manifest)

        XCTAssertEqual(try store.load(), manifest)
    }

    func testSharedUploadStagingCopiesFile() throws {
        let directory = temporaryDirectory("staged-uploads")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source)

        let staged = try SharedUploadStagingStore(directoryURL: directory)
            .stageFile(from: source, suggestedName: "../report.txt", now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(staged.fileName, ".._report.txt")
        XCTAssertEqual(staged.size, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.localPath))
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pgAgent-\(name)")
            .appendingPathComponent(UUID().uuidString)
    }
}
