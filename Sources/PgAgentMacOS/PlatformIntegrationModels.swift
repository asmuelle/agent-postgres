import Foundation

public enum PlatformIntegrationSchema {
    public static let currentVersion = 1
}

public enum AutomationApprovalPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case manual
    case biometricPerRun
    case allowBackground

    public var requiresForegroundApproval: Bool {
        self != .allowBackground
    }
}

public enum AgentApprovalWindow: String, Codable, CaseIterable, Hashable, Sendable {
    case once
    case fiveMinutes
    case sixtyMinutes
    case currentSession

    public var displayName: String {
        switch self {
        case .once: return "Once"
        case .fiveMinutes: return "5 minutes"
        case .sixtyMinutes: return "60 minutes"
        case .currentSession: return "Current session"
        }
    }

    public func expirationDate(now: Date = Date()) -> Date? {
        switch self {
        case .once, .currentSession:
            return nil
        case .fiveMinutes:
            return now.addingTimeInterval(5 * 60)
        case .sixtyMinutes:
            return now.addingTimeInterval(60 * 60)
        }
    }
}

public enum PlatformIntegrationRequester: String, Codable, CaseIterable, Hashable, Sendable {
    case app
    case fileProvider
    case shareExtension
    case shortcuts
    case widget
    case liveActivity
}

public struct SharedSnippetRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var tags: [String]
    public var updatedAt: Date
    public var syncEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        title: String,
        body: String,
        tags: [String] = [],
        updatedAt: Date = Date(),
        syncEnabled: Bool = true
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.body = body
        self.tags = Self.normalizedTags(tags)
        self.updatedAt = updatedAt
        self.syncEnabled = syncEnabled
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

public enum OfflineFolderSyncState: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case syncing
    case current
    case conflict
    case failed
    case paused
}

public struct OfflineSFTPFolderRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var profileId: String
    public var remotePath: String
    public var displayName: String
    public var localCachePath: String?
    public var syncState: OfflineFolderSyncState
    public var lastSyncedAt: Date?
    public var lastError: String?

    public init(
        id: String = UUID().uuidString,
        profileId: String,
        remotePath: String,
        displayName: String? = nil,
        localCachePath: String? = nil,
        syncState: OfflineFolderSyncState = .pending,
        lastSyncedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.remotePath = Self.normalizedRemotePath(remotePath)
        self.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? displayName!.trimmingCharacters(in: .whitespacesAndNewlines)
            : Self.defaultDisplayName(for: remotePath)
        self.localCachePath = localCachePath
        self.syncState = syncState
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private static func defaultDisplayName(for path: String) -> String {
        let normalized = normalizedRemotePath(path)
        if normalized == "/" { return "/" }
        return URL(fileURLWithPath: normalized).lastPathComponent
    }
}

public enum PortForwardKind: String, Codable, CaseIterable, Hashable, Sendable {
    case local
    case remote
    case dynamicSocks

    public var displayName: String {
        switch self {
        case .local:
            return "Local"
        case .remote:
            return "Remote"
        case .dynamicSocks:
            return "SOCKS"
        }
    }

    public var requiresDestination: Bool {
        self != .dynamicSocks
    }
}

