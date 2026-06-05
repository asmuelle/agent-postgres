import Foundation

public enum SecurityPatchCollectorProfile: String, Codable, Sendable, CaseIterable, Hashable {
    case os
    case packageManager
    case reboot
    case sshd
    case networkExposure

    public var displayName: String {
        switch self {
        case .os: return "OS"
        case .packageManager: return "Packages"
        case .reboot: return "Reboot"
        case .sshd: return "SSH Hardening"
        case .networkExposure: return "Network Exposure"
        }
    }
}

public enum SecurityPatchPackageManager: String, Codable, Sendable, CaseIterable {
    case apt
    case dnf
    case yum
    case zypper
    case pacman
    case apk
    case homebrew
    case unknown

    public var displayName: String {
        switch self {
        case .apt: return "apt"
        case .dnf: return "dnf"
        case .yum: return "yum"
        case .zypper: return "zypper"
        case .pacman: return "pacman"
        case .apk: return "apk"
        case .homebrew: return "Homebrew"
        case .unknown: return "Unknown"
        }
    }
}

public enum SecurityPatchSeverity: String, Codable, Sendable, CaseIterable, Comparable {
    case critical
    case high
    case warning
    case info
    case unknown

    private var rank: Int {
        switch self {
        case .critical: return 4
        case .high: return 3
        case .warning: return 2
        case .info: return 1
        case .unknown: return 0
        }
    }

    public static func < (lhs: SecurityPatchSeverity, rhs: SecurityPatchSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum SecurityPatchFindingKind: String, Codable, Sendable, CaseIterable {
    case securityUpdatesAvailable
    case normalUpdatesAvailable
    case knownExploitedVulnerability
    case rebootRequired
    case unsupportedOs
    case stalePackageMetadata
    case riskySshdSetting
    case weakSshAlgorithm
    case permissionLimited
    case scannerUnsupported
    case noImmediateIssue
}

public enum SecurityPatchEvidenceKind: String, Codable, Sendable, CaseIterable {
    case commandOutput
    case osRelease
    case packageStatus
    case rebootStatus
    case sshdConfig
    case networkExposure
}

public enum SecurityPatchMetadataStatus: String, Codable, Sendable, CaseIterable {
    case fresh
    case stale
    case unknown
    case unsupported
}

public enum SecurityPatchRebootStatus: String, Codable, Sendable, CaseIterable {
    case required
    case notRequired
    case unknown
}

public enum SecurityPatchHostBadge: String, Codable, Sendable, CaseIterable {
    case secure
    case securityUpdates
    case updatesAvailable
    case critical
    case rebootNeeded
    case unknown
    case unsupported

    public var displayName: String {
        switch self {
        case .secure: return "Secure"
        case .securityUpdates: return "Security Updates"
        case .updatesAvailable: return "Updates Available"
        case .critical: return "Critical"
        case .rebootNeeded: return "Reboot Needed"
        case .unknown: return "Unknown"
        case .unsupported: return "Unsupported"
        }
    }
}

public enum SecurityPatchAdvisorySource: String, Codable, Sendable, CaseIterable {
    case cisaKev

    public var displayName: String {
        switch self {
        case .cisaKev: return "CISA KEV"
        }
    }
}

public struct SecurityPatchScanRequest: Codable, Equatable, Sendable {
    public var connectionId: String
    public var profileId: String?
    public var hostLabel: String
    public var profiles: [SecurityPatchCollectorProfile]
    public var maxTotalBytes: Int
    public var perCommandTimeoutMs: Int
    public var lineLimit: Int

    public init(
        connectionId: String,
        profileId: String? = nil,
        hostLabel: String,
        profiles: [SecurityPatchCollectorProfile] = SecurityPatchCollectorProfile.allCases,
        maxTotalBytes: Int = 1_500_000,
        perCommandTimeoutMs: Int = 8_000,
        lineLimit: Int = 500
    ) {
        self.connectionId = connectionId
        self.profileId = profileId
        self.hostLabel = hostLabel
        self.profiles = profiles
        self.maxTotalBytes = maxTotalBytes
        self.perCommandTimeoutMs = perCommandTimeoutMs
        self.lineLimit = lineLimit
    }
}

public struct SecurityPatchPlannedCommand: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var profile: SecurityPatchCollectorProfile
    public var displayName: String
    public var command: String

    public init(
        id: String,
        profile: SecurityPatchCollectorProfile,
        displayName: String,
        command: String
    ) {
        self.id = id
        self.profile = profile
        self.displayName = displayName
        self.command = command
    }
}

public struct SecurityPatchScanPreview: Codable, Equatable, Sendable {
    public var request: SecurityPatchScanRequest
    public var plannedCommands: [SecurityPatchPlannedCommand]
    public var notes: [String]

