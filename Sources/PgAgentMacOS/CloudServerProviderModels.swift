import Foundation

public enum CloudServerInventoryConfiguration {
    public static let fileName = SharedAppStorageConfiguration.cloudServerInventoryFileName
    public static let schemaVersion = 1
}

public enum CloudServerPowerState: String, Codable, CaseIterable, Hashable, Sendable {
    case running
    case stopped
    case provisioning
    case rebooting
    case deleting
    case error
    case unknown
}

public struct CloudServerIPAddress: Codable, Hashable, Sendable {
    public var address: String
    public var family: String
    public var isPublic: Bool

    public init(address: String, family: String, isPublic: Bool) {
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.family = family.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isPublic = isPublic
    }
}

public struct CloudServerRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var provider: CloudServerProvider
    public var accountId: String
    public var providerServerId: String
    public var name: String
    public var status: CloudServerPowerState
    public var regionSlug: String?
    public var regionName: String?
    public var sizeSlug: String?
    public var imageSlug: String?
    public var imageName: String?
    public var publicIPv4: String?
    public var publicIPv6: String?
    public var privateIPv4: String?
    public var tags: [String]
    public var metadata: [String: String]
    public var createdAt: Date?
    public var refreshedAt: Date

    public init(
        id: String? = nil,
        provider: CloudServerProvider,
        accountId: String,
        providerServerId: String,
        name: String,
        status: CloudServerPowerState,
        regionSlug: String? = nil,
        regionName: String? = nil,
        sizeSlug: String? = nil,
        imageSlug: String? = nil,
        imageName: String? = nil,
        publicIPv4: String? = nil,
        publicIPv6: String? = nil,
        privateIPv4: String? = nil,
        tags: [String] = [],
        metadata: [String: String] = [:],
        createdAt: Date? = nil,
        refreshedAt: Date = Date()
    ) {
        self.provider = provider
        self.accountId = accountId
        self.providerServerId = providerServerId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id ?? "\(provider.rawValue):\(accountId):\(self.providerServerId)"
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).cloudFallback(self.providerServerId)
        self.status = status
        self.regionSlug = regionSlug?.trimmingCharacters(in: .whitespacesAndNewlines).cloudNilIfEmpty
        self.regionName = regionName?.trimmingCharacters(in: .whitespacesAndNewlines).cloudNilIfEmpty
        self.sizeSlug = sizeSlug?.trimmingCharacters(in: .whitespacesAndNewlines).cloudNilIfEmpty
        self.imageSlug = imageSlug?.trimmingCharacters(in: .whitespacesAndNewlines).cloudNilIfEmpty
        self.imageName = imageName?.trimmingCharacters(in: .whitespacesAndNewlines).cloudNilIfEmpty
        self.publicIPv4 = publicIPv4?.trimmingCharacters(in: .whitespacesAndNewlines).cloudNilIfEmpty
        self.publicIPv6 = publicIPv6?.trimmingCharacters(in: .whitespacesAndNewlines).cloudNilIfEmpty
        self.privateIPv4 = privateIPv4?.trimmingCharacters(in: .whitespacesAndNewlines).cloudNilIfEmpty
        self.tags = Self.normalizedTags(tags)
        self.metadata = metadata.filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.createdAt = createdAt
        self.refreshedAt = refreshedAt
    }

    public var connectHost: String? {
        publicIPv4 ?? publicIPv6
    }

    public var locationLabel: String {
        regionName ?? regionSlug ?? "Unknown region"
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { return nil }
            return tag
        }
    }
}

public struct CloudServerInventorySnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var accountId: String
    public var provider: CloudServerProvider
    public var servers: [CloudServerRecord]

    public init(
        schemaVersion: Int = CloudServerInventoryConfiguration.schemaVersion,
        generatedAt: Date = Date(),
        accountId: String,
        provider: CloudServerProvider,
        servers: [CloudServerRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.accountId = accountId
        self.provider = provider
        self.servers = servers
    }
}