public struct PortForwardProfileRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var profileId: String
    public var name: String
    public var kind: PortForwardKind
    public var bindHost: String
    public var bindPort: UInt16
    public var destinationHost: String?
    public var destinationPort: UInt16?
    public var autoStart: Bool

    public init(
        id: String = UUID().uuidString,
        profileId: String,
        name: String,
        kind: PortForwardKind,
        bindHost: String = "127.0.0.1",
        bindPort: UInt16,
        destinationHost: String? = nil,
        destinationPort: UInt16? = nil,
        autoStart: Bool = false
    ) {
        self.id = id
        self.profileId = profileId
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.bindHost = bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bindPort = bindPort
        self.destinationHost = destinationHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.destinationPort = destinationPort
        self.autoStart = autoStart
    }

    public var requiresDestination: Bool {
        kind.requiresDestination
    }

    public var bindEndpoint: String {
        "\(bindHost.isEmpty ? "127.0.0.1" : bindHost):\(bindPort)"
    }

    public var destinationEndpoint: String {
        guard let destinationHost, let destinationPort else {
            return kind == .dynamicSocks ? "SOCKS target" : "No destination"
        }
        return "\(destinationHost):\(destinationPort)"
    }

    public var routeSummary: String {
        switch kind {
        case .local:
            return "\(bindEndpoint) -> \(destinationEndpoint)"
        case .remote:
            return "remote \(bindEndpoint) -> \(destinationEndpoint)"
        case .dynamicSocks:
            return "SOCKS on \(bindEndpoint)"
        }
    }

    public var validationError: String? {
        if profileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose an SSH profile."
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Name is required."
        }
        if bindHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Bind host is required."
        }
        if requiresDestination {
            if destinationHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                return "Destination host is required."
            }
            if destinationPort == nil || destinationPort == 0 {
                return "Destination port is required."
            }
        }
        return nil
    }
}

public enum PortForwardRuntimeState: String, Codable, CaseIterable, Hashable, Sendable {
    case starting
    case running
    case stopped
    case failed
    case unsupported

    public var isActive: Bool {
        self == .starting || self == .running
    }
}

public struct PortForwardRuntimeRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var profileId: String
    public var connectionId: String
    public var name: String
    public var kind: PortForwardKind
    public var state: PortForwardRuntimeState
    public var bindHost: String
    public var requestedBindPort: UInt16
    public var boundPort: UInt16?
    public var destinationHost: String?
    public var destinationPort: UInt16?
    public var startedAt: Date?
    public var updatedAt: Date
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var connectionCount: UInt64
    public var lastError: String?

    public init(
        id: String,
        profileId: String,
        connectionId: String,
        name: String,
        kind: PortForwardKind,
        state: PortForwardRuntimeState,
        bindHost: String,
        requestedBindPort: UInt16,
        boundPort: UInt16? = nil,
        destinationHost: String? = nil,
        destinationPort: UInt16? = nil,
        startedAt: Date? = nil,
        updatedAt: Date = Date(),
        bytesIn: UInt64 = 0,
        bytesOut: UInt64 = 0,
        connectionCount: UInt64 = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.connectionId = connectionId
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.state = state
        self.bindHost = bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestedBindPort = requestedBindPort
        self.boundPort = boundPort
        self.destinationHost = destinationHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.destinationPort = destinationPort
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.connectionCount = connectionCount
        self.lastError = lastError
    }

    public var effectiveBindPort: UInt16 {
        boundPort ?? requestedBindPort
    }

    public var bindEndpoint: String {
        "\(bindHost.isEmpty ? "127.0.0.1" : bindHost):\(effectiveBindPort)"
    }

    public var destinationEndpoint: String {
        guard let destinationHost, let destinationPort else {
            return kind == .dynamicSocks ? "SOCKS target" : "No destination"
        }
        return "\(destinationHost):\(destinationPort)"
    }

    public var summary: String {
        switch state {
        case .starting:
            return "Starting \(bindEndpoint)"
        case .running:
            switch kind {
            case .local:
                return "\(bindEndpoint) -> \(destinationEndpoint)"
            case .remote:
                return "remote \(bindEndpoint) -> \(destinationEndpoint)"
            case .dynamicSocks:
                return "SOCKS on \(bindEndpoint)"
            }
        case .stopped:
            return "Stopped"
        case .failed:
            return "Forward failed"
        case .unsupported:
            return "Forward type unsupported"
        }
    }

    public static func stopped(from profile: PortForwardProfileRecord, connectionId: String = "") -> PortForwardRuntimeRecord {
        PortForwardRuntimeRecord(
            id: profile.id,
            profileId: profile.profileId,
            connectionId: connectionId,
            name: profile.name,
            kind: profile.kind,
            state: .stopped,
            bindHost: profile.bindHost,
            requestedBindPort: profile.bindPort,
            destinationHost: profile.destinationHost,
            destinationPort: profile.destinationPort
        )
    }
}

