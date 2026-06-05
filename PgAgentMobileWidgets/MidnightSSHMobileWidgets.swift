import ActivityKit
import SwiftUI
import WidgetKit

struct MobileMonitoringTimelineEntry: TimelineEntry {
    let date: Date
    let model: WidgetMonitoringDisplayModel
}

struct MobileMonitoringTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> MobileMonitoringTimelineEntry {
        entry(now: Date(), snapshotFile: WidgetMonitorSnapshotFile(snapshots: [.placeholder()]))
    }

    func getSnapshot(in context: Context, completion: @escaping (MobileMonitoringTimelineEntry) -> Void) {
        completion(loadEntry(now: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MobileMonitoringTimelineEntry>) -> Void) {
        let now = Date()
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(15 * 60)
        completion(Timeline(entries: [loadEntry(now: now)], policy: .after(nextRefresh)))
    }

    private func loadEntry(now: Date) -> MobileMonitoringTimelineEntry {
        let snapshotFile = try? WidgetSnapshotStore().loadSnapshotFile()
        let preferences = (try? WidgetMonitoringPreferencesStore().loadPreferences()) ?? .default
        return entry(now: now, snapshotFile: snapshotFile, preferences: preferences)
    }

    private func entry(
        now: Date,
        snapshotFile: WidgetMonitorSnapshotFile?,
        preferences: WidgetMonitoringPreferences = .default
    ) -> MobileMonitoringTimelineEntry {
        MobileMonitoringTimelineEntry(
            date: now,
            model: WidgetSnapshotPresenter.displayModel(
                snapshotFile: snapshotFile,
                now: now,
                preferences: preferences
            )
        )
    }
}

struct MobileMonitoringWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MobileMonitoringTimelineEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                MediumMobileMonitoringWidgetView(model: entry.model)
            case .systemLarge:
                LargeMobileMonitoringWidgetView(model: entry.model)
            default:
                SmallMobileMonitoringWidgetView(model: entry.model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: entry.model.openURL))
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }
}

private struct SmallMobileMonitoringWidgetView: View {
    let model: WidgetMonitoringDisplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                stateIcon(model.overallState, size: 18)
                Text("Midnight SSH")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(model.overallState.mobileLabel)
                .font(.title3.weight(.semibold))
                .lineLimit(1)

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
            CountStrip(model: model)
            Text(model.lastCheckedText)
                .font(.caption2)
                .foregroundStyle(model.overallState == .stale ? .orange : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
    }

    private var summary: String {
        if model.downCount > 0 { return "\(model.downCount) down" }
        if model.degradedCount > 0 { return "\(model.degradedCount) degraded" }
        if model.staleCount > 0 { return "\(model.staleCount) stale" }
        if model.unknownCount > 0 { return "\(model.unknownCount) unknown" }
        return "All checks passing"
    }
}

private struct MediumMobileMonitoringWidgetView: View {
    let model: WidgetMonitoringDisplayModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                stateIcon(model.overallState, size: 18)
                Text(model.overallState.mobileLabel)
                    .font(.headline)
                    .lineLimit(1)
                CountStrip(model: model)
                Spacer(minLength: 0)
                Text(model.lastCheckedText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 104, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.items.prefix(4)) { item in
                    MonitorWidgetRow(item: item)
                }
            }
        }
        .padding(12)
    }
}

private struct LargeMobileMonitoringWidgetView: View {
    let model: WidgetMonitoringDisplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                stateIcon(model.overallState, size: 18)
                Text("Midnight SSH")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(model.overallState.mobileLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.overallState.mobileColor)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.items.prefix(8)) { item in
                    MonitorWidgetRow(item: item)
                }
            }

            Spacer(minLength: 0)
            HStack {
                CountStrip(model: model)
                Spacer(minLength: 0)
                Text(model.lastCheckedText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
    }
}

