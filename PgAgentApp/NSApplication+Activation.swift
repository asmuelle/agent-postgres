import AppKit

extension NSApplication {
    /// Bring the app to the front. `activate(ignoringOtherApps:)` is
    /// deprecated on macOS 14 in favour of cooperative `activate()`; every call
    /// site is a direct response to user input (menu-bar button, deep link,
    /// Settings command), which cooperative activation honours.
    func activateFromUserAction() {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}
