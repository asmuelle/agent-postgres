import AppIntents
import SwiftUI
import WidgetKit

// =============================================================================
// PgFleetControl — "Database Health" for Control Center, the Lock Screen and
// the Action button: the fleet's state in two words, and one tap to Pulse.
// Reads the snapshot the app writes after every fleet refresh (the app
// reloads this control then); a missing or stale snapshot claims nothing.
// =============================================================================
struct PgFleetControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: PgFleetWidgetConfiguration.controlKind,
            provider: PgFleetControlProvider()
        ) { status in
            ControlWidgetButton(action: OpenPgAgentIntent(destination: .pulse)) {
                Label(status.title, systemImage: status.systemImage)
            }
        }
        .displayName("Database Health")
        .description("Your databases at a glance. Opens Pulse.")
    }
}

struct PgFleetControlProvider: ControlValueProvider {
    var previewValue: PgFleetControlStatus {
        PgFleetControlStatus(title: "All Healthy", systemImage: "checkmark.circle")
    }

    func currentValue() async throws -> PgFleetControlStatus {
        PgFleetControlStatus(snapshot: try? PgFleetWidgetSnapshotStore().load())
    }
}
