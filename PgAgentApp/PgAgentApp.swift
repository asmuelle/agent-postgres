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

    var body: some Scene {
        Window("Agent Postgres", id: "main") {
            ContentView()
                .environmentObject(layoutManager)
                .environmentObject(entitlementsStore)
                .environmentObject(postgresStore)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    layoutManager.toggleSidebar()
                }
                .keyboardShortcut("b", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(entitlementsStore)
                .environmentObject(updateManager)
        }
    }
}
