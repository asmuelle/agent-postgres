import Foundation

public enum CloudSyncSchema {
    public static let currentVersion = 1
}

public enum CloudSyncCollection: String, Codable, CaseIterable, Hashable, Sendable {
    case profile
    case snippet
    case terminalSettings
}

public struct CloudSyncTombstoneRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(collection.rawValue):\(recordId)" }
    public var collection: CloudSyncCollection
    public var recordId: String
    public var deletedAt: Date

    public init(collection: CloudSyncCollection, recordId: String, deletedAt: Date = Date()) {
        self.collection = collection
        self.recordId = recordId
        self.deletedAt = deletedAt
    }
}

public enum SyncedConnectionAuthMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case password
    case publicKey

    public init(_ authMethod: AuthMethod) {
        switch authMethod {
        case .password: self = .password
        case .publicKey: self = .publicKey
        }
    }

    public var connectionAuthMethod: AuthMethod {
        switch self {
        case .password: return .password
        case .publicKey: return .publicKey
        }
    }
}

public enum SyncedConnectionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case ssh
    case sftp

    public init(_ kind: ConnectionKind) {
        switch kind {
        case .ssh: self = .ssh
        case .sftp: self = .sftp
        }
    }

    public var connectionKind: ConnectionKind {
        switch self {
        case .ssh: return .ssh
        case .sftp: return .sftp
        }
    }
}

