import Combine
import SwiftUI

/// Hardware-keyboard actions for the iPad workspace.
///
/// Shortcuts are declared once, at the `Scene` level via
/// `MobileKeyboardCommands`, so they (a) show up in the iPadOS ⌘-hold
/// discoverability overlay and the iPadOS 26 menu bar, and (b) fire
/// regardless of which view is first responder — including while the SQL
/// text view has focus. The scene has no reference to the active workspace,
/// so the menu items publish an action through `MobileShortcutRelay` and the
/// visible `MobileQueryWorkspaceView` subscribes.
///
/// Bindings mirror the Mac editor (`PostgresQueryTabView+EditorBar`,
/// `PostgresWorkspaceView`) so muscle memory transfers between devices.
enum MobileShortcutAction: Equatable {
    /// ⌘↩ — run the active tab's SQL.
    case runQuery
    /// ⌘. — cancel the running statement.
    case cancelQuery
    /// ⌘T — open a blank query tab.
    case newTab
    /// ⌘W — close the active tab.
    case closeTab
    /// ⌘⇧] — select the next tab (wraps).
    case nextTab
    /// ⌘⇧[ — select the previous tab (wraps).
    case previousTab
    /// ⌘1…⌘8 — select the tab at a 0-based index.
    case selectTab(index: Int)
    /// ⌘9 — select the last tab.
    case selectLastTab
    /// ⌘⇧E — show/hide the Object Explorer sidebar.
    case toggleSidebar
}

/// Single-scene relay from menu commands to the workspace on screen.
/// When the app grows multiple windows this becomes a `FocusedValue`.
@MainActor
final class MobileShortcutRelay: ObservableObject {
    static let shared = MobileShortcutRelay()

    let actions = PassthroughSubject<MobileShortcutAction, Never>()

    func send(_ action: MobileShortcutAction) {
        actions.send(action)
    }
}

/// Menu-bar commands installed on the app's `WindowGroup`.
struct MobileKeyboardCommands: Commands {
    private let relay = MobileShortcutRelay.shared

    var body: some Commands {
        CommandMenu("Query") {
            Button("Run Query") { relay.send(.runQuery) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Cancel Query") { relay.send(.cancelQuery) }
                .keyboardShortcut(".", modifiers: .command)
        }

        CommandMenu("Tabs") {
            Button("New Query Tab") { relay.send(.newTab) }
                .keyboardShortcut("t", modifiers: .command)
            Button("Close Tab") { relay.send(.closeTab) }
                .keyboardShortcut("w", modifiers: .command)
            Divider()
            Button("Next Tab") { relay.send(.nextTab) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { relay.send(.previousTab) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1...8, id: \.self) { n in
                Button("Tab \(n)") { relay.send(.selectTab(index: n - 1)) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
            }
            Button("Last Tab") { relay.send(.selectLastTab) }
                .keyboardShortcut("9", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Object Explorer") { relay.send(.toggleSidebar) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }
}
