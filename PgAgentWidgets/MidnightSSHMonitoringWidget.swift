import SwiftUI
import WidgetKit
import PgAgentMacOS

struct MonitoringTimelineEntry: TimelineEntry {
    let date: Date
    let model: WidgetMonitoringDisplayModel
}

struct MonitoringTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> MonitoringTimelineEntry {
        loadEntry(now: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (MonitoringTimelineEntry) -> Void) {
        completion(loadEntry(now: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MonitoringTimelineEntry>) -> Void) {
        let now = Date()
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 1, to: now) ?? now.addingTimeInterval(60)
        completion(Timeline(entries: [loadEntry(now: now)], policy: .after(nextRefresh)))
    }

    private func loadEntry(now: Date) -> MonitoringTimelineEntry {
        let snapshotFile: WidgetMonitorSnapshotFile?
        do {
            snapshotFile = try Self.loadSnapshotFile()
        } catch {
            snapshotFile = WidgetMonitorSnapshotFile(
                generatedAt: now,
                snapshots: [
                    WidgetMonitorSnapshot(
                        id: "widget-snapshot-store-error",
                        displayName: "Widget data",
                        kind: .custom,
                        state: .unknown,
                        lastCheckedAt: now,
                        lastChangedAt: now,
                        summary: Self.snapshotLoadErrorSummary(for: error),
                        detail: error.localizedDescription,
                        openURL: WidgetSnapshotPresenter.monitoringOverviewURL
                    )
                ]
            )
        }

        let preferences = (try? WidgetMonitoringPreferencesStore().loadPreferences()) ?? .default
        return entry(now: now, snapshotFile: snapshotFile, preferences: preferences)
    }

    private func entry(
        now: Date,
        snapshotFile: WidgetMonitorSnapshotFile?,
        preferences: WidgetMonitoringPreferences = .default
    ) -> MonitoringTimelineEntry {
        MonitoringTimelineEntry(
            date: now,
            model: WidgetSnapshotPresenter.displayModel(
                snapshotFile: snapshotFile,
                now: now,
                preferences: preferences
            )
        )
    }

    private static func loadSnapshotFile() throws -> WidgetMonitorSnapshotFile? {
        do {
            return try WidgetSnapshotStore().loadSnapshotFile()
        } catch {
            if let fallbackFile = try loadSnapshotFileFromMacOSGroupContainer() {
                return fallbackFile
            }
            throw error
        }
    }

    private static func loadSnapshotFileFromMacOSGroupContainer() throws -> WidgetMonitorSnapshotFile? {
        #if os(macOS)
        let directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Group Containers")
            .appendingPathComponent(WidgetSnapshotConfiguration.appGroupIdentifier)
        let store = WidgetSnapshotStore(directoryURL: directoryURL)
        return try store.loadSnapshotFile()
        #else
        return nil
        #endif
    }

    private static func snapshotLoadErrorSummary(for error: Error) -> String {
        if let storeError = error as? WidgetSnapshotStoreError {
            switch storeError {
            case .appGroupContainerUnavailable:
                return "App Group unavailable"
            }
        }
        return "Widget data unavailable"
    }
}