public struct SyncedConnectionProfileRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var authMethod: SyncedConnectionAuthMethod
    public var kind: SyncedConnectionKind
    public var folderPath: String?
    public var favorite: Bool
    public var tags: [String]
    public var color: String?
    public var notes: String?
    public var networkOptions: NetworkConnectionOptions
    public var monitoredSystemdServices: [String]
    public var createdAt: Date
    public var lastConnected: Date?
    public var updatedAt: Date
    public var keychainAccountHint: String
    public var sshKeyDisplayName: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod, kind, folderPath
        case favorite, tags, color, notes, networkOptions, monitoredSystemdServices
        case createdAt, lastConnected, updatedAt, keychainAccountHint, sshKeyDisplayName
    }

    public init(
        id: String,
        name: String,
        host: String,
        port: UInt16,
        username: String,
        authMethod: SyncedConnectionAuthMethod,
        kind: SyncedConnectionKind,
        folderPath: String? = nil,
        favorite: Bool = false,
        tags: [String] = [],
        color: String? = nil,
        notes: String? = nil,
        networkOptions: NetworkConnectionOptions = .default,
        monitoredSystemdServices: [String] = [],
        createdAt: Date = Date(),
        lastConnected: Date? = nil,
        updatedAt: Date = Date(),
        keychainAccountHint: String? = nil,
        sshKeyDisplayName: String? = nil
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authMethod = authMethod
        self.kind = kind
        self.folderPath = folderPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.favorite = favorite
        self.tags = Self.normalizedTags(tags)
        self.color = color?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.notes = notes
        self.networkOptions = networkOptions
        self.monitoredSystemdServices = Self.normalizedTags(monitoredSystemdServices)
        self.createdAt = createdAt
        self.lastConnected = lastConnected
        self.updatedAt = updatedAt
        self.keychainAccountHint = keychainAccountHint ?? "\(self.username)@\(self.host):\(port)"
        self.sshKeyDisplayName = sshKeyDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public init(profile: ConnectionProfile, updatedAt: Date = Date()) {
        self.init(
            id: profile.id,
            name: profile.name,
            host: profile.host,
            port: profile.port,
            username: profile.username,
            authMethod: SyncedConnectionAuthMethod(profile.authMethod),
            kind: SyncedConnectionKind(profile.kind),
            folderPath: profile.folderPath,
            favorite: profile.favorite,
            tags: profile.tags,
            color: profile.color,
            notes: profile.notes,
            networkOptions: profile.networkOptions,
            monitoredSystemdServices: profile.monitoredSystemdServices,
            createdAt: profile.createdAt,
            lastConnected: profile.lastConnected,
            updatedAt: updatedAt,
            keychainAccountHint: profile.keychainAccount,
            sshKeyDisplayName: profile.sshKeyReference?.cloudSafeDisplayName
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            host: container.decode(String.self, forKey: .host),
            port: container.decode(UInt16.self, forKey: .port),
            username: container.decode(String.self, forKey: .username),
            authMethod: container.decode(SyncedConnectionAuthMethod.self, forKey: .authMethod),
            kind: container.decode(SyncedConnectionKind.self, forKey: .kind),
            folderPath: container.decodeIfPresent(String.self, forKey: .folderPath),
            favorite: container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false,
            tags: container.decodeIfPresent([String].self, forKey: .tags) ?? [],
            color: container.decodeIfPresent(String.self, forKey: .color),
            notes: container.decodeIfPresent(String.self, forKey: .notes),
            networkOptions: container.decodeIfPresent(NetworkConnectionOptions.self, forKey: .networkOptions) ?? .default,
            monitoredSystemdServices: container.decodeIfPresent([String].self, forKey: .monitoredSystemdServices) ?? [],
            createdAt: container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            lastConnected: container.decodeIfPresent(Date.self, forKey: .lastConnected),
            updatedAt: container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(),
            keychainAccountHint: container.decodeIfPresent(String.self, forKey: .keychainAccountHint),
            sshKeyDisplayName: container.decodeIfPresent(String.self, forKey: .sshKeyDisplayName)
        )
    }

    public func connectionProfile(preserving existing: ConnectionProfile? = nil) -> ConnectionProfile {
        ConnectionProfile(
            id: id,
            name: name.isEmpty ? host : name,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod.connectionAuthMethod,
            kind: kind.connectionKind,
            folderPath: folderPath,
            sshKeyReference: existing?.sshKeyReference,
            createdAt: existing?.createdAt ?? createdAt,
            lastConnected: mostRecent(lastConnected, existing?.lastConnected),
            favorite: favorite,
            tags: tags,
            color: color,
            notes: notes,
            networkOptions: networkOptions,
            monitoredSystemdServices: monitoredSystemdServices
        )
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

public struct SyncedTerminalSettingsRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "terminal" }
    public var defaultColumns: Int
    public var defaultRows: Int
    public var fontSize: Double
    public var themeId: String
    public var scrollbackLines: Int
    public var cursorStyleId: String
    public var mouseReporting: Bool
    public var optionAsMeta: Bool
    public var copyOnSelect: Bool
    public var accessoryKeyIds: [String]
    public var updatedAt: Date

    public init(
        defaultColumns: Int = 80,
        defaultRows: Int = 24,
        fontSize: Double = 12,
        themeId: String = "system",
        scrollbackLines: Int = 10_000,
        cursorStyleId: String = "blinkBlock",
        mouseReporting: Bool = true,
        optionAsMeta: Bool = true,
        copyOnSelect: Bool = false,
        accessoryKeyIds: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.defaultColumns = defaultColumns
        self.defaultRows = defaultRows
        self.fontSize = fontSize
        self.themeId = themeId
        self.scrollbackLines = scrollbackLines
        self.cursorStyleId = cursorStyleId
        self.mouseReporting = mouseReporting
        self.optionAsMeta = optionAsMeta
        self.copyOnSelect = copyOnSelect
        self.accessoryKeyIds = accessoryKeyIds
        self.updatedAt = updatedAt
    }
}

