import SwiftUI

// =============================================================================
// MobileLibraryToolbar — the one toolbar for the connection library, shared by
// the iPhone connection list and the iPad sidebar. Two everyday actions stay
// visible (Fleet Monitor, New Connection); the once-in-a-while ones (imports,
// SSH keys, Pro) live behind a single "More" menu.
// =============================================================================

/// Library-level actions, owned by `MobileContentView` (which presents the
/// sheets) and handed to whichever surface renders the library.
struct MobileLibraryActions {
    var showMonitor: () -> Void
    var addConnection: () -> Void
    var importFromProvider: () -> Void
    var importCSV: () -> Void
    var showSSHKeys: () -> Void
    var showPro: () -> Void
}

struct MobileLibraryToolbar: ToolbarContent {
    let actions: MobileLibraryActions
    let isPro: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: actions.showMonitor) {
                Label("Fleet Monitor", systemImage: "waveform.path.ecg")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            // ⌘N lives in the menu bar (MobileKeyboardCommands) so it works
            // from any screen, not only while this toolbar is visible.
            Button(action: actions.addConnection) {
                Label("New Connection", systemImage: "plus")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section {
                    Button(action: actions.importFromProvider) {
                        Label("Add from Cloud Provider…", systemImage: "cloud")
                    }
                    Button(action: actions.importCSV) {
                        Label("Import CSV…", systemImage: "square.and.arrow.down")
                    }
                }
                Button(action: actions.showSSHKeys) {
                    Label("SSH Keys…", systemImage: "key.horizontal")
                }
                if !isPro {
                    Button(action: actions.showPro) {
                        Label("pgAgent Pro…", systemImage: "sparkles")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

/// Shown wherever the library is empty: the first-run moment is the only time
/// the import paths matter, so they get a button here instead of a toolbar slot.
struct MobileNoConnectionsView: View {
    let actions: MobileLibraryActions

    var body: some View {
        ContentUnavailableView {
            Label("No Connections", systemImage: "cylinder.split.1x2")
        } description: {
            Text("Add a Postgres database to get started.")
        } actions: {
            Button(action: actions.addConnection) {
                Text("New Connection").foregroundStyle(MidnightColors.onAccent)
            }
            .buttonStyle(.borderedProminent)
            Button("Add from Cloud Provider…", action: actions.importFromProvider)
        }
    }
}