struct MonitoringWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MonitoringTimelineEntry

    @ViewBuilder
    var body: some View {
        if #available(macOS 14.0, *) {
            switch family {
            case .systemLarge:
                LargeMonitoringWidgetView(model: entry.model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .widgetURL(URL(string: entry.model.openURL))
                    .containerBackground(for: .widget) {
                        Color(nsColor: .windowBackgroundColor)
                    }
            case .systemMedium:
                MediumMonitoringWidgetView(model: entry.model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .widgetURL(URL(string: entry.model.openURL))
                    .containerBackground(for: .widget) {
                        Color(nsColor: .windowBackgroundColor)
                    }
            default:
                SmallMonitoringWidgetView(model: entry.model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .widgetURL(URL(string: entry.model.openURL))
                    .containerBackground(for: .widget) {
                        Color(nsColor: .windowBackgroundColor)
                    }
            }
        } else {
            switch family {
            case .systemLarge:
                LargeMonitoringWidgetView(model: entry.model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .widgetURL(URL(string: entry.model.openURL))
                    .background(Color(nsColor: .windowBackgroundColor))
            case .systemMedium:
                MediumMonitoringWidgetView(model: entry.model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .widgetURL(URL(string: entry.model.openURL))
                    .background(Color(nsColor: .windowBackgroundColor))
            default:
                SmallMonitoringWidgetView(model: entry.model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .widgetURL(URL(string: entry.model.openURL))
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }
}

private struct SmallMonitoringWidgetView: View {
    let model: WidgetMonitoringDisplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 6) {
                StatusGlyph(state: model.overallState, size: 18)
                Text("Midnight SSH")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if model.items.count > 1 {
                    Text("\(model.items.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.overallState.compactHeadline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(model.overallState == .up ? .primary : model.overallState.widgetColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(primarySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(model.items.prefix(2)) { item in
                    SmallMonitorRow(item: item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var primarySummary: String {
        if model.items.count == 1,
           let item = model.items.first,
           item.id == "widget-snapshot-store-error" {
            return item.detail ?? item.summary
        }
        if let firstProblem = model.items.first(where: { $0.state != .up && $0.state != .paused }) {
            return "\(firstProblem.displayName) \(firstProblem.state.shortAction)"
        }
        if !model.items.isEmpty {
            return "\(model.items.count) checks passing"
        }
        return "No checks configured"
    }
}

private struct SmallMonitorRow: View {
    let item: WidgetMonitorDisplayItem

    var body: some View {
        HStack(spacing: 6) {
            StatusGlyph(state: item.state, size: 10)

            Text(item.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Spacer(minLength: 4)

            Text(compactAge)
                .font(.caption2)
                .foregroundStyle(item.state == .up ? .secondary : item.state.widgetColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var compactAge: String {
        item.lastCheckedText
            .replacingOccurrences(of: "Last checked ", with: "")
            .replacingOccurrences(of: "Stale: checked ", with: "")
            .replacingOccurrences(of: "less than 1 min ago", with: "<1m")
            .replacingOccurrences(of: " min ago", with: "m")
            .replacingOccurrences(of: " hr ago", with: "h")
    }
}

private struct MediumMonitoringWidgetView: View {
    let model: WidgetMonitoringDisplayModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    StatusGlyph(state: model.overallState, size: 18)
                    Text(model.overallState.compactHeadline)
                        .font(.headline)
                        .foregroundStyle(model.overallState == .up ? .primary : model.overallState.widgetColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Text("Midnight SSH")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                StatusCountStrip(model: model)

                Spacer(minLength: 0)

                Text(model.lastCheckedText)
                    .font(.caption2)
                    .foregroundStyle(model.overallState == .stale ? .orange : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 112, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.items.prefix(4)) { item in
                    if let urlString = item.openURL,
                       let url = URL(string: urlString) {
                        Link(destination: url) {
                            MonitorRow(item: item)
                        }
                    } else {
                        MonitorRow(item: item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }
}

private struct MonitorRow: View {
    let item: WidgetMonitorDisplayItem

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            StatusGlyph(state: item.state, size: 12)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(item.state.widgetLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(item.state.widgetColor)
                        .lineLimit(1)
                }

                Text(rowDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(compactAge)
                .font(.caption2)
                .foregroundStyle(item.state == .up ? .secondary : item.state.widgetColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .contentShape(Rectangle())
    }

    private var rowDetail: String {
        if item.state == .down, let detail = item.detail, !detail.isEmpty {
            return detail
        }
        return item.summary
    }

    private var compactAge: String {
        item.lastCheckedText
            .replacingOccurrences(of: "Last checked ", with: "")
            .replacingOccurrences(of: "Stale: checked ", with: "")
            .replacingOccurrences(of: "less than 1 min ago", with: "<1m")
            .replacingOccurrences(of: " min ago", with: "m")
            .replacingOccurrences(of: " hr ago", with: "h")
    }
}

private struct LargeMonitoringWidgetView: View {
    let model: WidgetMonitoringDisplayModel

    private let columns = [
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        StatusGlyph(state: model.overallState, size: 18)
                        Text("Midnight SSH")
                            .font(.headline)
                            .lineLimit(1)
                    }

                    Text(model.overallState.widgetLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.overallState.widgetColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    StatusCountStrip(model: model)

                    Text(model.lastCheckedText)
                        .font(.caption2)
                        .foregroundStyle(model.overallState == .stale ? .orange : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            Divider()

            if model.groups.isEmpty {
                Spacer(minLength: 0)
                Text("Not checked yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(model.groups.prefix(4)) { group in
                        LargeGroupSection(group: group)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

private struct LargeGroupSection: View {
    let group: WidgetMonitoringDisplayGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(group.items.count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(group.items.prefix(3)) { item in
                    if let urlString = item.openURL,
                       let url = URL(string: urlString) {
                        Link(destination: url) {
                            LargeMonitorRow(item: item)
                        }
                    } else {
                        LargeMonitorRow(item: item)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct LargeMonitorRow: View {
    let item: WidgetMonitorDisplayItem

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            StatusGlyph(state: item.state, size: 10)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(item.state.widgetLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(item.state.widgetColor)
                        .lineLimit(1)
                }

                Text(rowDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(item.lastCheckedText)
                    .font(.caption2)
                    .foregroundStyle(item.state == .stale ? .orange : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .contentShape(Rectangle())
    }

    private var rowDetail: String {
        if item.state == .down, let detail = item.detail, !detail.isEmpty {
            return detail
        }
        return item.summary
    }
}

private struct StatusGlyph: View {
    let state: WidgetMonitorState
    let size: CGFloat

    var body: some View {
        Image(systemName: state.widgetSymbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(state.widgetColor)
            .frame(width: size + 2, height: size + 2)
    }
}

private struct StatusCountStrip: View {
    let model: WidgetMonitoringDisplayModel

    var body: some View {
        HStack(spacing: 5) {
            if model.downCount > 0 {
                CountPill(value: model.downCount, label: "down", color: .red)
            }
            if model.degradedCount > 0 {
                CountPill(value: model.degradedCount, label: "warn", color: .yellow)
            }
            if model.staleCount > 0 {
                CountPill(value: model.staleCount, label: "stale", color: .orange)
            }
            if model.unknownCount > 0 {
                CountPill(value: model.unknownCount, label: "unknown", color: .gray)
            }
            if model.downCount == 0,
               model.degradedCount == 0,
               model.staleCount == 0,
               model.unknownCount == 0 {
                CountPill(value: model.items.count, label: "up", color: .green)
            }
        }
    }
}

private struct CountPill: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
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

@main
struct MidnightSSHMonitoringWidget: Widget {
    private let kind = WidgetSnapshotConfiguration.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MonitoringTimelineProvider()) { entry in
            MonitoringWidgetView(entry: entry)
        }
        .configurationDisplayName("Midnight SSH")
        .description("Shows recent monitoring checks.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private extension WidgetMonitorState {
    var widgetLabel: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .degraded: return "Degraded"
        case .unknown: return "Unknown"
        case .stale: return "Stale"
        case .paused: return "Paused"
        }
    }

    var compactHeadline: String {
        switch self {
        case .up: return "All clear"
        case .down: return "Needs attention"
        case .degraded: return "Warning"
        case .unknown: return "Unknown"
        case .stale: return "Needs refresh"
        case .paused: return "Paused"
        }
    }

    var shortAction: String {
        switch self {
        case .up: return "is up"
        case .down: return "is down"
        case .degraded: return "needs review"
        case .unknown: return "is unknown"
        case .stale: return "needs refresh"
        case .paused: return "is paused"
        }
    }

    var widgetSymbol: String {
        switch self {
        case .up: return "checkmark.circle.fill"
        case .down: return "xmark.octagon.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        case .stale: return "clock.badge.exclamationmark.fill"
        case .paused: return "pause.circle.fill"
        }
    }

    var widgetColor: Color {
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
