import Foundation

public enum MonitoringAlertDeliverySource: String, Codable, Equatable, Sendable {
    case macOSApp = "macos-app"
    case iOSApp = "ios-app"
    case watchOSApp = "watchos-app"
    case pushGateway = "push-gateway"
}

public enum MonitoringAlertDeliverySeverity: String, Codable, Equatable, Sendable {
    case failure
    case warning
    case informational
}

public struct MonitoringAlertDeliveryPayload: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var severity: MonitoringAlertDeliverySeverity
    public var source: MonitoringAlertDeliverySource
    public var ruleId: String
    public var snapshotId: String
    public var occurredAt: Date
    public var checkedAt: Date?
    public var openURL: String?

    public init(
        id: String,
        title: String,
        body: String,
        severity: MonitoringAlertDeliverySeverity,
        source: MonitoringAlertDeliverySource,
        ruleId: String,
        snapshotId: String,
        occurredAt: Date = Date(),
        checkedAt: Date? = nil,
        openURL: String? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.severity = severity
        self.source = source
        self.ruleId = ruleId
        self.snapshotId = snapshotId
        self.occurredAt = occurredAt
        self.checkedAt = checkedAt
        self.openURL = openURL
    }

    public var notificationThreadIdentifier: String {
        "monitoring-alerts"
    }

    public var userInfo: [String: String] {
        var info = [
            Self.payloadKindKey: Self.payloadKind,
            Self.idKey: id,
            Self.titleKey: title,
            Self.bodyKey: body,
            Self.severityKey: severity.rawValue,
            Self.sourceKey: source.rawValue,
            Self.ruleIdKey: ruleId,
            Self.snapshotIdKey: snapshotId,
            Self.occurredAtKey: Self.iso8601Formatter.string(from: occurredAt),
        ]
        if let checkedAt {
            info[Self.checkedAtKey] = Self.iso8601Formatter.string(from: checkedAt)
        }
        if let openURL {
            info[Self.openURLKey] = openURL
        }
        return info
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard userInfo[Self.payloadKindKey] as? String == Self.payloadKind,
              let id = userInfo[Self.idKey] as? String,
              let title = userInfo[Self.titleKey] as? String,
              let body = userInfo[Self.bodyKey] as? String,
              let severityRaw = userInfo[Self.severityKey] as? String,
              let severity = MonitoringAlertDeliverySeverity(rawValue: severityRaw),
              let sourceRaw = userInfo[Self.sourceKey] as? String,
              let source = MonitoringAlertDeliverySource(rawValue: sourceRaw),
              let ruleId = userInfo[Self.ruleIdKey] as? String,
              let snapshotId = userInfo[Self.snapshotIdKey] as? String,
              let occurredAtRaw = userInfo[Self.occurredAtKey] as? String,
              let occurredAt = Self.iso8601Formatter.date(from: occurredAtRaw)
        else { return nil }

        let checkedAt = (userInfo[Self.checkedAtKey] as? String)
            .flatMap(Self.iso8601Formatter.date(from:))

        self.init(
            id: id,
            title: title,
            body: body,
            severity: severity,
            source: source,
            ruleId: ruleId,
            snapshotId: snapshotId,
            occurredAt: occurredAt,
            checkedAt: checkedAt,
            openURL: userInfo[Self.openURLKey] as? String
        )
    }

    private static let payloadKind = "monitoring-alert"
    private static let payloadKindKey = "msshPayloadKind"
    private static let idKey = "msshAlertId"
    private static let titleKey = "msshAlertTitle"
    private static let bodyKey = "msshAlertBody"
    private static let severityKey = "msshAlertSeverity"
    private static let sourceKey = "msshAlertSource"
    private static let ruleIdKey = "msshAlertRuleId"
    private static let snapshotIdKey = "msshAlertSnapshotId"
    private static let occurredAtKey = "msshAlertOccurredAt"
    private static let checkedAtKey = "msshAlertCheckedAt"
    public static let openURLKey = "msshAlertOpenURL"

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
