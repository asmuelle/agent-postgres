import AppKit
import SwiftUI
import PgAgentMacOS

@main
struct PgAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var layoutManager = LayoutManager()
    @StateObject private var entitlementsStore = EntitlementsStore.shared
    @StateObject private var postgresStore = PostgresProfileStore.shared
    @StateObject private var updateManager = UpdateManager.shared
    @StateObject private var monitorSettings = FleetMonitorSettings.shared
    @StateObject private var fleetHub = FleetMonitorHub.shared

    var body: some Scene {
        Window("Agent Postgres", id: "main") {
            ContentView()
                .environmentObject(layoutManager)
                .environmentObject(entitlementsStore)
                .environmentObject(postgresStore)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    // Resume hub mode if the user left it on last session.
                    FleetMonitorHub.shared.startIfEnabled()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    layoutManager.toggleSidebar()
                }
                .keyboardShortcut("b", modifiers: .command)

                Divider()

                // Menu-discoverable ⌘K entry; ContentView hosts the overlay
                // and listens for this event on the bus.
                Button("Command Palette…") {
                    PgAgentEventBus.shared.events.send(.showCommandPalette)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(entitlementsStore)
                .environmentObject(updateManager)
        }

        // Fleet health at a glance — only present while hub mode is on.
        // Dragging the item out of the menu bar flips the same setting off.
        // The binding must be equality-guarded: MenuBarExtra writes it during
        // view updates, and an unguarded @Published set re-publishes every
        // time, spinning an infinite "publishing during view updates" loop.
        MenuBarExtra(isInserted: hubModeBinding) {
            FleetHubMenuView()
        } label: {
            Image(systemName: fleetHub.menuBarSymbolName)
                .foregroundStyle(fleetHub.menuBarTint)
        }
    }

    private var hubModeBinding: Binding<Bool> {
        Binding(
            get: { monitorSettings.hubModeEnabled },
            set: { enabled in
                guard monitorSettings.hubModeEnabled != enabled else { return }
                monitorSettings.hubModeEnabled = enabled
                fleetHub.applyHubMode(enabled: enabled)
            }
        )
    }
}
