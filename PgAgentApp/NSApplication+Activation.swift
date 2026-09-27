import AppKit

extension NSApplication {
    /// Bring the app to the front with cooperative `activate()`; every call
    /// site is a direct response to user input (menu-bar button, deep link,
    /// Settings command), which cooperative activation honours.
    func activateFromUserAction() {
        activate()
    }
}