public struct CloudSyncSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var sourceDeviceId: String
    public var profiles: [SyncedConnectionProfileRecord]
    public var snippets: [SharedSnippetRecord]
    public var terminalSettings: SyncedTerminalSettingsRecord?
    public var tombstones: [CloudSyncTombstoneRecord]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case sourceDeviceId
        case profiles
        case snippets
        case terminalSettings
        case tombstones
    }

    public init(
        schemaVersion: Int = CloudSyncSchema.currentVersion,
        generatedAt: Date = Date(),
        sourceDeviceId: String = CloudSyncSnapshot.defaultDeviceId,
        profiles: [SyncedConnectionProfileRecord] = [],
        snippets: [SharedSnippetRecord] = [],
        terminalSettings: SyncedTerminalSettingsRecord? = nil,
        tombstones: [CloudSyncTombstoneRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.sourceDeviceId = sourceDeviceId
        self.profiles = profiles
        self.snippets = snippets
        self.terminalSettings = terminalSettings
        self.tombstones = tombstones
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? CloudSyncSchema.currentVersion
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
        sourceDeviceId = try container.decodeIfPresent(String.self, forKey: .sourceDeviceId)
            ?? CloudSyncSnapshot.defaultDeviceId
        profiles = try container.decodeIfPresent([SyncedConnectionProfileRecord].self, forKey: .profiles) ?? []
        snippets = try container.decodeIfPresent([SharedSnippetRecord].self, forKey: .snippets) ?? []
        terminalSettings = try container.decodeIfPresent(SyncedTerminalSettingsRecord.self, forKey: .terminalSettings)
        tombstones = try container.decodeIfPresent([CloudSyncTombstoneRecord].self, forKey: .tombstones) ?? []
    }

    public static let empty = CloudSyncSnapshot()

    public static var defaultDeviceId: String {
        let host = ProcessInfo.processInfo.hostName
        return host.replacingOccurrences(of: " ", with: "-")
    }
}

public struct CloudSyncMergeReport: Codable, Equatable, Sendable {
    public var insertedProfiles: Int = 0
    public var updatedProfiles: Int = 0
    public var skippedProfiles: Int = 0
    public var insertedSnippets: Int = 0
    public var updatedSnippets: Int = 0
    public var skippedSnippets: Int = 0
    public var deletedRecords: Int = 0
    public var terminalSettingsUpdated: Bool = false

    public init(
        insertedProfiles: Int = 0,
        updatedProfiles: Int = 0,
        skippedProfiles: Int = 0,
        insertedSnippets: Int = 0,
        updatedSnippets: Int = 0,
        skippedSnippets: Int = 0,
        deletedRecords: Int = 0,
        terminalSettingsUpdated: Bool = false
    ) {
        self.insertedProfiles = insertedProfiles
        self.updatedProfiles = updatedProfiles
        self.skippedProfiles = skippedProfiles
        self.insertedSnippets = insertedSnippets
        self.updatedSnippets = updatedSnippets
        self.skippedSnippets = skippedSnippets
        self.deletedRecords = deletedRecords
        self.terminalSettingsUpdated = terminalSettingsUpdated
    }

    public var changedRecordCount: Int {
        insertedProfiles + updatedProfiles + insertedSnippets + updatedSnippets + deletedRecords + (terminalSettingsUpdated ? 1 : 0)
    }

    public var summary: String {
        [
            "\(insertedProfiles) added profile\(insertedProfiles == 1 ? "" : "s")",
            "\(updatedProfiles) updated profile\(updatedProfiles == 1 ? "" : "s")",
            "\(insertedSnippets) added snippet\(insertedSnippets == 1 ? "" : "s")",
            "\(updatedSnippets) updated snippet\(updatedSnippets == 1 ? "" : "s")",
            "\(deletedRecords) deletion\(deletedRecords == 1 ? "" : "s")",
        ].joined(separator: ", ")
    }
}

