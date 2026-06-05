import Foundation

public enum WatchStatusSnapshotConfiguration {
    public static let fileName = SharedAppStorageConfiguration.watchStatusSnapshotFileName
    public static let schemaVersion = 1
    public static let itemLimit = 10
}

public enum WatchStatusItemKind: String, Codable, CaseIterable, Hashable, Sendable {
    case monitor
    case operation
}

public enum WatchStatusItemState: String, Codable, CaseIterable, Hashable, Sendable {
    case ok
    case warning
    case critical
    case paused
    case running
    case waiting
    case completed
    case failed
    case stale
    case unknown
}

public struct WatchStatusItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: WatchStatusItemKind
    public var title: String
    public var subtitle: String?
    public var state: WatchStatusItemState
    public var updatedAt: Date?
    public var openURL: String?

    public init(
        id: String,
        kind: WatchStatusItemKind,
        title: String,
        subtitle: String? = nil,
        state: WatchStatusItemState,
        updatedAt: Date? = nil,
        openURL: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).watchFallback("Midnight SSH")
        self.subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).watchNilIfBlank
        self.state = state
        self.updatedAt = updatedAt
        self.openURL = openURL?.trimmingCharacters(in: .whitespacesAndNewlines).watchNilIfBlank
    }
}

public enum WatchQuickActionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case openInApp
    case reconnect
    case stopTunnel
    case approveOperation
}

public enum WatchQuickActionPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case opensApp
    case requiresConfirmation
    case requiresBiometricApproval
}

public struct WatchQuickActionRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: WatchQuickActionKind
    public var title: String
    public var targetId: String
    public var profileId: String?
    public var policy: WatchQuickActionPolicy
    public var openURL: String?

    public init(
        id: String,
        kind: WatchQuickActionKind,
        title: String,
        targetId: String,
        profileId: String? = nil,
        policy: WatchQuickActionPolicy,
        openURL: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).watchFallback("Open")
        self.targetId = targetId
        self.profileId = profileId?.watchNilIfBlank
        self.policy = policy
        self.openURL = openURL?.watchNilIfBlank
    }
}

public struct WatchStatusSnapshotFile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var summary: String
    public var items: [WatchStatusItem]
    public var guardedQuickActions: [WatchQuickActionRecord]

    public static let empty = WatchStatusSnapshotFile(
        summary: "No recent status",
        items: [],
        guardedQuickActions: []
    )

    public init(
        schemaVersion: Int = WatchStatusSnapshotConfiguration.schemaVersion,
        generatedAt: Date = Date(),
        summary: String,
        items: [WatchStatusItem],
        guardedQuickActions: [WatchQuickActionRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.summary = summary
        self.items = items
        self.guardedQuickActions = guardedQuickActions
    }
}

public final class WatchStatusSnapshotStore: @unchecked Sendable {
    private let store: SharedJSONFileStore<WatchStatusSnapshotFile>
    private let directoryURL: URL?

    public init(
        fileName: String = WatchStatusSnapshotConfiguration.fileName,
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.store = SharedJSONFileStore(
            fileName: fileName,
            fileManager: fileManager,
            directoryURL: directoryURL
        )
    }

    public func load() throws -> WatchStatusSnapshotFile {
        try store.load(default: .empty)
    }

    public func save(_ snapshotFile: WatchStatusSnapshotFile) throws {
        try store.save(snapshotFile)
    }

    public func refresh(
        monitoringSnapshotFile: WidgetMonitorSnapshotFile? = nil,
        liveActivitySnapshotFile: LiveActivitySnapshotFile? = nil,
        now: Date = Date()
    ) throws {
        let monitoring = try monitoringSnapshotFile ?? WidgetSnapshotStore(directoryURL: directoryURL).loadSnapshotFile()
        let liveActivities = try liveActivitySnapshotFile ?? LiveActivitySnapshotStore(directoryURL: directoryURL).load()
        try save(
            WatchStatusSnapshotBuilder.snapshot(
                monitoringSnapshotFile: monitoring,
                liveActivitySnapshotFile: liveActivities,
                now: now
            )
        )
    }
}

public enum WatchStatusSnapshotBuilder {
    public static func snapshot(
        monitoringSnapshotFile: WidgetMonitorSnapshotFile?,
        liveActivitySnapshotFile: LiveActivitySnapshotFile?,
        now: Date = Date()
    ) -> WatchStatusSnapshotFile {
        let monitorItems = monitorItems(from: monitoringSnapshotFile, now: now)
        let operationItems = operationItems(from: liveActivitySnapshotFile)
        let items = Array((operationItems + monitorItems).prefix(WatchStatusSnapshotConfiguration.itemLimit))
        let actions = guardedQuickActions(
            monitoringSnapshotFile: monitoringSnapshotFile,
            liveActivitySnapshotFile: liveActivitySnapshotFile
        )

        return WatchStatusSnapshotFile(
            generatedAt: now,
            summary: summary(for: items),
            items: items,
            guardedQuickActions: actions
        )
    }

