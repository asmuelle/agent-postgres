import SwiftUI

enum MidnightMobileDesign {
    enum FontToken {
        static let title = Font.system(size: 22, weight: .semibold)
        static let headline = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 17, weight: .regular)
        static let subheadline = Font.system(size: 15, weight: .regular)
        static let label = Font.system(size: 15, weight: .semibold)
        static let caption = Font.system(size: 12, weight: .regular)
        static let captionStrong = Font.system(size: 12, weight: .semibold)
        static let metadataMono = Font.system(size: 12, design: .monospaced)
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
