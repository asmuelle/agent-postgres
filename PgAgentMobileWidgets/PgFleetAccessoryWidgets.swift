import SwiftUI
import WidgetKit

// =============================================================================
// PgFleetAccessoryWidget — lock-screen / Apple Watch accessory families for
// Postgres fleet health. Reads the compact PgFleetWidgetSnapshot the app
// writes to the App Group container after every fleet refresh (see
// FleetHealthStore.publishWidgetSnapshot).
//   accessoryCircular    worst-severity gauge + instance count
//   accessoryRectangular top three instances with status dots
//   accessoryInline      one-line fleet summary
// =============================================================================

struct PgFleetAccessoryEntry: TimelineEntry {
    let date: Date
    let snapshot: PgFleetWidgetSnapshot?
    let isStale: Bool
}

struct PgFleetAccessoryTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PgFleetAccessoryEntry {
        PgFleetAccessoryEntry(date: Date(), snapshot: .placeholder, isStale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (PgFleetAccessoryEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : loadEntry(now: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PgFleetAccessoryEntry>) -> Void) {
        let now = Date()
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(15 * 60)
        completion(Timeline(entries: [loadEntry(now: now)], policy: .after(nextRefresh)))
    }

    private func loadEntry(now: Date) -> PgFleetAccessoryEntry {
        let snapshot = try? PgFleetWidgetSnapshotStore().load()
        return PgFleetAccessoryEntry(
            date: now,
            snapshot: snapshot,
            isStale: snapshot?.isStale(now: now) ?? false
        )
    }
}

struct PgFleetAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: PgFleetWidgetConfiguration.accessoryWidgetKind,
            provider: PgFleetAccessoryTimelineProvider()
        ) { entry in
            PgFleetAccessoryView(entry: entry)
                .widgetURL(URL(string: "pgAgent://fleet"))
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Postgres Fleet")
        .description("Fleet health at a glance on the Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct PgFleetAccessoryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PgFleetAccessoryEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            PgFleetRectangularView(entry: entry)
        case .accessoryInline:
            PgFleetInlineView(entry: entry)
        default:
            PgFleetCircularView(entry: entry)
        }
    }
}

// MARK: - Circular: worst-severity gauge + instance count

private struct PgFleetCircularView: View {
    let entry: PgFleetAccessoryEntry

    var body: some View {
        if let snapshot = entry.snapshot, !snapshot.instances.isEmpty {
            Gauge(value: healthyFraction(snapshot)) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.caption2)
            } currentValueLabel: {
                VStack(spacing: 0) {
                    Text("\(snapshot.instances.count)")
                        .font(.headline.monospacedDigit())
                    Text(entry.isStale ? "stale" : snapshot.worstStatus.shortLabel)
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .gaugeStyle(.accessoryCircular)
            .tint(entry.isStale ? .gray : snapshot.worstStatus.statusColor)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: "cylinder.split.1x2")
                        .font(.caption)
                    Text("—")
                        .font(.caption2.weight(.semibold))
                }
            }
        }
    }

    private func healthyFraction(_ snapshot: PgFleetWidgetSnapshot) -> Double {
        guard !snapshot.instances.isEmpty else { return 0 }
        let ok = snapshot.instances.count - snapshot.problemCount
        return Double(ok) / Double(snapshot.instances.count)
    }
}

// MARK: - Rectangular: top instances with status dots

private struct PgFleetRectangularView: View {
    let entry: PgFleetAccessoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.caption2)
                Text("Postgres Fleet")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                if entry.isStale {
                    Text("· stale")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if let snapshot = entry.snapshot, !snapshot.instances.isEmpty {
                ForEach(snapshot.rankedInstances.prefix(3)) { instance in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(entry.isStale ? Color.gray : instance.status.statusColor)
                            .frame(width: 5, height: 5)
                        Text(instance.name)
                            .font(.caption2)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(instance.statusDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("Open pgAgent to sync")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Inline: one-line summary

private struct PgFleetInlineView: View {
    let entry: PgFleetAccessoryEntry

    var body: some View {
        if let snapshot = entry.snapshot, !snapshot.instances.isEmpty {
            let count = snapshot.instances.count
            if entry.isStale {
                Text("\(Image(systemName: "cylinder.split.1x2")) Fleet stale")
            } else if snapshot.problemCount == 0 {
                Text("\(Image(systemName: "checkmark.circle")) \(count) instance\(count == 1 ? "" : "s") healthy")
            } else {
                Text("\(Image(systemName: snapshot.worstStatus.statusSymbol)) \(snapshot.problemCount) of \(count) need attention")
            }
        } else {
            Text("\(Image(systemName: "cylinder.split.1x2")) No fleet data")
        }
    }
}

// MARK: - Presentation helpers

private extension PgFleetInstanceStatus {
    var shortLabel: String {
        switch self {
        case .offline: return "down"
        case .blocked: return "blkd"
        case .slow: return "slow"
        case .busy: return "busy"
        case .healthy: return "ok"
        }
    }

    var statusColor: Color {
        switch self {
        case .offline: return .red
        case .blocked: return .orange
        case .slow: return .yellow
        case .busy: return .cyan
        case .healthy: return .green
        }
    }

    var statusSymbol: String {
        switch self {
        case .offline: return "xmark.octagon"
        case .blocked: return "lock.trianglebadge.exclamationmark"
        case .slow: return "tortoise"
        case .busy: return "bolt"
        case .healthy: return "checkmark.circle"
        }
    }
}

private extension PgFleetWidgetInstance {
    /// Compact right-aligned annotation for the rectangular row.
    var statusDetail: String {
        switch status {
        case .offline: return "down"
        case .blocked: return "\(blockedLockCount) blkd"
        case .slow: return "\(longRunningCount) slow"
        case .busy: return "\(activeBackends) active"
        case .healthy: return "ok"
        }
    }
}

private extension PgFleetWidgetSnapshot {
    static let placeholder = PgFleetWidgetSnapshot(
        generatedAt: Date(),
        instances: [
            PgFleetWidgetInstance(
                profileId: "placeholder-1", name: "prod-primary", status: .healthy,
                activeBackends: 4, longRunningCount: 0, blockedLockCount: 0
            ),
            PgFleetWidgetInstance(
                profileId: "placeholder-2", name: "analytics", status: .slow,
                activeBackends: 7, longRunningCount: 2, blockedLockCount: 0
            ),
            PgFleetWidgetInstance(
                profileId: "placeholder-3", name: "staging", status: .healthy,
                activeBackends: 1, longRunningCount: 0, blockedLockCount: 0
            ),
        ]
    )
}