public struct PortForwardRuntimeStoreData: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var records: [PortForwardRuntimeRecord]

    public static let empty = PortForwardRuntimeStoreData()

    public init(
        schemaVersion: Int = PlatformIntegrationSchema.currentVersion,
        records: [PortForwardRuntimeRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
    }
}

public final class PortForwardRuntimeStore: @unchecked Sendable {
    private let store: SharedJSONFileStore<PortForwardRuntimeStoreData>

    public init(
        fileName: String = SharedAppStorageConfiguration.portForwardRuntimeFileName,
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.store = SharedJSONFileStore(
            fileName: fileName,
            fileManager: fileManager,
            directoryURL: directoryURL
        )
    }

    public func load() throws -> PortForwardRuntimeStoreData {
        try store.load(default: .empty)
    }

    public func save(_ data: PortForwardRuntimeStoreData) throws {
        try store.save(data)
    }

    public func upsert(_ record: PortForwardRuntimeRecord) throws {
        var data = try load()
        if let index = data.records.firstIndex(where: { $0.id == record.id }) {
            data.records[index] = record
        } else {
            data.records.append(record)
        }
        data.records.sort { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
        try save(data)
    }

    public func remove(id: String) throws {
        var data = try load()
        data.records.removeAll { $0.id == id }
        try save(data)
    }

    public func replace(records matchingProfileId: String, with records: [PortForwardRuntimeRecord]) throws {
        var data = try load()
        data.records.removeAll { $0.profileId == matchingProfileId }
        data.records.append(contentsOf: records)
        data.records.sort { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
        try save(data)
    }
}

public enum CloudServerProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case digitalOcean
    case hetzner
}

public struct CloudServerAccountRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var provider: CloudServerProvider
    public var displayName: String
    public var keychainAccount: String
    public var lastRefreshedAt: Date?

    public init(
        id: String = UUID().uuidString,
        provider: CloudServerProvider,
        displayName: String,
        keychainAccount: String,
        lastRefreshedAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keychainAccount = keychainAccount
        self.lastRefreshedAt = lastRefreshedAt
    }
}

public enum AdvancedAuthIdentityKind: String, Codable, CaseIterable, Hashable, Sendable {
    case secureEnclaveKey
    case securityKey
    case sshCertificate
    case certificateAuthority

    public var displayName: String {
        switch self {
        case .secureEnclaveKey: return "Secure Enclave"
        case .securityKey: return "Security key"
        case .sshCertificate: return "SSH certificate"
        case .certificateAuthority: return "Certificate authority"
        }
    }

    public var canAuthenticateThroughAgent: Bool {
        switch self {
        case .securityKey, .sshCertificate:
            return true
        case .secureEnclaveKey, .certificateAuthority:
            return false
        }
    }
}

public struct AdvancedAuthIdentityRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: AdvancedAuthIdentityKind
    public var displayName: String
    public var publicKey: String?
    public var publicKeyFingerprint: String?
    public var keychainAccount: String?
    public var certificate: String?
    public var principal: String?
    public var issuer: String?
    public var expiresAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var requiresBiometricApproval: Bool
    public var agentApprovalWindow: AgentApprovalWindow

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case displayName
        case publicKey
        case publicKeyFingerprint
        case keychainAccount
        case certificate
        case principal
        case issuer
        case expiresAt
        case createdAt
        case updatedAt
        case requiresBiometricApproval
        case agentApprovalWindow
    }

    public init(
        id: String = UUID().uuidString,
        kind: AdvancedAuthIdentityKind,
        displayName: String,
        publicKey: String? = nil,
        publicKeyFingerprint: String? = nil,
        keychainAccount: String? = nil,
        certificate: String? = nil,
        principal: String? = nil,
        issuer: String? = nil,
        expiresAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        requiresBiometricApproval: Bool = false,
        agentApprovalWindow: AgentApprovalWindow = .once
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.publicKey = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.publicKeyFingerprint = publicKeyFingerprint
        self.keychainAccount = keychainAccount?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.certificate = certificate?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.principal = principal?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.issuer = issuer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.requiresBiometricApproval = requiresBiometricApproval
        self.agentApprovalWindow = agentApprovalWindow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(AdvancedAuthIdentityKind.self, forKey: .kind)
        displayName = try container.decode(String.self, forKey: .displayName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        publicKeyFingerprint = try container.decodeIfPresent(String.self, forKey: .publicKeyFingerprint)
        keychainAccount = try container.decodeIfPresent(String.self, forKey: .keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        certificate = try container.decodeIfPresent(String.self, forKey: .certificate)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        principal = try container.decodeIfPresent(String.self, forKey: .principal)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        issuer = try container.decodeIfPresent(String.self, forKey: .issuer)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        requiresBiometricApproval = try container.decodeIfPresent(Bool.self, forKey: .requiresBiometricApproval) ?? false
        agentApprovalWindow = try container.decodeIfPresent(AgentApprovalWindow.self, forKey: .agentApprovalWindow) ?? .once
    }

    public var identityHint: String? {
        guard let publicKey else { return publicKeyFingerprint }
        let fields = publicKey.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { return publicKeyFingerprint }
        return String(fields[1])
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    public var statusSummary: String {
        if let expiresAt {
            return isExpired() ? "Expired" : "Expires \(Self.summaryDateFormatter.string(from: expiresAt))"
        }
        if requiresBiometricApproval {
            return "Biometric approval"
        }
        return kind.displayName
    }

    private static let summaryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

public struct AutomationCredentialPolicyRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String { profileId }
    public var profileId: String
    public var approvalPolicy: AutomationApprovalPolicy
    public var allowedRequesters: Set<PlatformIntegrationRequester>
    public var updatedAt: Date

    public init(
        profileId: String,
        approvalPolicy: AutomationApprovalPolicy = .manual,
        allowedRequesters: Set<PlatformIntegrationRequester> = [],
        updatedAt: Date = Date()
    ) {
        self.profileId = profileId
        self.approvalPolicy = approvalPolicy
        self.allowedRequesters = allowedRequesters
        self.updatedAt = updatedAt
    }
}

public struct ShortcutServerRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var kind: String
    public var supportsTerminal: Bool
    public var folder: String?
    public var tags: [String]
    public var lastConnected: Date?
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        host: String,
        port: UInt16,
        username: String,
        kind: String,
        supportsTerminal: Bool,
        folder: String? = nil,
        tags: [String] = [],
        lastConnected: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        self.supportsTerminal = supportsTerminal
        self.folder = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tags = Self.normalizedTags(tags)
        self.lastConnected = lastConnected
        self.updatedAt = updatedAt
    }

    public var displayName: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }

    public var endpoint: String {
        "\(username)@\(host):\(port)"
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

public struct ShareUploadDestinationRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var profileId: String
    public var remotePath: String
    public var contentType: String?
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        profileId: String,
        remotePath: String,
        contentType: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.profileId = profileId
        self.remotePath = Self.normalizedRemotePath(remotePath)
        self.contentType = contentType
        self.updatedAt = updatedAt
    }

    public static func normalizedRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }
}

