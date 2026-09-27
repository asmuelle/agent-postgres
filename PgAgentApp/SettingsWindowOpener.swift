import AppKit
import SwiftUI

// =============================================================================
// SettingsWindowOpener — programmatic "open the Settings scene".
//
// macOS ignores the private `showSettingsWindow:` responder action (it logs
// "Please use SettingsLink for opening the Settings scene" and does nothing),
// so the only supported path is SwiftUI's `@Environment(\.openSettings)`.
// That action lives in the view environment, so a view in the main window
// registers it here via `.registersSettingsOpener()`; non-view callers (the
// command palette's static item builder, deep-link routing) then call
// `open(tab:)`.
// =============================================================================

@MainActor
final class SettingsWindowOpener {
    static let shared = SettingsWindowOpener()

    private var openSettingsAction: (() -> Void)?

    private init() {}

    fileprivate func register(_ action: @escaping () -> Void) {
        openSettingsAction = action
    }

    /// Bring the Settings window forward, optionally on a specific tab.
    func open(tab: SettingsTab? = nil) {
        if let tab {
            SettingsPanelRouter.shared.selectedTab = tab
        }
        openSettingsAction?()
        NSApp.activateFromUserAction()
    }
}

private struct SettingsOpenerRegistration: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                let action = openSettings
                SettingsWindowOpener.shared.register { action() }
            }
    }
}

extension View {
    /// Registers this view's `openSettings` environment action with
    /// `SettingsWindowOpener`.
    func registersSettingsOpener() -> some View {
        background { SettingsOpenerRegistration() }
    }
}
