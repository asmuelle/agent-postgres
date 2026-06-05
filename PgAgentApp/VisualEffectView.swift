import AppKit
import SwiftUI

/// SwiftUI wrapper around `NSVisualEffectView` so panels can opt into
/// real macOS materials (sidebar vibrancy, content-background, header, etc.)
/// instead of flat solid fills.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .followsWindowActiveState
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = emphasized
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = emphasized
    }
}

extension View {
    /// Convenience: paint a material behind any view.
    func materialBackground(
        _ material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) -> some View {
        background(VisualEffectView(material: material, blendingMode: blendingMode).ignoresSafeArea())
    }

    /// Finder-style sidebar background: translucent material + a
    /// very subtle light-blue vertical gradient that fades top→bottom,
    /// matching the look of the macOS Finder sidebar regardless of the
    /// user's accent colour. Both layers ignore safe area so they
    /// extend under the toolbar.
    ///
    /// `.blendMode(.plusLighter)` mixes the gradient *with* the
    /// vibrant material instead of compositing on top, so the blue
    /// tint reads through the desktop-aware blur.
    func finderSidebarBackground() -> some View {
        background {
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()
                .overlay {
                    LinearGradient(
                        colors: [
                            Color(red: 0.83, green: 0.87, blue: 0.96).opacity(0.20),
                            Color(red: 0.90, green: 0.93, blue: 0.98).opacity(0.06),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.plusLighter)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
        }
    }
}