    public init(
        request: SecurityPatchScanRequest,
        plannedCommands: [SecurityPatchPlannedCommand],
        notes: [String] = []
    ) {
        self.request = request
        self.plannedCommands = plannedCommands
        self.notes = notes
    }
}

public struct SecurityPatchCommandAudit: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var collectorId: String
    public var profile: SecurityPatchCollectorProfile
    public var displayName: String
    public var command: String
    public var startedAt: Date
    public var durationMs: Int
    public var exitStatus: Int?
    public var stdoutBytes: Int
    public var stderrBytes: Int
    public var truncated: Bool
    public var permissionLimited: Bool
    public var risk: String

    public init(
        id: String,
        collectorId: String,
        profile: SecurityPatchCollectorProfile,
        displayName: String,
        command: String,
        startedAt: Date,
        durationMs: Int,
        exitStatus: Int?,
        stdoutBytes: Int,
        stderrBytes: Int,
        truncated: Bool,
        permissionLimited: Bool,
        risk: String = "read_only"
    ) {
        self.id = id
        self.collectorId = collectorId
        self.profile = profile
        self.displayName = displayName
        self.command = command
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.exitStatus = exitStatus
        self.stdoutBytes = stdoutBytes
        self.stderrBytes = stderrBytes
        self.truncated = truncated
        self.permissionLimited = permissionLimited
        self.risk = risk
    }
}

public struct SecurityPatchEvidence: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var collectorId: String
    public var profile: SecurityPatchCollectorProfile
    public var kind: SecurityPatchEvidenceKind
    public var title: String
    public var source: String
    public var collectedAt: Date
    public var risk: String
    public var exitStatus: Int?
    public var excerpt: String
    public var rawOutput: String
    public var rawRef: String
    public var byteCount: Int
    public var lineCount: Int
    public var truncated: Bool
    public var permissionLimited: Bool

    public init(
        id: String,
        collectorId: String,
        profile: SecurityPatchCollectorProfile,
        kind: SecurityPatchEvidenceKind,
        title: String,
        source: String,
        collectedAt: Date,
        risk: String = "read_only",
        exitStatus: Int?,
        excerpt: String,
        rawOutput: String,
        rawRef: String,
        byteCount: Int,
        lineCount: Int,
        truncated: Bool,
        permissionLimited: Bool
    ) {
        self.id = id
        self.collectorId = collectorId
        self.profile = profile
        self.kind = kind
        self.title = title
        self.source = source
        self.collectedAt = collectedAt
        self.risk = risk
        self.exitStatus = exitStatus
        self.excerpt = excerpt
        self.rawOutput = rawOutput
        self.rawRef = rawRef
        self.byteCount = byteCount
        self.lineCount = lineCount
        self.truncated = truncated
        self.permissionLimited = permissionLimited
    }
}

public struct SecurityPatchWarning: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }
}

public struct SecurityPatchScanBundle: Codable, Equatable, Sendable {
    public var id: String
    public var connectionId: String
    public var profileId: String?
    public var hostLabel: String
    public var scannedAt: Date
    public var profiles: [SecurityPatchCollectorProfile]
    public var commandAudits: [SecurityPatchCommandAudit]
    public var evidence: [SecurityPatchEvidence]
    public var warnings: [SecurityPatchWarning]

    public init(
        id: String,
        connectionId: String,
        profileId: String? = nil,
        hostLabel: String,
        scannedAt: Date = Date(),
        profiles: [SecurityPatchCollectorProfile],
        commandAudits: [SecurityPatchCommandAudit],
        evidence: [SecurityPatchEvidence],
        warnings: [SecurityPatchWarning] = []
    ) {
        self.id = id
        self.connectionId = connectionId
        self.profileId = profileId
        self.hostLabel = hostLabel
        self.scannedAt = scannedAt
        self.profiles = profiles
        self.commandAudits = commandAudits
        self.evidence = evidence
        self.warnings = warnings
    }
}