    private static func monitorItems(
        from snapshotFile: WidgetMonitorSnapshotFile?,
        now: Date
    ) -> [WatchStatusItem] {
        let snapshots = snapshotFile?.snapshots ?? []
        return snapshots
            .sorted { lhs, rhs in
                let lhsState = lhs.displayState(now: now)
                let rhsState = rhs.displayState(now: now)
                if lhsState.watchSeverityRank != rhsState.watchSeverityRank {
                    return lhsState.watchSeverityRank < rhsState.watchSeverityRank
                }
                return (lhs.lastCheckedAt ?? .distantPast) > (rhs.lastCheckedAt ?? .distantPast)
            }
            .map { snapshot in
                WatchStatusItem(
                    id: "monitor:\(snapshot.id)",
                    kind: .monitor,
                    title: snapshot.displayName,
                    subtitle: snapshot.summary,
                    state: WatchStatusItemState(snapshot.displayState(now: now)),
                    updatedAt: snapshot.lastCheckedAt ?? snapshot.lastChangedAt,
                    openURL: snapshot.openURL
                )
            }
    }

    private static func operationItems(
        from snapshotFile: LiveActivitySnapshotFile?
    ) -> [WatchStatusItem] {
        (snapshotFile?.snapshots ?? [])
            .sorted {
                if $0.isActive != $1.isActive {
                    return $0.isActive && !$1.isActive
                }
                return $0.updatedAt > $1.updatedAt
            }
            .map { snapshot in
                WatchStatusItem(
                    id: "operation:\(snapshot.id)",
                    kind: .operation,
                    title: snapshot.title,
                    subtitle: operationSubtitle(snapshot),
                    state: WatchStatusItemState(snapshot.state),
                    updatedAt: snapshot.updatedAt,
                    openURL: snapshot.openURL
                )
            }
    }

    private static func guardedQuickActions(
        monitoringSnapshotFile: WidgetMonitorSnapshotFile?,
        liveActivitySnapshotFile: LiveActivitySnapshotFile?
    ) -> [WatchQuickActionRecord] {
        var actions: [WatchQuickActionRecord] = []

        for snapshot in liveActivitySnapshotFile?.snapshots ?? [] {
            if snapshot.state == .waitingForApproval {
                actions.append(
                    WatchQuickActionRecord(
                        id: "approve:\(snapshot.id)",
                        kind: .approveOperation,
                        title: "Approve \(snapshot.title)",
                        targetId: snapshot.id,
                        profileId: snapshot.profileId,
                        policy: .requiresBiometricApproval,
                        openURL: snapshot.openURL
                    )
                )
            } else if snapshot.kind == .tunnel, snapshot.state == .running {
                actions.append(
                    WatchQuickActionRecord(
                        id: "stop:\(snapshot.id)",
                        kind: .stopTunnel,
                        title: "Stop \(snapshot.title)",
                        targetId: snapshot.id,
                        profileId: snapshot.profileId,
                        policy: .requiresConfirmation,
                        openURL: snapshot.openURL
                    )
                )
            }
        }

        for snapshot in monitoringSnapshotFile?.snapshots ?? [] where snapshot.state.isConfirmedFailure {
            actions.append(
                WatchQuickActionRecord(
                    id: "open:\(snapshot.id)",
                    kind: .openInApp,
                    title: "Open \(snapshot.displayName)",
                    targetId: snapshot.id,
                    policy: .opensApp,
                    openURL: snapshot.openURL
                )
            )
        }

        return Array(actions.prefix(WatchStatusSnapshotConfiguration.itemLimit))
    }

    private static func summary(for items: [WatchStatusItem]) -> String {
        let critical = items.filter { $0.state == .critical || $0.state == .failed }.count
        if critical > 0 {
            return "\(critical) needs attention"
        }

        let running = items.filter { $0.state == .running || $0.state == .waiting }.count
        if running > 0 {
            return "\(running) active"
        }

        let warning = items.filter { $0.state == .warning || $0.state == .stale }.count
        if warning > 0 {
            return "\(warning) warning"
        }

        return items.isEmpty ? "No recent status" : "All quiet"
    }

    private static func operationSubtitle(_ snapshot: LiveActivitySnapshot) -> String {
        if let progress = snapshot.progressPercentText {
            return [progress, snapshot.subtitle].compactMap { $0 }.joined(separator: " - ")
        }
        return snapshot.subtitle ?? LiveActivityPresenter.stateLabel(for: snapshot.state)
    }
}

private extension WatchStatusItemState {
    init(_ state: WidgetMonitorState) {
        switch state {
        case .up:
            self = .ok
        case .degraded:
            self = .warning
        case .down:
            self = .critical
        case .paused:
            self = .paused
        case .stale:
            self = .stale
        case .unknown:
            self = .unknown
        }
    }

    init(_ state: LiveActivityOperationState) {
        switch state {
        case .queued, .running:
            self = .running
        case .waitingForApproval:
            self = .waiting
        case .completed:
            self = .completed
        case .failed:
            self = .failed
        case .cancelled:
            self = .paused
        case .stale:
            self = .stale
        }
    }
}

private extension WidgetMonitorState {
    var watchSeverityRank: Int {
        switch self {
        case .down:
            return 0
        case .degraded:
            return 1
        case .stale:
            return 2
        case .unknown:
            return 3
        case .paused:
            return 4
        case .up:
            return 5
        }
    }
}

private extension String {
    var watchNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func watchFallback(_ value: String) -> String {
        isEmpty ? value : self
    }
}
