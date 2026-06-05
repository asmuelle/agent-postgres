import Foundation

public enum ServerDoctorScope: String, Codable, Sendable, CaseIterable {
    case broadHost
    case selectedService
    case selectedLog
    case selectedConfig
}

public enum ServerDoctorCollectorProfile: String, Codable, Sendable, CaseIterable, Hashable {
    case host
    case systemd
    case nginx
    case disk

    public var displayName: String {
        switch self {
        case .host: return "Host Basics"
        case .systemd: return "systemd"
        case .nginx: return "nginx"
        case .disk: return "Disk"
        }
    }
}

public enum ServerDoctorSeverity: String, Codable, Sendable, CaseIterable, Comparable {
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

    public static func < (lhs: ServerDoctorSeverity, rhs: ServerDoctorSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum ServerDoctorConfidence: String, Codable, Sendable, CaseIterable {
    case high
    case medium
    case low
}

public enum ServerDoctorEvidenceKind: String, Codable, Sendable, CaseIterable {
    case commandOutput
    case logExcerpt
    case configExcerpt
    case fileMetadata
    case metricSample
    case serviceStatus
}

public enum ServerDoctorSuggestedActionKind: String, Codable, Sendable, CaseIterable {
    case inspectEvidence
    case openLog
    case openConfig
    case runReadOnlyFollowup
}

public enum ServerDoctorPrivacyPreset: String, Codable, Sendable, CaseIterable {
    case balanced
    case strict
    case localOnly

    public var displayName: String {
        switch self {
        case .balanced: return "Balanced"
        case .strict: return "Strict"
        case .localOnly: return "Local Only"
        }
    }
}

public struct ServerDoctorCollectionRequest: Codable, Equatable, Sendable {
    public var connectionId: String
    public var hostLabel: String
    public var scope: ServerDoctorScope
    public var profiles: [ServerDoctorCollectorProfile]
    public var serviceName: String?
    public var maxTotalBytes: Int
    public var perCommandTimeoutMs: Int
    public var logLineLimit: Int
    public var privacyPreset: ServerDoctorPrivacyPreset

    public init(
        connectionId: String,
        hostLabel: String,
        scope: ServerDoctorScope = .broadHost,
        profiles: [ServerDoctorCollectorProfile] = [.host, .systemd, .nginx, .disk],
        serviceName: String? = nil,
        maxTotalBytes: Int = 2_000_000,
        perCommandTimeoutMs: Int = 5_000,
        logLineLimit: Int = 300,
        privacyPreset: ServerDoctorPrivacyPreset = .balanced
    ) {
        self.connectionId = connectionId
        self.hostLabel = hostLabel
        self.scope = scope
        self.profiles = profiles
        self.serviceName = serviceName
        self.maxTotalBytes = maxTotalBytes
        self.perCommandTimeoutMs = perCommandTimeoutMs
        self.logLineLimit = logLineLimit
        self.privacyPreset = privacyPreset
    }
}

public struct ServerDoctorPlannedCommand: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var profile: ServerDoctorCollectorProfile
    public var displayName: String
    public var command: String

    public init(id: String, profile: ServerDoctorCollectorProfile, displayName: String, command: String) {
        self.id = id
        self.profile = profile
        self.displayName = displayName
        self.command = command
    }
}

public struct ServerDoctorCollectionPreview: Codable, Equatable, Sendable {
    public var request: ServerDoctorCollectionRequest
    public var plannedCommands: [ServerDoctorPlannedCommand]
    public var possibleFileSources: [String]
    public var notes: [String]

    public init(
        request: ServerDoctorCollectionRequest,
        plannedCommands: [ServerDoctorPlannedCommand],
        possibleFileSources: [String] = [],
        notes: [String] = []
    ) {
        self.request = request
        self.plannedCommands = plannedCommands
        self.possibleFileSources = possibleFileSources
        self.notes = notes
    }
}

public struct ServerDoctorCommandAudit: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var collectorId: String
    public var profile: ServerDoctorCollectorProfile
    public var displayName: String
    public var command: String
    public var startedAt: Date
    public var durationMs: Int
    public var exitStatus: Int?
    public var stdoutBytes: Int
    public var stderrBytes: Int
    public var truncated: Bool
    public var permissionLimited: Bool
    public var readOnlyRisk: String

    public init(
        id: String,
        collectorId: String,
        profile: ServerDoctorCollectorProfile,
        displayName: String,
        command: String,
        startedAt: Date,
        durationMs: Int,
        exitStatus: Int?,
        stdoutBytes: Int,
        stderrBytes: Int,
        truncated: Bool,
        permissionLimited: Bool,
        readOnlyRisk: String = "read_only"
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
        self.readOnlyRisk = readOnlyRisk
    }
}

public struct ServerDoctorEvidence: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ServerDoctorEvidenceKind
    public var title: String
    public var source: String
    public var collectedAt: Date
    public var risk: String
    public var exitStatus: Int?
    public var excerpt: String
    public var redactedExcerpt: String
    public var rawOutput: String
    public var rawRef: String
    public var byteCount: Int
    public var lineCount: Int
    public var truncated: Bool
    public var permissionLimited: Bool

    public init(
        id: String,
        kind: ServerDoctorEvidenceKind,
        title: String,
        source: String,
        collectedAt: Date,
        risk: String = "read_only",
        exitStatus: Int?,
        excerpt: String,
        redactedExcerpt: String? = nil,
        rawOutput: String,
        rawRef: String,
        byteCount: Int,
        lineCount: Int,
        truncated: Bool,
        permissionLimited: Bool
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.source = source
        self.collectedAt = collectedAt
        self.risk = risk
        self.exitStatus = exitStatus
        self.excerpt = excerpt
        self.redactedExcerpt = redactedExcerpt ?? excerpt
        self.rawOutput = rawOutput
        self.rawRef = rawRef
        self.byteCount = byteCount
        self.lineCount = lineCount
        self.truncated = truncated
        self.permissionLimited = permissionLimited
    }
}