public enum CloudSyncMergeEngine {
    public static func merge(local: CloudSyncSnapshot, incoming: CloudSyncSnapshot) -> (CloudSyncSnapshot, CloudSyncMergeReport) {
        var result = local
        result.schemaVersion = max(local.schemaVersion, incoming.schemaVersion, CloudSyncSchema.currentVersion)
        result.generatedAt = max(local.generatedAt, incoming.generatedAt)
        result.sourceDeviceId = local.sourceDeviceId

        var report = CloudSyncMergeReport()
        let tombstones = mergeTombstones(local.tombstones, incoming.tombstones)
        result.tombstones = tombstones

        result.profiles = mergeRecords(
            local: local.profiles,
            incoming: incoming.profiles,
            tombstones: tombstones.filter { $0.collection == .profile },
            updatedAt: \.updatedAt,
            reportInserted: { report.insertedProfiles += 1 },
            reportUpdated: { report.updatedProfiles += 1 },
            reportSkipped: { report.skippedProfiles += 1 },
            reportDeleted: { report.deletedRecords += 1 }
        )

        result.snippets = mergeRecords(
            local: local.snippets,
            incoming: incoming.snippets,
            tombstones: tombstones.filter { $0.collection == .snippet },
            updatedAt: \.updatedAt,
            reportInserted: { report.insertedSnippets += 1 },
            reportUpdated: { report.updatedSnippets += 1 },
            reportSkipped: { report.skippedSnippets += 1 },
            reportDeleted: { report.deletedRecords += 1 }
        )

        if let incomingSettings = incoming.terminalSettings {
            if let localSettings = local.terminalSettings {
                if incomingSettings.updatedAt > localSettings.updatedAt {
                    result.terminalSettings = incomingSettings
                    report.terminalSettingsUpdated = true
                }
            } else if !isDeleted(recordId: incomingSettings.id, updatedAt: incomingSettings.updatedAt, tombstones: tombstones, collection: .terminalSettings) {
                result.terminalSettings = incomingSettings
                report.terminalSettingsUpdated = true
            }
        }

        if let settings = result.terminalSettings,
           isDeleted(recordId: settings.id, updatedAt: settings.updatedAt, tombstones: tombstones, collection: .terminalSettings) {
            result.terminalSettings = nil
            report.deletedRecords += 1
        }

        return (result, report)
    }

    private static func mergeTombstones(
        _ lhs: [CloudSyncTombstoneRecord],
        _ rhs: [CloudSyncTombstoneRecord]
    ) -> [CloudSyncTombstoneRecord] {
        var byId: [String: CloudSyncTombstoneRecord] = [:]
        for tombstone in lhs + rhs {
            if let existing = byId[tombstone.id], existing.deletedAt >= tombstone.deletedAt {
                continue
            }
            byId[tombstone.id] = tombstone
        }
        return byId.values.sorted { $0.deletedAt > $1.deletedAt }
    }

    private static func mergeRecords<Record: Identifiable & Equatable>(
        local: [Record],
        incoming: [Record],
        tombstones: [CloudSyncTombstoneRecord],
        updatedAt: KeyPath<Record, Date>,
        reportInserted: () -> Void,
        reportUpdated: () -> Void,
        reportSkipped: () -> Void,
        reportDeleted: () -> Void
    ) -> [Record] where Record.ID == String {
        var byId = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })

        for incomingRecord in incoming {
            if isDeleted(recordId: incomingRecord.id, updatedAt: incomingRecord[keyPath: updatedAt], tombstones: tombstones) {
                reportSkipped()
                continue
            }

            guard let localRecord = byId[incomingRecord.id] else {
                byId[incomingRecord.id] = incomingRecord
                reportInserted()
                continue
            }

            if incomingRecord[keyPath: updatedAt] > localRecord[keyPath: updatedAt] {
                byId[incomingRecord.id] = incomingRecord
                reportUpdated()
            } else {
                reportSkipped()
            }
        }

        for record in local where isDeleted(recordId: record.id, updatedAt: record[keyPath: updatedAt], tombstones: tombstones) {
            byId[record.id] = nil
            reportDeleted()
        }

        return byId.values.sorted { lhs, rhs in
            lhs[keyPath: updatedAt] > rhs[keyPath: updatedAt]
        }
    }

    private static func isDeleted(
        recordId: String,
        updatedAt: Date,
        tombstones: [CloudSyncTombstoneRecord],
        collection: CloudSyncCollection? = nil
    ) -> Bool {
        tombstones.contains { tombstone in
            tombstone.recordId == recordId
                && (collection == nil || tombstone.collection == collection)
                && tombstone.deletedAt >= updatedAt
        }
    }
}