public struct CloudServerInventoryStoreData: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var snapshots: [CloudServerInventorySnapshot]

    public static let empty = CloudServerInventoryStoreData()

    public init(
        schemaVersion: Int = CloudServerInventoryConfiguration.schemaVersion,
        snapshots: [CloudServerInventorySnapshot] = []
    ) {
        self.schemaVersion = schemaVersion
        self.snapshots = snapshots
    }

    public func snapshot(accountId: String) -> CloudServerInventorySnapshot? {
        snapshots.first { $0.accountId == accountId }
    }
}

public final class CloudServerInventoryStore: @unchecked Sendable {
    private let store: SharedJSONFileStore<CloudServerInventoryStoreData>

    public init(
        fileName: String = CloudServerInventoryConfiguration.fileName,
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.store = SharedJSONFileStore(
            fileName: fileName,
            fileManager: fileManager,
            directoryURL: directoryURL
        )
    }

    public func load() throws -> CloudServerInventoryStoreData {
        try store.load(default: .empty)
    }

    public func save(_ data: CloudServerInventoryStoreData) throws {
        try store.save(data)
    }

    public func upsert(_ snapshot: CloudServerInventorySnapshot) throws {
        var data = try load()
        if let index = data.snapshots.firstIndex(where: { $0.accountId == snapshot.accountId }) {
            data.snapshots[index] = snapshot
        } else {
            data.snapshots.append(snapshot)
        }
        data.snapshots.sort { $0.generatedAt > $1.generatedAt }
        try save(data)
    }

    public func remove(accountId: String) throws {
        var data = try load()
        data.snapshots.removeAll { $0.accountId == accountId }
        try save(data)
    }
}

public struct CloudServerCreateRequest: Codable, Equatable, Sendable {
    public var name: String
    public var regionSlug: String
    public var sizeSlug: String
    public var imageSlug: String
    public var sshKeyIds: [String]
    public var tags: [String]
    public var userData: String?
    public var enableIPv6: Bool
    public var enableBackups: Bool

    public init(
        name: String,
        regionSlug: String,
        sizeSlug: String,
        imageSlug: String,
        sshKeyIds: [String] = [],
        tags: [String] = [],
        userData: String? = nil,
        enableIPv6: Bool = true,
        enableBackups: Bool = false
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.regionSlug = regionSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sizeSlug = sizeSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        self.imageSlug = imageSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sshKeyIds = sshKeyIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.userData = userData?.trimmingCharacters(in: .whitespacesAndNewlines).cloudNilIfEmpty
        self.enableIPv6 = enableIPv6
        self.enableBackups = enableBackups
    }

    public var validationError: String? {
        if name.isEmpty { return "Server name is required." }
        if regionSlug.isEmpty { return "Region is required." }
        if sizeSlug.isEmpty { return "Size is required." }
        if imageSlug.isEmpty { return "Image is required." }
        return nil
    }
}

public enum CloudServerLifecycleAction: String, Codable, CaseIterable, Hashable, Sendable {
    case create
    case delete
    case reboot
}

public struct CloudServerActionResult: Codable, Equatable, Sendable {
    public var provider: CloudServerProvider
    public var action: CloudServerLifecycleAction
    public var serverId: String?
    public var providerActionId: String?
    public var status: String
    public var message: String?

    public init(
        provider: CloudServerProvider,
        action: CloudServerLifecycleAction,
        serverId: String? = nil,
        providerActionId: String? = nil,
        status: String,
        message: String? = nil
    ) {
        self.provider = provider
        self.action = action
        self.serverId = serverId
        self.providerActionId = providerActionId
        self.status = status
        self.message = message
    }
}

public enum CloudServerAPIError: LocalizedError, Equatable {
    case invalidAccount(String)
    case invalidCreateRequest(String)
    case invalidResponse
    case httpStatus(Int, String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAccount(let message):
            return message
        case .invalidCreateRequest(let message):
            return message
        case .invalidResponse:
            return "The cloud provider returned an invalid response."
        case .httpStatus(let statusCode, let body):
            return "Cloud provider request failed with HTTP \(statusCode): \(body)"
        case .decoding(let message):
            return "Cloud provider response could not be decoded: \(message)"
        }
    }
}

public struct CloudServerProfileGenerationOptions: Equatable, Sendable {
    public var username: String
    public var authMethod: AuthMethod
    public var kind: ConnectionKind
    public var folderPath: String?
    public var favorite: Bool
    public var sshKeyReference: SSHKeyReference?