public struct ServerDoctorWarning: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }
}

public struct ServerDoctorCollectionBundle: Codable, Equatable, Sendable {
    public var id: String
    public var hostLabel: String
    public var collectedAt: Date
    public var profiles: [ServerDoctorCollectorProfile]
    public var commandAudits: [ServerDoctorCommandAudit]
    public var evidence: [ServerDoctorEvidence]
    public var warnings: [ServerDoctorWarning]

    public init(
        id: String,
        hostLabel: String,
        collectedAt: Date = Date(),
        profiles: [ServerDoctorCollectorProfile],
        commandAudits: [ServerDoctorCommandAudit],
        evidence: [ServerDoctorEvidence],
        warnings: [ServerDoctorWarning] = []
    ) {
        self.id = id
        self.hostLabel = hostLabel
        self.collectedAt = collectedAt
        self.profiles = profiles
        self.commandAudits = commandAudits
        self.evidence = evidence
        self.warnings = warnings
    }
}

public struct ServerDoctorSuggestedAction: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ServerDoctorSuggestedActionKind
    public var title: String
    public var target: String?

    public init(
        id: String = UUID().uuidString,
        kind: ServerDoctorSuggestedActionKind,
        title: String,
        target: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.target = target
    }
}

public struct ServerDoctorFinding: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var severity: ServerDoctorSeverity
    public var confidence: ServerDoctorConfidence
    public var affectedSubsystem: String
    public var affectedService: String?
    public var evidenceIds: [String]
    public var safeNextSteps: [ServerDoctorSuggestedAction]
    public var unsafeActionsToAvoid: [String]
    public var explanation: String

    public init(
        id: String = UUID().uuidString,
        title: String,
        summary: String,
        severity: ServerDoctorSeverity,
        confidence: ServerDoctorConfidence,
        affectedSubsystem: String,
        affectedService: String? = nil,
        evidenceIds: [String],
        safeNextSteps: [ServerDoctorSuggestedAction] = [],
        unsafeActionsToAvoid: [String] = [],
        explanation: String = ""
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.severity = severity
        self.confidence = confidence
        self.affectedSubsystem = affectedSubsystem
        self.affectedService = affectedService
        self.evidenceIds = evidenceIds
        self.safeNextSteps = safeNextSteps
        self.unsafeActionsToAvoid = unsafeActionsToAvoid
        self.explanation = explanation
    }
}

public struct ServerDoctorProviderMetadata: Codable, Equatable, Sendable {
    public var providerName: String
    public var modelName: String
    public var externalCall: Bool

    public init(providerName: String, modelName: String = "heuristic", externalCall: Bool = false) {
        self.providerName = providerName
        self.modelName = modelName
        self.externalCall = externalCall
    }

    public static let localHeuristics = ServerDoctorProviderMetadata(providerName: "Local Heuristics")
}

public struct ServerDoctorRedactionSummary: Codable, Equatable, Sendable {
    public var preset: ServerDoctorPrivacyPreset
    public var replacementCount: Int
    public var categories: [String: Int]

    public init(
        preset: ServerDoctorPrivacyPreset,
        replacementCount: Int = 0,
        categories: [String: Int] = [:]
    ) {
        self.preset = preset
        self.replacementCount = replacementCount
        self.categories = categories
    }
}

public struct ServerDoctorReport: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var hostLabel: String
    public var reportTitle: String
    public var summary: String
    public var overallSeverity: ServerDoctorSeverity
    public var overallConfidence: ServerDoctorConfidence
    public var collectedAt: Date
    public var generatedAt: Date
    public var findings: [ServerDoctorFinding]
    public var questionsToResolve: [String]
    public var suggestedReadOnlyFollowups: [ServerDoctorSuggestedAction]
    public var provider: ServerDoctorProviderMetadata
    public var redaction: ServerDoctorRedactionSummary

    public init(
        id: String = UUID().uuidString,
        hostLabel: String,
        reportTitle: String,
        summary: String,
        overallSeverity: ServerDoctorSeverity,
        overallConfidence: ServerDoctorConfidence,
        collectedAt: Date,
        generatedAt: Date = Date(),
        findings: [ServerDoctorFinding],
        questionsToResolve: [String] = [],
        suggestedReadOnlyFollowups: [ServerDoctorSuggestedAction] = [],
        provider: ServerDoctorProviderMetadata = .localHeuristics,
        redaction: ServerDoctorRedactionSummary
    ) {
        self.id = id
        self.hostLabel = hostLabel
        self.reportTitle = reportTitle
        self.summary = summary
        self.overallSeverity = overallSeverity
        self.overallConfidence = overallConfidence
        self.collectedAt = collectedAt
        self.generatedAt = generatedAt
        self.findings = findings
        self.questionsToResolve = questionsToResolve
        self.suggestedReadOnlyFollowups = suggestedReadOnlyFollowups
        self.provider = provider
        self.redaction = redaction
    }
}

public struct ServerDoctorReportValidationResult: Codable, Equatable, Sendable {
    public var isValid: Bool
    public var errors: [String]

    public init(isValid: Bool, errors: [String] = []) {
        self.isValid = isValid
        self.errors = errors
    }
}
