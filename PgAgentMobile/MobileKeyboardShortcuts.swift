import Combine
import SwiftUI

/// Hardware-keyboard actions for the iPad workspace.
///
/// Shortcuts are declared once, at the `Scene` level via
/// `MobileKeyboardCommands`, so they (a) show up in the iPadOS ⌘-hold
/// discoverability overlay and the iPadOS 26 menu bar, and (b) fire
/// regardless of which view is first responder — including while the SQL
/// text view has focus. Commands have no reference to the active workspace,
/// so they publish through the focused window's `MobileShortcutRelay` (a
/// focused scene value — each window has its own) and that window's views
/// subscribe. ⌘↩ therefore only ever runs the query in the window in front.
///
/// Bindings mirror the Mac editor (`PostgresQueryTabView+EditorBar`,
/// `PostgresWorkspaceView`) so muscle memory transfers between devices.
enum MobileShortcutAction: Equatable {
    /// ⌘N — add a connection.
    case newConnection
    /// ⌥⌘N — a new window on the current database.
    case newWindow
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
    /// ⌘⌥1…3 — show Pulse, Query or Browse.
    case showTab(MobileAppTab)
}

/// One window's relay from menu commands to its views. Created per scene by
/// `MobileContentView`, published to the commands as a focused scene value
/// and to the window's views as an environment object.
@MainActor
final class MobileShortcutRelay: ObservableObject {
    let actions = PassthroughSubject<MobileShortcutAction, Never>()

    func send(_ action: MobileShortcutAction) {
        actions.send(action)
    }
}

extension FocusedValues {
    /// The shortcut relay of the window in front.
    @Entry var mobileShortcutRelay: MobileShortcutRelay?
}

/// Menu-bar commands installed on the app's `WindowGroup`. Every item acts
/// on the focused window only, and is disabled when no window has focus.
struct MobileKeyboardCommands: Commands {
    @FocusedValue(\.mobileShortcutRelay) private var focusedRelay

    var body: some Commands {
        // Replaces the system File items, so New Window is provided here.
        CommandGroup(replacing: .newItem) {
            Group {
                Button("New Connection…") { send(.newConnection) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Window") { send(.newWindow) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            .disabled(focusedRelay == nil)
        }

        CommandMenu("Query") {
            Group {
                Button("Run Query") { send(.runQuery) }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Cancel Query") { send(.cancelQuery) }
                    .keyboardShortcut(".", modifiers: .command)
            }
            .disabled(focusedRelay == nil)
        }

        CommandMenu("Tabs") {
            Group {
                Button("New Query Tab") { send(.newTab) }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") { send(.closeTab) }
                    .keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("Next Tab") { send(.nextTab) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { send(.previousTab) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                ForEach(1...8, id: \.self) { n in
                    Button("Tab \(n)") { send(.selectTab(index: n - 1)) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                }
                Button("Last Tab") { send(.selectLastTab) }
                    .keyboardShortcut("9", modifiers: .command)
            }
            .disabled(focusedRelay == nil)
        }

        CommandGroup(after: .sidebar) {
            Group {
                Button("Pulse") { send(.showTab(.pulse)) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Query") { send(.showTab(.query)) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Browse") { send(.showTab(.browse)) }
                    .keyboardShortcut("3", modifiers: [.command, .option])
            }
            .disabled(focusedRelay == nil)
        }
    }

    private func send(_ action: MobileShortcutAction) {
        focusedRelay?.send(action)
    }
}
