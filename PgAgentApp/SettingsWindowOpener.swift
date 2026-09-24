import AppKit
import SwiftUI

// =============================================================================
// SettingsWindowOpener — programmatic "open the Settings scene" that works on
// every supported macOS.
//
// macOS 14+ ignores the private `showSettingsWindow:` responder action (it
// logs "Please use SettingsLink for opening the Settings scene" and does
// nothing), so there the only supported path is SwiftUI's
// `@Environment(\.openSettings)`. That action lives in the view environment,
// so a view in the main window registers it here via
// `.registersSettingsOpener()`; non-view callers (the command palette's static
// item builder, deep-link routing) then call `open(tab:)`. macOS 13 has no
// `openSettings` and still honours the selector — that's the fallback.
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
        if let openSettingsAction {
            openSettingsAction()
        } else {
            // macOS 13 (or no registered view yet): the app-level responder
            // action is the only bridge to the Settings scene.
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        NSApp.activateFromUserAction()
    }
}

@available(macOS 14.0, *)
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
    /// `SettingsWindowOpener` (macOS 14+; no-op on macOS 13).
    func registersSettingsOpener() -> some View {
        background {
            if #available(macOS 14.0, *) {
                SettingsOpenerRegistration()
            }
        }
    }
}
