import Foundation

// MARK: - Auth method

public enum AuthMethod: String, Codable, Sendable, CaseIterable {
    case password
    case publicKey

    public var displayName: String {
        switch self {
        case .password: return "Password"
        case .publicKey: return "Public Key"
        }
    }
}

// MARK: - SSH key reference

public enum SSHKeyReference: Codable, Hashable, Sendable {
    case plainPath(String)
    case securityScopedBookmark(Data)
    case importedVaultKey(id: String)
    case generatedVaultKey(id: String)
    case agent(identityHint: String?)
    case advancedAuthIdentity(id: String)

    public var displayName: String {
        switch self {
        case .plainPath(let path):
            return path
        case .securityScopedBookmark:
            return "External key"
        case .importedVaultKey(let id):
            return "Imported key \(String(id.prefix(8)))"
        case .generatedVaultKey(let id):
            return "Generated key \(String(id.prefix(8)))"
        case .agent(let identityHint):
            guard let identityHint, !identityHint.isEmpty else { return "SSH agent" }
            return "SSH agent (\(identityHint))"
        case .advancedAuthIdentity(let id):
            return "Advanced identity \(String(id.prefix(8)))"
        }
    }

    public var legacyPath: String? {
        switch self {
        case .plainPath(let path):
            return path
        default:
            return nil
        }
    }

    public var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }

    public var needsStoredPassphrase: Bool {
        switch self {
        case .plainPath, .securityScopedBookmark, .importedVaultKey, .generatedVaultKey:
            return true
        case .agent, .advancedAuthIdentity:
            return false
        }
    }

    public var advancedAuthIdentityId: String? {
        if case .advancedAuthIdentity(let id) = self { return id }
        return nil
    }
}

// MARK: - Connection kind

/// What this profile is used for. Both kinds share the underlying
/// SSH transport (russh) — `.sftp` simply skips the PTY-start step
/// and routes the profile straight to the file browser. This matters
/// for accounts where the server allows SFTP but not a login shell
/// (chroot jails, `scponly` users, hosting providers that publish
/// SFTP-only credentials). On those hosts, opening a terminal would
/// fail with a non-zero exec status — declaring the profile as
/// `.sftp` removes that footgun.
public enum ConnectionKind: String, Codable, Sendable, CaseIterable {
    /// Full SSH session: terminal tab + file browser + system monitor.
    case ssh
    /// File transfer only: connects but never starts a PTY. The
    /// sidebar routes the click straight to the Files view.
    case sftp

    public var displayName: String {
        switch self {
        case .ssh: return "SSH (Terminal + Files)"
        case .sftp: return "SFTP only (Files)"
        }
    }

    /// Whether profiles of this kind can host an interactive shell.
    /// Terminal tabs, the live PTY, and the system-monitor view all
    /// gate on this.
    public var supportsTerminal: Bool {
        switch self {
        case .ssh: return true
        case .sftp: return false
        }
    }
}

// MARK: - Connection profile