public final class CloudSyncStore: @unchecked Sendable {
    private let localStore: SharedJSONFileStore<CloudSyncSnapshot>
    private let ubiquitousStore: NSUbiquitousKeyValueStore?
    private let ubiquitousKey: String

    public init(
        fileName: String = SharedAppStorageConfiguration.cloudSyncSnapshotFileName,
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        ubiquitousStore: NSUbiquitousKeyValueStore? = .default,
        ubiquitousKey: String = "com.mc-ssh.pgAgent.cloud-sync.snapshot"
    ) {
        self.localStore = SharedJSONFileStore(
            fileName: fileName,
            fileManager: fileManager,
            directoryURL: directoryURL
        )
        self.ubiquitousStore = ubiquitousStore
        self.ubiquitousKey = ubiquitousKey
    }

    public func loadLocal() throws -> CloudSyncSnapshot? {
        try localStore.load()
    }

    public func saveLocal(_ snapshot: CloudSyncSnapshot) throws {
        try localStore.save(snapshot)
    }

    public func loadCloud() throws -> CloudSyncSnapshot? {
        guard let data = ubiquitousStore?.data(forKey: ubiquitousKey) else { return nil }
        return try Self.decoder.decode(CloudSyncSnapshot.self, from: data)
    }

    public func saveCloud(_ snapshot: CloudSyncSnapshot) throws {
        guard let ubiquitousStore else { return }
        let data = try Self.encoder.encode(snapshot)
        ubiquitousStore.set(data, forKey: ubiquitousKey)
        ubiquitousStore.synchronize()
    }

    public func loadLatest() throws -> CloudSyncSnapshot? {
        let local = try loadLocal()
        let cloud = try loadCloud()
        switch (local, cloud) {
        case (.none, .none):
            return nil
        case (.some(let snapshot), .none), (.none, .some(let snapshot)):
            return snapshot
        case (.some(let local), .some(let cloud)):
            return cloud.generatedAt > local.generatedAt ? cloud : local
        }
    }

