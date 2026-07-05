import ActivityKit
import SwiftUI
import WidgetKit

// =============================================================================
// PgOperationLiveActivityWidget — lock-screen banner + Dynamic Island for
// long-running Postgres operations (VACUUM, fixes, health checks), driven by
// PgOperationActivityAttributes (dual-target file in PgAgentMobile/).
// Visual language mirrors the existing mobile widgets: SF Symbols, caption
// typography, semantic status colors.
// =============================================================================

struct PgOperationLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PgOperationActivityAttributes.self) { context in
            PgOperationLockScreenView(context: context)
                .activityBackgroundTint(Color(.secondarySystemBackground))
                .activitySystemActionForegroundColor(.accentColor)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.operationKind, systemImage: context.attributes.operationSymbol)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.phase)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(context.state.statusColor)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PgOperationDetailContent(attributes: context.attributes, state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.attributes.operationSymbol)
                    .foregroundStyle(context.state.statusColor)
            } compactTrailing: {
                if let progress = context.state.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .tint(context.state.statusColor)
                } else if context.state.succeeded == nil {
                    Text(context.state.startedAt, style: .timer)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(context.state.statusColor)
                        .frame(maxWidth: 44)
                        .multilineTextAlignment(.trailing)
                } else {
                    Image(systemName: context.state.terminalSymbol)
                        .foregroundStyle(context.state.statusColor)
                }
            } minimal: {
                Image(systemName: context.attributes.operationSymbol)
                    .foregroundStyle(context.state.statusColor)
            }
        }
    }
}

private struct PgOperationLockScreenView: View {
    let context: ActivityViewContext<PgOperationActivityAttributes>

    var body: some View {
        PgOperationDetailContent(attributes: context.attributes, state: context.state)
            .padding(14)
    }
}

private struct PgOperationDetailContent: View {
    let attributes: PgOperationActivityAttributes
    let state: PgOperationActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: attributes.operationSymbol)
                    .foregroundStyle(state.statusColor)
                Text(attributes.operationKind)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if state.succeeded == nil {
                    // Live elapsed time while the operation runs.
                    Text(state.startedAt, style: .timer)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Text(state.phase)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.statusColor)
            }

            Text(targetLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let detail = state.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let progress = state.progress {
                ProgressView(value: progress)
                    .tint(state.statusColor)
            }
        }
    }

    private var targetLine: String {
        if let target = attributes.targetName {
            return "\(target) · \(attributes.instanceName)"
        }
        return attributes.instanceName
    }
}

private extension PgOperationActivityAttributes {
    var operationSymbol: String {
        let kind = operationKind.lowercased()
        if kind.contains("vacuum") { return "sparkles" }
        if kind.contains("fix") { return "wrench.and.screwdriver" }
        if kind.contains("health") { return "stethoscope" }
        return "cylinder.split.1x2"
    }
}

private extension PgOperationActivityAttributes.ContentState {
    var statusColor: Color {
        switch succeeded {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .cyan
        }
    }

    var terminalSymbol: String {
        succeeded == true ? "checkmark.circle.fill" : "xmark.octagon.fill"
    }
}
