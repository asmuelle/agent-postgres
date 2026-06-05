import Foundation

public struct WidgetMonitorDisplayItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var kind: WidgetMonitorKind
    public var state: WidgetMonitorState
    public var summary: String
    public var detail: String?
    public var lastCheckedText: String
    public var lastCheckedAt: Date?
    public var openURL: String?

    public init(
        id: String,
        displayName: String,
        kind: WidgetMonitorKind,
        state: WidgetMonitorState,
        summary: String,
        detail: String?,
        lastCheckedText: String,
        lastCheckedAt: Date?,
        openURL: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.state = state
        self.summary = summary
        self.detail = detail
        self.lastCheckedText = lastCheckedText
        self.lastCheckedAt = lastCheckedAt
        self.openURL = openURL
    }
}

public struct WidgetMonitoringDisplayGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var items: [WidgetMonitorDisplayItem]

    public init(id: String, title: String, items: [WidgetMonitorDisplayItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

public struct WidgetMonitoringDisplayModel: Equatable, Sendable {
    public var generatedAt: Date
    public var overallState: WidgetMonitorState
    public var items: [WidgetMonitorDisplayItem]
    public var groups: [WidgetMonitoringDisplayGroup]
    public var lastCheckedText: String
    public var downCount: Int
    public var degradedCount: Int
    public var staleCount: Int
    public var unknownCount: Int
    public var pausedCount: Int
    public var openURL: String

    public init(
        generatedAt: Date,
        overallState: WidgetMonitorState,
        items: [WidgetMonitorDisplayItem],
        groups: [WidgetMonitoringDisplayGroup],
        lastCheckedText: String,
        downCount: Int,
        degradedCount: Int,
        staleCount: Int,
        unknownCount: Int,
        pausedCount: Int,
        openURL: String
    ) {
        self.generatedAt = generatedAt
        self.overallState = overallState
        self.items = items
        self.groups = groups
        self.lastCheckedText = lastCheckedText
        self.downCount = downCount
        self.degradedCount = degradedCount
        self.staleCount = staleCount
        self.unknownCount = unknownCount
        self.pausedCount = pausedCount
        self.openURL = openURL
    }
}

public enum WidgetSnapshotPresenter {
    public static let monitoringOverviewURL = "pgAgent://monitoring"

    public static func displayModel(
        snapshotFile: WidgetMonitorSnapshotFile?,
        now: Date = Date(),
        policy: WidgetSnapshotFreshnessPolicy = .default,
        preferences: WidgetMonitoringPreferences = .default,
        itemLimit: Int? = nil
    ) -> WidgetMonitoringDisplayModel {
        let sourceSnapshots = snapshotFile?.snapshots ?? []
        let filteredSnapshots = preferences.filteredSnapshots(sourceSnapshots)
        let snapshots: [WidgetMonitorSnapshot]
        if sourceSnapshots.isEmpty {
            snapshots = [.placeholder(now: now)]
        } else if filteredSnapshots.isEmpty {
            snapshots = [.filteredPlaceholder(now: now)]
        } else {
            snapshots = filteredSnapshots
        }
        let sorted = snapshots.sortedForWidgetDisplay(now: now, policy: policy)
        let limited = itemLimit.map { Array(sorted.prefix(max(0, $0))) } ?? sorted

        let items = limited.map { snapshot in
            let displayState = snapshot.displayState(now: now, policy: policy)
            return WidgetMonitorDisplayItem(
                id: snapshot.id,
                displayName: snapshot.displayName,
                kind: snapshot.kind,
                state: displayState,
                summary: summary(for: snapshot, displayState: displayState),
                detail: snapshot.detail,
                lastCheckedText: lastCheckedText(
                    lastCheckedAt: snapshot.lastCheckedAt,
                    displayState: displayState,
                    now: now
                ),
                lastCheckedAt: snapshot.lastCheckedAt,
                openURL: snapshot.openURL
            )
        }
        let groups = groupedDisplayItems(items)

        let allStates = sorted.map { $0.displayState(now: now, policy: policy) }
        let overallState = WidgetSnapshotReducer.overallState(
            for: snapshots,
            now: now,
            policy: policy
        )
        let newestCheck = sorted.compactMap(\.lastCheckedAt).max()
        let firstURL = sorted.compactMap(\.openURL).first

        return WidgetMonitoringDisplayModel(
            generatedAt: snapshotFile?.generatedAt ?? now,
            overallState: overallState,
            items: items,
            groups: groups,
            lastCheckedText: lastCheckedText(
                lastCheckedAt: newestCheck,
                displayState: overallState,
                now: now
            ),
            downCount: allStates.filter { $0 == .down }.count,
            degradedCount: allStates.filter { $0 == .degraded }.count,
            staleCount: allStates.filter { $0 == .stale }.count,
            unknownCount: allStates.filter { $0 == .unknown }.count,
            pausedCount: allStates.filter { $0 == .paused }.count,
            openURL: firstURL ?? monitoringOverviewURL
        )
    }

    public static func lastCheckedText(
        lastCheckedAt: Date?,
        displayState: WidgetMonitorState,
        now: Date = Date()
    ) -> String {
        guard let lastCheckedAt else { return "Not checked yet" }
        let ageText = relativeAgeText(from: lastCheckedAt, to: now)
        if displayState == .stale {
            return "Stale: checked \(ageText)"
        }
        return "Last checked \(ageText)"
    }

    private static func summary(
        for snapshot: WidgetMonitorSnapshot,
        displayState: WidgetMonitorState
    ) -> String {
        if displayState == .stale, snapshot.state != .stale {
            return "Was \(snapshot.state.rawValue)"
        }
        return snapshot.summary
    }

    private static func relativeAgeText(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "less than 1 min ago"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) min ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours) hr ago"
        }

        let days = hours / 24
        return "\(days) d ago"
    }

    private static func groupedDisplayItems(_ items: [WidgetMonitorDisplayItem]) -> [WidgetMonitoringDisplayGroup] {
        WidgetMonitorKind.widgetGroupOrder.compactMap { kind in
            let groupedItems = items.filter { $0.kind == kind }
            guard !groupedItems.isEmpty else { return nil }
            return WidgetMonitoringDisplayGroup(
                id: kind.rawValue,
                title: kind.widgetGroupTitle,
                items: groupedItems
            )
        }
    }
}

