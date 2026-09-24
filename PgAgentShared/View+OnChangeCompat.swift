import SwiftUI

extension View {
    /// `onChange(of:)` whose action receives the new value, without the
    /// single-parameter `onChange(of:perform:)` deprecation (macOS 14 / iOS 17).
    ///
    /// Uses the two-parameter API wherever it exists and falls back to the
    /// deprecated form only on macOS 13 (the macOS deployment target). iOS
    /// deploys at 17, so it never needs the fallback.
    @ViewBuilder
    func onChangeCompat<V: Equatable>(
        of value: V,
        perform action: @escaping (V) -> Void
    ) -> some View {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value, perform: action)
        }
        #else
        onChange(of: value) { _, newValue in action(newValue) }
        #endif
    }
}