public struct SecurityPatchOsInfo: Codable, Equatable, Sendable {
    public var prettyName: String?
    public var id: String?
    public var versionId: String?
    public var kernel: String?

    public init(
        prettyName: String? = nil,
        id: String? = nil,
        versionId: String? = nil,
        kernel: String? = nil
    ) {
        self.prettyName = prettyName
        self.id = id
        self.versionId = versionId
        self.kernel = kernel
    }
}

public struct SecurityPatchPackageSummary: Codable, Equatable, Sendable {
    public var packageManager: SecurityPatchPackageManager
    public var totalUpdateCount: Int?
    public var securityUpdateCount: Int?
    public var updatePackages: [String]
    public var securityUpdatePackages: [String]
    public var supportsSecurityUpdateCount: Bool
    public var metadataStatus: SecurityPatchMetadataStatus
    public var notes: [String]

    public init(
        packageManager: SecurityPatchPackageManager = .unknown,
        totalUpdateCount: Int? = nil,
        securityUpdateCount: Int? = nil,
        updatePackages: [String] = [],
        securityUpdatePackages: [String] = [],
        supportsSecurityUpdateCount: Bool = false,
        metadataStatus: SecurityPatchMetadataStatus = .unknown,
        notes: [String] = []
    ) {
        self.packageManager = packageManager
        self.totalUpdateCount = totalUpdateCount
        self.securityUpdateCount = securityUpdateCount
        self.updatePackages = updatePackages
        self.securityUpdatePackages = securityUpdatePackages
        self.supportsSecurityUpdateCount = supportsSecurityUpdateCount
        self.metadataStatus = metadataStatus
        self.notes = notes
    }
}

public struct SecurityPatchSshdSetting: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var key: String
    public var value: String
    public var severity: SecurityPatchSeverity
    public var summary: String
    public var evidenceId: String?

    public init(
        id: String? = nil,
        key: String,
        value: String,
        severity: SecurityPatchSeverity,
        summary: String,
        evidenceId: String? = nil
    ) {
        self.id = id ?? "\(key)=\(value)"
        self.key = key
        self.value = value
        self.severity = severity
        self.summary = summary
        self.evidenceId = evidenceId
    }
}

public struct SecurityPatchSshdSummary: Codable, Equatable, Sendable {
    public var version: String?
    public var effectiveConfigAvailable: Bool
    public var configFileReadable: Bool
    public var riskySettings: [SecurityPatchSshdSetting]
    public var weakAlgorithms: [SecurityPatchSshdSetting]

    public init(
        version: String? = nil,
        effectiveConfigAvailable: Bool = false,
        configFileReadable: Bool = false,
        riskySettings: [SecurityPatchSshdSetting] = [],
        weakAlgorithms: [SecurityPatchSshdSetting] = []
    ) {
        self.version = version
        self.effectiveConfigAvailable = effectiveConfigAvailable
        self.configFileReadable = configFileReadable
        self.riskySettings = riskySettings
        self.weakAlgorithms = weakAlgorithms
    }
}

public struct SecurityPatchAdvisoryMatch: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(source.rawValue):\(cveId)" }
    public var source: SecurityPatchAdvisorySource
    public var cveId: String
    public var title: String
    public var vendorProject: String
    public var product: String
    public var dueDate: String?
    public var knownRansomwareCampaignUse: String?
    public var requiredAction: String
    public var notes: String?
    public var evidenceIds: [String]

    public init(
        source: SecurityPatchAdvisorySource,
        cveId: String,
        title: String,
        vendorProject: String,
        product: String,
        dueDate: String? = nil,
        knownRansomwareCampaignUse: String? = nil,
        requiredAction: String,
        notes: String? = nil,
        evidenceIds: [String] = []
    ) {
        self.source = source
        self.cveId = cveId
        self.title = title
        self.vendorProject = vendorProject
        self.product = product
        self.dueDate = dueDate
        self.knownRansomwareCampaignUse = knownRansomwareCampaignUse
        self.requiredAction = requiredAction
        self.notes = notes
        self.evidenceIds = evidenceIds
    }
}

public struct SecurityPatchKevCatalog: Codable, Equatable, Sendable {
    public var title: String?
    public var catalogVersion: String?
    public var dateReleased: String?
    public var count: Int?
    public var vulnerabilities: [SecurityPatchKevVulnerability]