public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var authMethod: AuthMethod
    public var kind: ConnectionKind
    public var folderPath: String?

    // Non-credential auth details. New saves use `sshKeyReference`; the
    // computed `privateKeyPath` keeps older call sites and imported JSON
    // working while profiles migrate away from raw paths.
    public var sshKeyReference: SSHKeyReference?
    public var privateKeyPath: String? {
        get { sshKeyReference?.legacyPath }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            sshKeyReference = trimmed?.isEmpty == false ? .plainPath(trimmed!) : nil
        }
    }

    public var createdAt: Date
    public var lastConnected: Date?
    public var favorite: Bool
    public var tags: [String]
    public var color: String?
    public var notes: String?
    public var networkOptions: NetworkConnectionOptions
    public var monitoredSystemdServices: [String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        host: String,
        port: UInt16 = 22,
        username: String,
        authMethod: AuthMethod = .password,
        kind: ConnectionKind = .ssh,
        folderPath: String? = nil,
        privateKeyPath: String? = nil,
        sshKeyReference: SSHKeyReference? = nil,
        createdAt: Date = Date(),
        lastConnected: Date? = nil,
        favorite: Bool = false,
        tags: [String] = [],
        color: String? = nil,
        notes: String? = nil,
        networkOptions: NetworkConnectionOptions = .default,
        monitoredSystemdServices: [String] = []
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.kind = kind
        self.folderPath = folderPath
        if let sshKeyReference {
            self.sshKeyReference = sshKeyReference
        } else if let privateKeyPath,
                  !privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.sshKeyReference = .plainPath(privateKeyPath)
        } else {
            self.sshKeyReference = nil
        }
        self.createdAt = createdAt
        self.lastConnected = lastConnected
        self.favorite = favorite
        self.tags = tags
        self.color = color
        self.notes = notes
        self.networkOptions = networkOptions
        self.monitoredSystemdServices = monitoredSystemdServices
    }

    /// Keychain account string derived from this profile.
    public var keychainAccount: String { "\(username)@\(host):\(port)" }

    // Decode with `kind` defaulting to `.ssh` so older saved stores
    // (no `kind` field) round-trip cleanly.
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod, kind, folderPath
        case privateKeyPath, sshKeyReference, createdAt, lastConnected, favorite, tags, color, notes
        case networkOptions, monitoredSystemdServices
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.host = try c.decode(String.self, forKey: .host)
        self.port = try c.decode(UInt16.self, forKey: .port)
        self.username = try c.decode(String.self, forKey: .username)
        self.authMethod = try c.decode(AuthMethod.self, forKey: .authMethod)
        self.kind = try c.decodeIfPresent(ConnectionKind.self, forKey: .kind) ?? .ssh
        self.folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        if let reference = try c.decodeIfPresent(SSHKeyReference.self, forKey: .sshKeyReference) {
            self.sshKeyReference = reference
        } else if let legacyPath = try c.decodeIfPresent(String.self, forKey: .privateKeyPath),
                  !legacyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.sshKeyReference = .plainPath(legacyPath)
        } else {
            self.sshKeyReference = nil
        }
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
        self.favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.color = try c.decodeIfPresent(String.self, forKey: .color)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.networkOptions = try c.decodeIfPresent(NetworkConnectionOptions.self, forKey: .networkOptions) ?? .default
        self.monitoredSystemdServices = try c.decodeIfPresent([String].self, forKey: .monitoredSystemdServices) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(authMethod, forKey: .authMethod)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(folderPath, forKey: .folderPath)
        try c.encodeIfPresent(privateKeyPath, forKey: .privateKeyPath)
        try c.encodeIfPresent(sshKeyReference, forKey: .sshKeyReference)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastConnected, forKey: .lastConnected)
        try c.encode(favorite, forKey: .favorite)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encode(networkOptions, forKey: .networkOptions)
        try c.encode(monitoredSystemdServices, forKey: .monitoredSystemdServices)
    }
}

// MARK: - Connection folder

public struct ConnectionFolder: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var parentPath: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        parentPath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.parentPath = parentPath
        self.createdAt = createdAt
    }
}

// MARK: - Connection store

/// Persisted connection database. Saved as JSON to Application Support.
public struct ConnectionStoreData: Codable, Sendable {
    public var connections: [ConnectionProfile]
    public var folders: [ConnectionFolder]

    public static let empty = ConnectionStoreData(connections: [], folders: [])

    public init(connections: [ConnectionProfile], folders: [ConnectionFolder]) {
        self.connections = connections
        self.folders = folders
    }
}

// MARK: - JSON import format from Tauri app

public struct TauriConnectionImport: Codable, Sendable {
    public var connections: [TauriConnectionEntry]
    public var folders: [TauriFolderEntry]?
}

public struct TauriConnectionEntry: Codable, Sendable {
    public var id: String?
    public var name: String?
    public var host: String?
    public var port: UInt16?
    public var username: String?
    public var authMethod: String?
    public var password: String?
    public var privateKeyPath: String?
    public var passphrase: String?
    public var folder: String?
    public var favorite: Bool?
    public var tags: [String]?
    public var color: String?
    public var description: String?
    public var createdAt: String?
    public var lastConnected: String?
    public var `protocol`: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod, password, privateKeyPath
        case passphrase, folder, favorite, tags, color, description, createdAt
        case lastConnected
        case `protocol`
    }
}

public struct TauriFolderEntry: Codable, Sendable {
    public var id: String?
    public var name: String?
    public var path: String?
    public var parentPath: String?
    public var createdAt: String?
}