    public init(
        username: String = "root",
        authMethod: AuthMethod = .publicKey,
        kind: ConnectionKind = .ssh,
        folderPath: String? = nil,
        favorite: Bool = false,
        sshKeyReference: SSHKeyReference? = .agent(identityHint: nil)
    ) {
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines).cloudFallback("root")
        self.authMethod = authMethod
        self.kind = kind
        self.folderPath = folderPath?.trimmingCharacters(in: .whitespacesAndNewlines).cloudNilIfEmpty
        self.favorite = favorite
        self.sshKeyReference = sshKeyReference
    }
}

public struct CloudServerProfileImportReport: Codable, Equatable, Sendable {
    public var insertedProfiles: Int
    public var updatedProfiles: Int
    public var skippedServers: Int

    public init(insertedProfiles: Int = 0, updatedProfiles: Int = 0, skippedServers: Int = 0) {
        self.insertedProfiles = insertedProfiles
        self.updatedProfiles = updatedProfiles
        self.skippedServers = skippedServers
    }

    public var summary: String {
        "\(insertedProfiles) inserted, \(updatedProfiles) updated, \(skippedServers) skipped"
    }
}

public enum CloudServerProfileGenerator {
    public static func profile(
        from server: CloudServerRecord,
        account: CloudServerAccountRecord,
        options: CloudServerProfileGenerationOptions = CloudServerProfileGenerationOptions(),
        preserving existing: ConnectionProfile? = nil
    ) -> ConnectionProfile? {
        guard let host = server.connectHost else { return nil }
        let folder = options.folderPath ?? "Cloud/\(account.displayName.cloudFallback(account.provider.displayName))"
        return ConnectionProfile(
            id: "cloud-\(server.provider.rawValue)-\(server.accountId)-\(server.providerServerId)",
            name: server.name,
            host: host,
            port: 22,
            username: existing?.username ?? options.username,
            authMethod: existing?.authMethod ?? options.authMethod,
            kind: existing?.kind ?? options.kind,
            folderPath: existing?.folderPath ?? folder,
            sshKeyReference: existing?.sshKeyReference ?? options.sshKeyReference,
            createdAt: existing?.createdAt ?? Date(),
            lastConnected: existing?.lastConnected,
            favorite: existing?.favorite ?? options.favorite,
            tags: normalizedProfileTags(server: server, existing: existing),
            color: existing?.color,
            notes: profileNotes(server: server, account: account),
            networkOptions: existing?.networkOptions ?? .default,
            monitoredSystemdServices: existing?.monitoredSystemdServices ?? []
        )
    }

    private static func normalizedProfileTags(server: CloudServerRecord, existing: ConnectionProfile?) -> [String] {
        var tags = existing?.tags ?? []
        tags.append("cloud")
        tags.append(server.provider.displayName)
        if let region = server.regionSlug {
            tags.append(region)
        }
        tags.append(contentsOf: server.tags)

        var seen = Set<String>()
        return tags.compactMap { raw in
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { return nil }
            return tag
        }
    }

    private static func profileNotes(server: CloudServerRecord, account: CloudServerAccountRecord) -> String {
        [
            "Imported from \(account.provider.displayName).",
            "Cloud account: \(account.displayName).",
            "Provider server ID: \(server.providerServerId).",
        ].joined(separator: "\n")
    }
}

public extension CloudServerProvider {
    var displayName: String {
        switch self {
        case .digitalOcean:
            return "DigitalOcean"
        case .hetzner:
            return "Hetzner"
        }
    }

    var defaultRegionSlug: String {
        switch self {
        case .digitalOcean:
            return "nyc3"
        case .hetzner:
            return "fsn1"
        }
    }

    var defaultSizeSlug: String {
        switch self {
        case .digitalOcean:
            return "s-1vcpu-1gb"
        case .hetzner:
            return "cx22"
        }
    }

    var defaultImageSlug: String {
        switch self {
        case .digitalOcean:
            return "ubuntu-24-04-x64"
        case .hetzner:
            return "ubuntu-24.04"
        }
    }
}

private extension String {
    var cloudNilIfEmpty: String? {
        isEmpty ? nil : self
    }

    func cloudFallback(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