    public init(
        title: String? = nil,
        catalogVersion: String? = nil,
        dateReleased: String? = nil,
        count: Int? = nil,
        vulnerabilities: [SecurityPatchKevVulnerability]
    ) {
        self.title = title
        self.catalogVersion = catalogVersion
        self.dateReleased = dateReleased
        self.count = count
        self.vulnerabilities = vulnerabilities
    }
}

public struct SecurityPatchKevVulnerability: Codable, Equatable, Sendable {
    public var cveID: String
    public var vendorProject: String
    public var product: String
    public var vulnerabilityName: String
    public var dateAdded: String?
    public var shortDescription: String?
    public var requiredAction: String
    public var dueDate: String?
    public var knownRansomwareCampaignUse: String?
    public var notes: String?

    public init(
        cveID: String,
        vendorProject: String,
        product: String,
        vulnerabilityName: String,
        dateAdded: String? = nil,
        shortDescription: String? = nil,
        requiredAction: String,
        dueDate: String? = nil,
        knownRansomwareCampaignUse: String? = nil,
        notes: String? = nil
    ) {
        self.cveID = cveID
        self.vendorProject = vendorProject
        self.product = product
        self.vulnerabilityName = vulnerabilityName
        self.dateAdded = dateAdded
        self.shortDescription = shortDescription
        self.requiredAction = requiredAction
        self.dueDate = dueDate
        self.knownRansomwareCampaignUse = knownRansomwareCampaignUse
        self.notes = notes
    }
}

public struct SecurityPatchFinding: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: SecurityPatchFindingKind
    public var title: String
    public var summary: String
    public var severity: SecurityPatchSeverity
    public var evidenceIds: [String]
    public var recommendation: String

    public init(
        id: String = UUID().uuidString,
        kind: SecurityPatchFindingKind,
        title: String,
        summary: String,
        severity: SecurityPatchSeverity,
        evidenceIds: [String] = [],
        recommendation: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.severity = severity
        self.evidenceIds = evidenceIds
        self.recommendation = recommendation
    }
}

public struct SecurityPatchHostSummary: Codable, Equatable, Sendable {
    public var connectionId: String
    public var profileId: String?
    public var hostLabel: String
    public var badge: SecurityPatchHostBadge
    public var severity: SecurityPatchSeverity
    public var summary: String
    public var scannedAt: Date?
    public var securityUpdateCount: Int?
    public var totalUpdateCount: Int?
    public var rebootRequired: Bool

    public init(
        connectionId: String,
        profileId: String? = nil,
        hostLabel: String,
        badge: SecurityPatchHostBadge,
        severity: SecurityPatchSeverity,
        summary: String,
        scannedAt: Date? = nil,
        securityUpdateCount: Int? = nil,
        totalUpdateCount: Int? = nil,
        rebootRequired: Bool = false
    ) {
        self.connectionId = connectionId
        self.profileId = profileId
        self.hostLabel = hostLabel
        self.badge = badge
        self.severity = severity
        self.summary = summary
        self.scannedAt = scannedAt
        self.securityUpdateCount = securityUpdateCount
        self.totalUpdateCount = totalUpdateCount
        self.rebootRequired = rebootRequired
    }
}