    public func save(_ snapshot: CloudSyncSnapshot) throws {
        try saveLocal(snapshot)
        try saveCloud(snapshot)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct ConnectionCSVRow: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var authMethod: SyncedConnectionAuthMethod
    public var kind: SyncedConnectionKind
    public var folderPath: String?
    public var tags: [String]
    public var favorite: Bool
    public var color: String?
    public var notes: String?

    public init(
        id: String? = nil,
        name: String,
        host: String,
        port: UInt16 = 22,
        username: String,
        authMethod: SyncedConnectionAuthMethod = .password,
        kind: SyncedConnectionKind = .ssh,
        folderPath: String? = nil,
        tags: [String] = [],
        favorite: Bool = false,
        color: String? = nil,
        notes: String? = nil
    ) {
        self.id = id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authMethod = authMethod
        self.kind = kind
        self.folderPath = folderPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.tags = tags
        self.favorite = favorite
        self.color = color?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.notes = notes
    }

    public init(profile: ConnectionProfile) {
        self.init(
            id: profile.id,
            name: profile.name,
            host: profile.host,
            port: profile.port,
            username: profile.username,
            authMethod: SyncedConnectionAuthMethod(profile.authMethod),
            kind: SyncedConnectionKind(profile.kind),
            folderPath: profile.folderPath,
            tags: profile.tags,
            favorite: profile.favorite,
            color: profile.color,
            notes: profile.notes
        )
    }

    public var stableId: String {
        id ?? "csv-\(Self.stableHash([name, host, "\(port)", username].joined(separator: "|")))"
    }

    public func connectionProfile(preserving existing: ConnectionProfile? = nil) -> ConnectionProfile {
        ConnectionProfile(
            id: stableId,
            name: name.isEmpty ? host : name,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod.connectionAuthMethod,
            kind: kind.connectionKind,
            folderPath: folderPath,
            sshKeyReference: existing?.sshKeyReference,
            createdAt: existing?.createdAt ?? Date(),
            lastConnected: existing?.lastConnected,
            favorite: favorite,
            tags: tags,
            color: color,
            notes: notes,
            networkOptions: existing?.networkOptions ?? .default,
            monitoredSystemdServices: existing?.monitoredSystemdServices ?? []
        )
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

public enum ConnectionCSVError: LocalizedError, Equatable {
    case missingHeader
    case missingRequiredColumn(String)
    case malformedRow(Int)
    case invalidPort(row: Int, value: String)

    public var errorDescription: String? {
        switch self {
        case .missingHeader:
            return "CSV import requires a header row."
        case .missingRequiredColumn(let column):
            return "CSV import is missing the required \(column) column."
        case .malformedRow(let row):
            return "CSV row \(row) is malformed."
        case .invalidPort(let row, let value):
            return "CSV row \(row) has an invalid port: \(value)."
        }
    }
}

public enum ConnectionCSVCodec {
    public static let header = [
        "id", "name", "host", "port", "username", "authMethod", "kind",
        "folder", "tags", "favorite", "color", "notes"
    ]

    public static func encode(profiles: [ConnectionProfile]) -> String {
        var rows = [header]
        rows += profiles.map { profile in
            let row = ConnectionCSVRow(profile: profile)
            return [
                row.id ?? "",
                row.name,
                row.host,
                "\(row.port)",
                row.username,
                row.authMethod.rawValue,
                row.kind.rawValue,
                row.folderPath ?? "",
                row.tags.joined(separator: ";"),
                row.favorite ? "true" : "false",
                row.color ?? "",
                row.notes ?? "",
            ]
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    public static func decode(_ csv: String) throws -> [ConnectionCSVRow] {
        let table = parse(csv)
            .filter { row in row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        guard let headerRow = table.first else { throw ConnectionCSVError.missingHeader }
        let headerMap = Dictionary(uniqueKeysWithValues: headerRow.enumerated().map { index, name in
            (name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), index)
        })
        for required in ["name", "host", "username"] where headerMap[required] == nil {
            throw ConnectionCSVError.missingRequiredColumn(required)
        }

        return try table.dropFirst().enumerated().map { offset, fields in
            let rowNumber = offset + 2
            func field(_ name: String) -> String {
                guard let index = headerMap[name.lowercased()], index < fields.count else { return "" }
                return fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let rawPort = field("port")
            let port = rawPort.isEmpty ? 22 : UInt16(rawPort)
            guard let port else { throw ConnectionCSVError.invalidPort(row: rowNumber, value: rawPort) }

            return ConnectionCSVRow(
                id: field("id"),
                name: field("name"),
                host: field("host"),
                port: port,
                username: field("username"),
                authMethod: SyncedConnectionAuthMethod(rawValue: field("authMethod")) ?? .password,
                kind: SyncedConnectionKind(rawValue: field("kind")) ?? .ssh,
                folderPath: field("folder"),
                tags: field("tags").split(separator: ";").map(String.init),
                favorite: ["true", "yes", "1"].contains(field("favorite").lowercased()),
                color: field("color"),
                notes: field("notes")
            )
        }
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func parse(_ csv: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = csv.makeIterator()

        while let char = iterator.next() {
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            if next == "," {
                                row.append(field)
                                field = ""
                            } else if next == "\n" {
                                row.append(field)
                                rows.append(row)
                                row = []
                                field = ""
                            } else if next != "\r" {
                                field.append(next)
                            }
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else {
                switch char {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n":
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                case "\r":
                    continue
                default:
                    field.append(char)
                }
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

public enum ConnectionCSVImportAction: String, Codable, Equatable, Sendable {
    case add
    case update
    case skip
    case invalid
}

public struct ConnectionCSVImportItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var action: ConnectionCSVImportAction
    public var row: ConnectionCSVRow
    public var message: String?

    public init(action: ConnectionCSVImportAction, row: ConnectionCSVRow, message: String? = nil) {
        self.id = row.stableId
        self.action = action
        self.row = row
        self.message = message
    }
}

public struct ConnectionCSVImportPlan: Codable, Equatable, Sendable {
    public var items: [ConnectionCSVImportItem]

    public init(items: [ConnectionCSVImportItem]) {
        self.items = items
    }

    public var addCount: Int { items.filter { $0.action == .add }.count }
    public var updateCount: Int { items.filter { $0.action == .update }.count }
    public var skipCount: Int { items.filter { $0.action == .skip }.count }
    public var invalidCount: Int { items.filter { $0.action == .invalid }.count }

    public var isApplicable: Bool {
        invalidCount == 0 && items.contains { $0.action == .add || $0.action == .update }
    }

    public var summary: String {
        "\(addCount) add, \(updateCount) update, \(skipCount) unchanged, \(invalidCount) invalid"
    }
}

public enum ConnectionCSVImportPlanner {
    public static func plan(existing: [ConnectionProfile], csv: String) throws -> ConnectionCSVImportPlan {
        try plan(existing: existing, rows: ConnectionCSVCodec.decode(csv))
    }

    public static func plan(existing: [ConnectionProfile], rows: [ConnectionCSVRow]) -> ConnectionCSVImportPlan {
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var seenIds = Set<String>()
        let items = rows.map { row -> ConnectionCSVImportItem in
            guard !row.name.isEmpty, !row.host.isEmpty, !row.username.isEmpty else {
                return ConnectionCSVImportItem(action: .invalid, row: row, message: "Name, host, and username are required.")
            }

            let stableId = row.stableId
            guard seenIds.insert(stableId).inserted else {
                return ConnectionCSVImportItem(action: .invalid, row: row, message: "Duplicate stable ID \(stableId).")
            }

            if let existing = existingById[stableId] {
                return row.connectionProfile(preserving: existing) == existing
                    ? ConnectionCSVImportItem(action: .skip, row: row)
                    : ConnectionCSVImportItem(action: .update, row: row)
            }
            return ConnectionCSVImportItem(action: .add, row: row)
        }
        return ConnectionCSVImportPlan(items: items)
    }

    public static func apply(_ plan: ConnectionCSVImportPlan, to existing: [ConnectionProfile]) -> [ConnectionProfile] {
        var output = existing
        for item in plan.items {
            switch item.action {
            case .add:
                output.append(item.row.connectionProfile())
            case .update:
                guard let index = output.firstIndex(where: { $0.id == item.id }) else { continue }
                output[index] = item.row.connectionProfile(preserving: output[index])
            case .skip, .invalid:
                continue
            }
        }
        return output
    }
}

private func mostRecent(_ lhs: Date?, _ rhs: Date?) -> Date? {
    switch (lhs, rhs) {
    case (.none, .none): return nil
    case (.some(let date), .none), (.none, .some(let date)): return date
    case (.some(let lhs), .some(let rhs)): return max(lhs, rhs)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension SSHKeyReference {
    var cloudSafeDisplayName: String? {
        switch self {
        case .plainPath, .securityScopedBookmark, .agent, .advancedAuthIdentity:
            return nil
        case .importedVaultKey(let id):
            return "Imported key \(String(id.prefix(8)))"
        case .generatedVaultKey(let id):
            return "Generated key \(String(id.prefix(8)))"
        }
    }
}
