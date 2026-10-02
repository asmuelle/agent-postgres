import SwiftUI

// MARK: - App Color Palette

/// Adaptive palette. Every token resolves per trait collection, so the app
/// follows the system light/dark setting instead of forcing dark mode.
enum MidnightColors {
    /// Screen background behind grouped lists and cards.
    static let primaryBackground = Color(uiColor: .systemGroupedBackground)
    /// Document-like surfaces: the SQL editor, results grid, routine editor.
    static let canvas = Color(uiColor: .systemBackground)
    /// Rows and cards sitting on `primaryBackground`.
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let borderGray = Color(uiColor: .separator)
    /// Selection highlights and chips (was white at 2–8% on the old dark-only palette).
    static let subtleFill = Color(uiColor: .quaternarySystemFill)
    /// Recessed strips: tab bar, status bar, editor well (was black at 20–40%).
    static let recessedFill = Color(uiColor: .tertiarySystemFill)

    /// Brand accent: bright cyan on dark, deeper teal on light so glyphs and
    /// labels keep ≥4.5:1 contrast on white.
    static let accentCyan = adaptive(
        dark: UIColor(red: 0.15, green: 0.75, blue: 0.85, alpha: 1),
        light: UIColor(red: 0.00, green: 0.47, blue: 0.56, alpha: 1)
    )
    static let accentPurple = adaptive(
        dark: UIColor(red: 0.55, green: 0.35, blue: 0.85, alpha: 1),
        light: UIColor(red: 0.42, green: 0.22, blue: 0.72, alpha: 1)
    )
    /// Labels and glyphs drawn on an `accentCyan` fill.
    static let onAccent = adaptive(dark: .black, light: .white)

    static func glowGradient() -> LinearGradient {
        LinearGradient(
            colors: [accentCyan.opacity(0.15), accentPurple.opacity(0.15)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func adaptive(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

enum MidnightMobileDesign {
    /// Text styles, not fixed point sizes, so every token scales with
    /// Dynamic Type. At the default size each matches the old fixed value
    /// (title2 = 22, headline/body = 17, subheadline = 15, caption = 12).
    enum FontToken {
        static let title = Font.title2.weight(.semibold)
        static let headline = Font.headline
        static let body = Font.body
        static let subheadline = Font.subheadline
        static let label = Font.subheadline.weight(.semibold)
        static let caption = Font.caption
        static let captionStrong = Font.caption.weight(.semibold)
        static let metadataMono = Font.caption.monospaced()
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
        static let overlay: CGFloat = 16
    }

    enum Spacing {
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
        static let xlarge: CGFloat = 16
        static let touchTarget: CGFloat = 44
    }

    enum ColorToken {
        static let groupedBackground = Color(uiColor: .systemGroupedBackground)
        static let secondaryGroupedBackground = Color(uiColor: .secondarySystemGroupedBackground)
        static let tertiaryGroupedBackground = Color(uiColor: .tertiarySystemGroupedBackground)
        static let separator = Color(uiColor: .separator)
        static let secondaryText = Color(uiColor: .secondaryLabel)
        static let tertiaryText = Color(uiColor: .tertiaryLabel)
    }

    static func statusColor(_ status: PostgresWorkspaceStatus) -> Color {
        switch status {
        case .disconnected: return ColorToken.tertiaryText
        case .connecting: return .orange
        case .connected: return .green
        case .error: return .red
        }
    }

    static func statusSymbol(_ status: PostgresWorkspaceStatus) -> String {
        switch status {
        case .disconnected: return "circle"
        case .connecting: return "clock.fill"
        case .connected: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }
}

extension View {
    func midnightMobileCard(radius: CGFloat = MidnightMobileDesign.Radius.medium) -> some View {
        background(MidnightMobileDesign.ColorToken.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: radius))
    }

    func midnightMobileMinimumTapTarget() -> some View {
        frame(minHeight: MidnightMobileDesign.Spacing.touchTarget)
    }
}
