import AppKit
import PgAgentMacOS
import SwiftUI

enum MidnightMacDesign {
    enum FontToken {
        static let title = Font.system(size: 17, weight: .semibold)
        static let headline = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13, weight: .regular)
        static let callout = Font.system(size: 12, weight: .regular)
        static let subheadline = Font.system(size: 11, weight: .regular)
        static let label = Font.system(size: 11, weight: .semibold)
        static let caption = Font.system(size: 10, weight: .regular)
        static let metadataMono = Font.system(size: 10, design: .monospaced)
    }

    enum Radius {
        static let xsmall: CGFloat = 4
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
    }

    enum Spacing {
        static let xsmall: CGFloat = 4
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
        static let xlarge: CGFloat = 16
    }

    enum ColorToken {
        static let windowBackground = Color(nsColor: .windowBackgroundColor)
        static let controlBackground = Color(nsColor: .controlBackgroundColor)
        static let textBackground = Color(nsColor: .textBackgroundColor)
        static let separator = Color(nsColor: .separatorColor)
        static let secondaryText = Color(nsColor: .secondaryLabelColor)
        static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
        static let selection = Color(nsColor: .selectedContentBackgroundColor)
        static let inactiveSelection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    static func statusColor(_ status: TerminalConnectionStatus) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return ColorToken.tertiaryText
        case .error: return .red
        }
    }

    static func statusSymbol(_ status: TerminalConnectionStatus) -> String {
        switch status {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "clock.fill"
        case .disconnected: return "circle"
        case .error: return "exclamationmark.circle.fill"
        }
    }
}

extension View {
    func midnightMacCard(radius: CGFloat = MidnightMacDesign.Radius.medium) -> some View {
        background(MidnightMacDesign.ColorToken.controlBackground, in: RoundedRectangle(cornerRadius: radius))
    }

    func midnightMacFocusRing(_ isFocused: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.small)
                .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 1)
        )
    }
}
