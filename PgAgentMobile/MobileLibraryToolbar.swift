import SwiftUI

// =============================================================================
// MobileLibraryToolbar — the Pulse toolbar: New Connection stays visible;
// the once-in-a-while actions (imports, SSH keys, alert settings, Pro) live
// behind a single "More" menu. Every action is a sheet request on the
// MobileAppModel, presented by MobileContentView.
// =============================================================================

struct MobileLibraryToolbar: ToolbarContent {
    let app: MobileAppModel
    let isPro: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // ⌘N lives in the menu bar (MobileKeyboardCommands) so it works
            // from any screen, not only while this toolbar is visible.
            Button {
                app.present(.newConnection)
            } label: {
                Label("New Connection", systemImage: "plus")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section {
                    Button {
                        app.present(.importFromProvider)
                    } label: {
                        Label("Add from Cloud Provider…", systemImage: "cloud")
                    }
                    Button {
                        app.present(.importCSV)
                    } label: {
                        Label("Import CSV…", systemImage: "square.and.arrow.down")
                    }
                }
                Section {
                    Button {
                        app.present(.sshKeys)
                    } label: {
                        Label("SSH Keys…", systemImage: "key.horizontal")
                    }
                    Button {
                        app.present(.alertSettings)
                    } label: {
                        Label("Alert Settings…", systemImage: "bell.badge")
                    }
                }
                if !isPro {
                    Button {
                        app.present(.pro)
                    } label: {
                        Label("pgAgent Pro…", systemImage: "sparkles")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

/// Shown wherever there are no connections yet: the first-run moment is the
/// only time the import paths matter, so they get a button here.
struct MobileNoConnectionsView: View {
    @Environment(MobileAppModel.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label("No Connections", systemImage: "cylinder.split.1x2")
        } description: {
            Text("Add a Postgres database to get started.")
        } actions: {
            Button {
                app.present(.newConnection)
            } label: {
                Text("New Connection").foregroundStyle(MidnightColors.onAccent)
            }
            .buttonStyle(.borderedProminent)
            Button("Add from Cloud Provider…") {
                app.present(.importFromProvider)
            }
        }
    }
}
