import Foundation

public struct WidgetMonitorAlertRule: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var isEnabled: Bool
    public var includedKinds: Set<WidgetMonitorKind>
    public var matchingStates: Set<WidgetMonitorState>
    public var minimumRepeatInterval: TimeInterval
    public var requiresCompletedCheck: Bool

    public init(
        id: String,
        displayName: String,
        isEnabled: Bool = true,
        includedKinds: Set<WidgetMonitorKind> = Set(WidgetMonitorKind.allCases),
        matchingStates: Set<WidgetMonitorState>,
        minimumRepeatInterval: TimeInterval = 15 * 60,
        requiresCompletedCheck: Bool = true
    ) {
        precondition(minimumRepeatInterval >= 0, "minimumRepeatInterval must be non-negative")
        self.id = id
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.includedKinds = includedKinds
        self.matchingStates = matchingStates
        self.minimumRepeatInterval = minimumRepeatInterval
        self.requiresCompletedCheck = requiresCompletedCheck
    }

    public static let confirmedFailures = WidgetMonitorAlertRule(
        id: "confirmed-failures",
        displayName: "Confirmed failures",
        matchingStates: [.down]
    )

    public func matches(
        _ snapshot: WidgetMonitorSnapshot,
        now: Date = Date(),
        freshnessPolicy: WidgetSnapshotFreshnessPolicy = .default
    ) -> Bool {
        guard isEnabled else { return false }
        guard includedKinds.contains(snapshot.kind) else { return false }
        guard !requiresCompletedCheck || snapshot.lastCheckedAt != nil else { return false }

        let displayState = snapshot.displayState(now: now, policy: freshnessPolicy)
        return matchingStates.contains(displayState)
    }
}

public struct WidgetMonitorAlertHistory: Codable, Equatable, Sendable {
    public var lastDeliveredAtByKey: [String: Date]

    public init(lastDeliveredAtByKey: [String: Date] = [:]) {
        self.lastDeliveredAtByKey = lastDeliveredAtByKey
    }

    public func lastDeliveredAt(ruleId: String, snapshotId: String) -> Date? {
        lastDeliveredAtByKey[Self.key(ruleId: ruleId, snapshotId: snapshotId)]
    }

    public mutating func record(ruleId: String, snapshotId: String, deliveredAt: Date) {
        lastDeliveredAtByKey[Self.key(ruleId: ruleId, snapshotId: snapshotId)] = deliveredAt
    }

    public static func key(ruleId: String, snapshotId: String) -> String {
        "\(ruleId)|\(snapshotId)"
    }
}

public struct WidgetMonitorAlertDecision: Identifiable, Equatable, Sendable {
    public var id: String { notificationIdentifier }
    public var ruleId: String
    public var snapshotId: String
    public var snapshot: WidgetMonitorSnapshot
    public var title: String
    public var body: String
    public var openURL: String?
    public var notificationIdentifier: String

    public init(
        ruleId: String,
        snapshot: WidgetMonitorSnapshot,
        title: String,
        body: String,
        openURL: String?,
        notificationIdentifier: String
    ) {
        self.ruleId = ruleId
        self.snapshotId = snapshot.id
        self.snapshot = snapshot
        self.title = title
        self.body = body
        self.openURL = openURL
        self.notificationIdentifier = notificationIdentifier
    }

    public func deliveryPayload(
        source: MonitoringAlertDeliverySource,
        occurredAt: Date = Date()
    ) -> MonitoringAlertDeliveryPayload {
        MonitoringAlertDeliveryPayload(
            id: notificationIdentifier,
            title: title,
            body: body,
            severity: .failure,
            source: source,
            ruleId: ruleId,
            snapshotId: snapshotId,
            occurredAt: occurredAt,
            checkedAt: snapshot.lastCheckedAt,
            openURL: openURL
        )
    }
}

public enum WidgetMonitorAlertEvaluator {
    public static func decisions(
        for snapshots: [WidgetMonitorSnapshot],
        previousSnapshots: [String: WidgetMonitorSnapshot],
        history: WidgetMonitorAlertHistory = WidgetMonitorAlertHistory(),
        rules: [WidgetMonitorAlertRule] = [.confirmedFailures],
        now: Date = Date(),
        freshnessPolicy: WidgetSnapshotFreshnessPolicy = .default
    ) -> [WidgetMonitorAlertDecision] {
        snapshots.flatMap { snapshot in
            rules.compactMap { rule in
                decision(
                    for: snapshot,
                    previousSnapshot: previousSnapshots[snapshot.id],
                    history: history,
                    rule: rule,
                    now: now,
                    freshnessPolicy: freshnessPolicy
                )
            }
        }
    }

    public static func decision(
        for snapshot: WidgetMonitorSnapshot,
        previousSnapshot: WidgetMonitorSnapshot?,
        history: WidgetMonitorAlertHistory = WidgetMonitorAlertHistory(),
        rule: WidgetMonitorAlertRule = .confirmedFailures,
        now: Date = Date(),
        freshnessPolicy: WidgetSnapshotFreshnessPolicy = .default
    ) -> WidgetMonitorAlertDecision? {
        guard rule.matches(snapshot, now: now, freshnessPolicy: freshnessPolicy) else { return nil }

        if let previousSnapshot,
           rule.matches(previousSnapshot, now: now, freshnessPolicy: freshnessPolicy) {
            return nil
        }

        if let lastDeliveredAt = history.lastDeliveredAt(ruleId: rule.id, snapshotId: snapshot.id),
           now.timeIntervalSince(lastDeliveredAt) < rule.minimumRepeatInterval {
            return nil
        }

        return WidgetMonitorAlertDecision(
            ruleId: rule.id,
            snapshot: snapshot,
            title: "\(snapshot.displayName) is down",
            body: alertBody(for: snapshot),
            openURL: snapshot.openURL ?? WidgetSnapshotPresenter.monitoringOverviewURL,
            notificationIdentifier: notificationIdentifier(ruleId: rule.id, snapshotId: snapshot.id, now: now)
        )
    }

    private static func alertBody(for snapshot: WidgetMonitorSnapshot) -> String {
        let trimmedDetail = snapshot.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedDetail, !trimmedDetail.isEmpty {
            return trimmedDetail
        }

        let trimmedSummary = snapshot.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            return trimmedSummary
        }

        return "A monitoring check confirmed a failure."
    }

    private static func notificationIdentifier(ruleId: String, snapshotId: String, now: Date) -> String {
        let timestamp = Int(now.timeIntervalSince1970)
        return "monitoring-alert.\(ruleId).\(snapshotId).\(timestamp)"
            .replacingOccurrences(of: " ", with: "-")
    }
}