private struct MonitorWidgetRow: View {
    let item: WidgetMonitorDisplayItem

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            stateIcon(item.state, size: 12)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(item.state.mobileLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(item.state.mobileColor)
                        .lineLimit(1)
                }
                Text(item.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct CountStrip: View {
    let model: WidgetMonitoringDisplayModel

    var body: some View {
        HStack(spacing: 5) {
            if model.downCount > 0 {
                countPill(model.downCount, "down", .red)
            }
            if model.degradedCount > 0 {
                countPill(model.degradedCount, "warn", .yellow)
            }
            if model.staleCount > 0 {
                countPill(model.staleCount, "stale", .orange)
            }
            if model.unknownCount > 0 {
                countPill(model.unknownCount, "unknown", .gray)
            }
            if model.downCount == 0,
               model.degradedCount == 0,
               model.staleCount == 0,
               model.unknownCount == 0 {
                countPill(model.items.count, "up", .green)
            }
        }
    }

    private func countPill(_ value: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text("\(value) \(label)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct MidnightSSHMobileMonitoringWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetSnapshotConfiguration.iOSWidgetKind,
            provider: MobileMonitoringTimelineProvider()
        ) { entry in
            MobileMonitoringWidgetView(entry: entry)
        }
        .configurationDisplayName("Midnight SSH")
        .description("Shows recent monitoring checks.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct MidnightSSHOperationLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MidnightSSHOperationActivityAttributes.self) { context in
            OperationActivityView(context: context)
                .activityBackgroundTint(Color(.secondarySystemBackground))
                .activitySystemActionForegroundColor(.accentColor)
                .widgetURL(context.attributes.openURL.flatMap(URL.init(string:)))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.kind.mobileLabel, systemImage: context.attributes.kind.mobileSymbol)
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.state.mobileLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(context.state.state.mobileColor)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    OperationActivityContent(
                        title: context.attributes.title,
                        state: context.state
                    )
                }
            } compactLeading: {
                Image(systemName: context.attributes.kind.mobileSymbol)
                    .foregroundStyle(context.state.state.mobileColor)
            } compactTrailing: {
                Text(context.state.progress.map { "\(Int(($0 * 100).rounded()))" } ?? context.state.state.compactLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(context.state.state.mobileColor)
            } minimal: {
                Image(systemName: context.attributes.kind.mobileSymbol)
                    .foregroundStyle(context.state.state.mobileColor)
            }
            .widgetURL(context.attributes.openURL.flatMap(URL.init(string:)))
        }
    }
}

private struct OperationActivityView: View {
    let context: ActivityViewContext<MidnightSSHOperationActivityAttributes>

    var body: some View {
        OperationActivityContent(title: context.attributes.title, state: context.state)
            .padding(14)
    }
}

private struct OperationActivityContent: View {
    let title: String
    let state: MidnightSSHOperationActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: state.state.mobileSymbol)
                    .foregroundStyle(state.state.mobileColor)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(state.state.mobileLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.state.mobileColor)
            }

            if let subtitle = state.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let progress = state.progress {
                ProgressView(value: progress)
                    .tint(state.state.mobileColor)
            }
        }
    }
}

@main
struct MidnightSSHMobileWidgetBundle: WidgetBundle {
    var body: some Widget {
        MidnightSSHMobileMonitoringWidget()
        MidnightSSHOperationLiveActivityWidget()
    }
}

private func stateIcon(_ state: WidgetMonitorState, size: CGFloat) -> some View {
    Image(systemName: state.mobileSymbol)
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(state.mobileColor)
        .frame(width: size + 2, height: size + 2)
}

private extension WidgetMonitorState {
    var mobileLabel: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .degraded: return "Degraded"
        case .unknown: return "Unknown"
        case .stale: return "Stale"
        case .paused: return "Paused"
        }
    }

    var mobileSymbol: String {
        switch self {
        case .up: return "checkmark.circle.fill"
        case .down: return "xmark.octagon.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        case .stale: return "clock.badge.exclamationmark.fill"
        case .paused: return "pause.circle.fill"
        }
    }

    var mobileColor: Color {
        switch self {
        case .up: return .green
        case .down: return .red
        case .degraded: return .yellow
        case .unknown: return .gray
        case .stale: return .orange
        case .paused: return .secondary
        }
    }
}

private extension LiveActivityOperationKind {
    var mobileLabel: String {
        switch self {
        case .command: return "Command"
        case .transfer: return "Transfer"
        case .tunnel: return "Tunnel"
        case .offlineSync: return "Sync"
        case .shortcut: return "Shortcut"
        case .fileProvider: return "Files"
        case .shareUpload: return "Upload"
        case .other: return "Task"
        }
    }

    var mobileSymbol: String {
        switch self {
        case .command: return "terminal"
        case .transfer, .shareUpload: return "arrow.up.arrow.down"
        case .tunnel: return "point.3.connected.trianglepath.dotted"
        case .offlineSync: return "arrow.triangle.2.circlepath"
        case .shortcut: return "wand.and.stars"
        case .fileProvider: return "folder"
        case .other: return "circle"
        }
    }
}

private extension LiveActivityOperationState {
    var mobileLabel: String {
        LiveActivityPresenter.stateLabel(for: self)
    }

    var compactLabel: String {
        switch self {
        case .queued: return "Q"
        case .waitingForApproval: return "!"
        case .running: return "Run"
        case .completed: return "OK"
        case .failed: return "Err"
        case .cancelled: return "Stop"
        case .stale: return "Old"
        }
    }

    var mobileSymbol: String {
        switch self {
        case .queued: return "clock"
        case .waitingForApproval: return "lock.shield"
        case .running: return "bolt.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        case .stale: return "clock.badge.exclamationmark.fill"
        }
    }

    var mobileColor: Color {
        switch self {
        case .queued, .running: return .blue
        case .waitingForApproval: return .orange
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .stale: return .orange
        }
    }
}