private extension Array where Element == WidgetMonitorSnapshot {
    func sortedForWidgetDisplay(
        now: Date,
        policy: WidgetSnapshotFreshnessPolicy
    ) -> [WidgetMonitorSnapshot] {
        sorted { lhs, rhs in
            let lhsState = lhs.displayState(now: now, policy: policy)
            let rhsState = rhs.displayState(now: now, policy: policy)
            let lhsRank = lhsState.widgetSeverityRank
            let rhsRank = rhsState.widgetSeverityRank
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }

            switch (lhs.lastCheckedAt, rhs.lastCheckedAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
    }
}

private extension WidgetMonitorState {
    var widgetSeverityRank: Int {
        switch self {
        case .down: return 0
        case .degraded: return 1
        case .stale: return 2
        case .unknown: return 3
        case .paused: return 4
        case .up: return 5
        }
    }
}

private extension WidgetMonitorKind {
    static let widgetGroupOrder: [WidgetMonitorKind] = [
        .host,
        .sftp,
        .tunnel,
        .postgres,
        .port,
        .custom,
    ]

    var widgetGroupTitle: String {
        switch self {
        case .host:
            return "Hosts"
        case .sftp:
            return "File Sessions"
        case .tunnel:
            return "Tunnels"
        case .postgres:
            return "Databases"
        case .port:
            return "Ports"
        case .custom:
            return "Services"
        }
    }
}