public struct SecurityPatchScanResult: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var connectionId: String
    public var profileId: String?
    public var hostLabel: String
    public var scannedAt: Date
    public var osInfo: SecurityPatchOsInfo
    public var packageSummary: SecurityPatchPackageSummary
    public var rebootStatus: SecurityPatchRebootStatus
    public var sshdSummary: SecurityPatchSshdSummary
    public var findings: [SecurityPatchFinding]
    public var evidence: [SecurityPatchEvidence]
    public var commandAudits: [SecurityPatchCommandAudit]
    public var warnings: [SecurityPatchWarning]
    public var advisoryMatches: [SecurityPatchAdvisoryMatch]
    public var overallSeverity: SecurityPatchSeverity
    public var summaryLabel: String
    public var isPermissionLimited: Bool

    public init(
        id: String = UUID().uuidString,
        connectionId: String,
        profileId: String? = nil,
        hostLabel: String,
        scannedAt: Date,
        osInfo: SecurityPatchOsInfo,
        packageSummary: SecurityPatchPackageSummary,
        rebootStatus: SecurityPatchRebootStatus,
        sshdSummary: SecurityPatchSshdSummary,
        findings: [SecurityPatchFinding],
        evidence: [SecurityPatchEvidence],
        commandAudits: [SecurityPatchCommandAudit],
        warnings: [SecurityPatchWarning],
        advisoryMatches: [SecurityPatchAdvisoryMatch] = [],
        overallSeverity: SecurityPatchSeverity,
        summaryLabel: String,
        isPermissionLimited: Bool
    ) {
        self.id = id
        self.connectionId = connectionId
        self.profileId = profileId
        self.hostLabel = hostLabel
        self.scannedAt = scannedAt
        self.osInfo = osInfo
        self.packageSummary = packageSummary
        self.rebootStatus = rebootStatus
        self.sshdSummary = sshdSummary
        self.findings = findings
        self.evidence = evidence
        self.commandAudits = commandAudits
        self.warnings = warnings
        self.advisoryMatches = advisoryMatches
        self.overallSeverity = overallSeverity
        self.summaryLabel = summaryLabel
        self.isPermissionLimited = isPermissionLimited
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case connectionId
        case profileId
        case hostLabel
        case scannedAt
        case osInfo
        case packageSummary
        case rebootStatus
        case sshdSummary
        case findings
        case evidence
        case commandAudits
        case warnings
        case advisoryMatches
        case overallSeverity
        case summaryLabel
        case isPermissionLimited
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        connectionId = try container.decode(String.self, forKey: .connectionId)
        profileId = try container.decodeIfPresent(String.self, forKey: .profileId)
        hostLabel = try container.decode(String.self, forKey: .hostLabel)
        scannedAt = try container.decode(Date.self, forKey: .scannedAt)
        osInfo = try container.decode(SecurityPatchOsInfo.self, forKey: .osInfo)
        packageSummary = try container.decode(SecurityPatchPackageSummary.self, forKey: .packageSummary)
        rebootStatus = try container.decode(SecurityPatchRebootStatus.self, forKey: .rebootStatus)
        sshdSummary = try container.decode(SecurityPatchSshdSummary.self, forKey: .sshdSummary)
        findings = try container.decode([SecurityPatchFinding].self, forKey: .findings)
        evidence = try container.decode([SecurityPatchEvidence].self, forKey: .evidence)
        commandAudits = try container.decode([SecurityPatchCommandAudit].self, forKey: .commandAudits)
        warnings = try container.decode([SecurityPatchWarning].self, forKey: .warnings)
        advisoryMatches = try container.decodeIfPresent(
            [SecurityPatchAdvisoryMatch].self,
            forKey: .advisoryMatches
        ) ?? []
        overallSeverity = try container.decode(SecurityPatchSeverity.self, forKey: .overallSeverity)
        summaryLabel = try container.decode(String.self, forKey: .summaryLabel)
        isPermissionLimited = try container.decode(Bool.self, forKey: .isPermissionLimited)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(connectionId, forKey: .connectionId)
        try container.encodeIfPresent(profileId, forKey: .profileId)
        try container.encode(hostLabel, forKey: .hostLabel)
        try container.encode(scannedAt, forKey: .scannedAt)
        try container.encode(osInfo, forKey: .osInfo)
        try container.encode(packageSummary, forKey: .packageSummary)
        try container.encode(rebootStatus, forKey: .rebootStatus)
        try container.encode(sshdSummary, forKey: .sshdSummary)
        try container.encode(findings, forKey: .findings)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(commandAudits, forKey: .commandAudits)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(advisoryMatches, forKey: .advisoryMatches)
        try container.encode(overallSeverity, forKey: .overallSeverity)
        try container.encode(summaryLabel, forKey: .summaryLabel)
        try container.encode(isPermissionLimited, forKey: .isPermissionLimited)
    }

    public var hostSummary: SecurityPatchHostSummary {
        SecurityPatchHostSummary(
            connectionId: connectionId,
            profileId: profileId,
            hostLabel: hostLabel,
            badge: SecurityPatchMonitorScoring.badge(
                severity: overallSeverity,
                packageSummary: packageSummary,
                rebootStatus: rebootStatus
            ),
            severity: overallSeverity,
            summary: summaryLabel,
            scannedAt: scannedAt,
            securityUpdateCount: packageSummary.securityUpdateCount,
            totalUpdateCount: packageSummary.totalUpdateCount,
            rebootRequired: rebootStatus == .required
        )
    }
}
