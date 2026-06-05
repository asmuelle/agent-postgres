import Foundation
import SwiftUI

enum ActivitySeverity: String, Codable, CaseIterable {
    case info
    case success
    case warning
    case critical

    var color: Color {
        switch self {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var label: String {
        switch self {
        case .info: return "Info"
        case .success: return "OK"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

struct ActivityLogEvent: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let profileId: String?
    let connectionId: String?
    let title: String
    let detail: String
    let icon: String
    let severity: ActivitySeverity
}

@MainActor
final class ActivityLogStore: ObservableObject {
    static let shared = ActivityLogStore()

    @Published private(set) var events: [ActivityLogEvent] = []

    private let maxEvents = 240

    private init() {}

    func record(
        title: String,
        detail: String,
        profileId: String? = nil,
        connectionId: String? = nil,
        icon: String = "circle",
        severity: ActivitySeverity = .info
    ) {
        let event = ActivityLogEvent(
            date: Date(),
            profileId: profileId,
            connectionId: connectionId,
            title: title,
            detail: detail,
            icon: icon,
            severity: severity
        )
        events.insert(event, at: 0)
        if events.count > maxEvents {
            events.removeLast(events.count - maxEvents)
        }
    }

    func recent(
        profileId: String?,
        connectionId: String?,
        limit: Int = 8
    ) -> [ActivityLogEvent] {
        events
            .filter { event in
                if let profileId, event.profileId == profileId { return true }
                if let connectionId, event.connectionId == connectionId { return true }
                return profileId == nil && connectionId == nil
            }
            .prefix(limit)
            .map { $0 }
    }

    func recentProblems(limit: Int = 6, after cutoffDate: Date? = nil) -> [ActivityLogEvent] {
        events
            .filter { event in
                guard event.severity == .warning || event.severity == .critical else {
                    return false
                }
                if let cutoffDate, event.date < cutoffDate {
                    return false
                }
                return true
            }
            .prefix(limit)
            .map { $0 }
    }
}

struct ActivityTimelineView: View {
    @ObservedObject private var store = ActivityLogStore.shared

    let profileId: String?
    let connectionId: String?
    var maxEvents = 8

    private var events: [ActivityLogEvent] {
        store.recent(profileId: profileId, connectionId: connectionId, limit: maxEvents)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Activity", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            if events.isEmpty {
                Text("No activity recorded for this server in this session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(events, id: \.id) { event in
                        ActivityTimelineRow(event: event)
                        if let last = events.last, event.id != last.id {
                            Divider()
                                .padding(.leading, 28)
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct ActivityTimelineRow: View {
    let event: ActivityLogEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.icon)
                .foregroundStyle(event.severity.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(event.date, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(8)
    }
}