public struct PlatformIntegrationStoreData: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var snippets: [SharedSnippetRecord]
    public var offlineFolders: [OfflineSFTPFolderRecord]
    public var portForwards: [PortForwardProfileRecord]
    public var cloudAccounts: [CloudServerAccountRecord]
    public var authIdentities: [AdvancedAuthIdentityRecord]
    public var automationPolicies: [AutomationCredentialPolicyRecord]
    public var shortcutServers: [ShortcutServerRecord]
    public var shareDestinations: [ShareUploadDestinationRecord]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case snippets
        case offlineFolders
        case portForwards
        case cloudAccounts
        case authIdentities
        case automationPolicies
        case shortcutServers
        case shareDestinations
    }

    public static let empty = PlatformIntegrationStoreData()

    public init(
        schemaVersion: Int = PlatformIntegrationSchema.currentVersion,
        snippets: [SharedSnippetRecord] = [],
        offlineFolders: [OfflineSFTPFolderRecord] = [],
        portForwards: [PortForwardProfileRecord] = [],
        cloudAccounts: [CloudServerAccountRecord] = [],
        authIdentities: [AdvancedAuthIdentityRecord] = [],
        automationPolicies: [AutomationCredentialPolicyRecord] = [],
        shortcutServers: [ShortcutServerRecord] = [],
        shareDestinations: [ShareUploadDestinationRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.snippets = snippets
        self.offlineFolders = offlineFolders
        self.portForwards = portForwards
        self.cloudAccounts = cloudAccounts
        self.authIdentities = authIdentities
        self.automationPolicies = automationPolicies
        self.shortcutServers = shortcutServers
        self.shareDestinations = shareDestinations
    }

    public func shortcutServer(id: String) -> ShortcutServerRecord? {
        shortcutServers.first { $0.id == id }
    }

    public func authIdentity(id: String) -> AdvancedAuthIdentityRecord? {
        authIdentities.first { $0.id == id }
    }

    public func shortcutServers(matching query: String) -> [ShortcutServerRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = shortcutServers.sorted {
            if $0.lastConnected != $1.lastConnected {
                return ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast)
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { server in
            [
                server.displayName,
                server.host,
                server.username,
                server.endpoint,
                server.folder ?? "",
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(needle)
                || server.tags.contains { $0.lowercased().contains(needle) }
        }
    }

    public func automationPolicy(
        profileId: String,
        requester: PlatformIntegrationRequester = .shortcuts
    ) -> AutomationApprovalPolicy {
        guard let policy = automationPolicies.first(where: { $0.profileId == profileId }),
              policy.allowedRequesters.contains(requester) else {
            return .manual
        }
        return policy.approvalPolicy
    }

    public func automationStatus(
        profileId: String,
        requester: PlatformIntegrationRequester = .shortcuts
    ) -> BackgroundSSHOperationStatus {
        automationPolicy(profileId: profileId, requester: requester).requiresForegroundApproval
            ? .waitingForApproval
            : .queued
    }

    public func preferredShareDestination(contentType: String? = nil) -> ShareUploadDestinationRecord? {
        let sorted = shareDestinations.sorted { $0.updatedAt > $1.updatedAt }
        if let contentType,
           let typed = sorted.first(where: { $0.contentType == contentType }) {
            return typed
        }
        return sorted.first
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? PlatformIntegrationSchema.currentVersion
        snippets = try container.decodeIfPresent([SharedSnippetRecord].self, forKey: .snippets) ?? []
        offlineFolders = try container.decodeIfPresent([OfflineSFTPFolderRecord].self, forKey: .offlineFolders) ?? []
        portForwards = try container.decodeIfPresent([PortForwardProfileRecord].self, forKey: .portForwards) ?? []
        cloudAccounts = try container.decodeIfPresent([CloudServerAccountRecord].self, forKey: .cloudAccounts) ?? []
        authIdentities = try container.decodeIfPresent([AdvancedAuthIdentityRecord].self, forKey: .authIdentities) ?? []
        automationPolicies = try container.decodeIfPresent([AutomationCredentialPolicyRecord].self, forKey: .automationPolicies) ?? []
        shortcutServers = try container.decodeIfPresent([ShortcutServerRecord].self, forKey: .shortcutServers) ?? []
        shareDestinations = try container.decodeIfPresent([ShareUploadDestinationRecord].self, forKey: .shareDestinations) ?? []
    }
}

public final class PlatformIntegrationStore: @unchecked Sendable {
    private let store: SharedJSONFileStore<PlatformIntegrationStoreData>

    public init(
        fileName: String = SharedAppStorageConfiguration.integrationsFileName,
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.store = SharedJSONFileStore(
            fileName: fileName,
            fileManager: fileManager,
            directoryURL: directoryURL
        )
    }

    public func load() throws -> PlatformIntegrationStoreData {
        try store.load(default: .empty)
    }

    public func save(_ data: PlatformIntegrationStoreData) throws {
        try store.save(data)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
