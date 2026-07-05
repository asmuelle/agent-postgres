import SwiftUI

// =============================================================================
// PostgresEnvironmentBadge — the one shared rendering of a profile's
// environment tag + read-only lock, used by the macOS sidebar/query tab
// and the iOS connection/fleet rows so "production" looks identical
// everywhere.
//
// Treatment contract (roadmap 1.4, "safe against production"):
//   * production   → loud red capsule, white PRODUCTION text. Unmissable.
//   * staging      → subtle amber tinted label.
//   * development  → subtle green tinted label.
//   * unspecified  → nothing.
//   * read-only    → small lock glyph next to (or instead of) the badge.
// =============================================================================

extension PostgresEnvironment {
    /// Tint for subtle affordances (sidebar icon/name, dots). `nil` for
    /// unspecified.
    var tint: Color? {
        switch self {
        case .unspecified: return nil
        case .development: return .green
        case .staging:     return .orange
        case .production:  return .red
        }
    }
}

struct PostgresEnvironmentBadge: View {
    let environment: PostgresEnvironment
    var isReadOnly: Bool = false
    /// Compact scales the badge down for dense list rows.
    var compact: Bool = false

    init(profile: PostgresProfile, compact: Bool = false) {
        self.environment = profile.effectiveEnvironment
        self.isReadOnly = profile.isReadOnly
        self.compact = compact
    }

    init(environment: PostgresEnvironment, isReadOnly: Bool = false, compact: Bool = false) {
        self.environment = environment
        self.isReadOnly = isReadOnly
        self.compact = compact
    }

    var body: some View {
        if environment != .unspecified || isReadOnly {
            HStack(spacing: 4) {
                if let label = environment.badgeLabel, let tint = environment.tint {
                    if environment == .production {
                        // Loud: filled red capsule, reserved for production only.
                        Text(label)
                            .font(.system(size: compact ? 9 : 11, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, compact ? 5 : 8)
                            .padding(.vertical, compact ? 1 : 2)
                            .background(Capsule().fill(Color.red))
                    } else {
                        // Subtle: tinted text on a faint tinted background.
                        Text(label)
                            .font(.system(size: compact ? 8 : 9, weight: .bold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, compact ? 4 : 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(tint.opacity(0.12))
                                    .overlay(Capsule().stroke(tint.opacity(0.3), lineWidth: 0.5))
                            )
                    }
                }
                if isReadOnly {
                    Image(systemName: "lock.fill")
                        .font(.system(size: compact ? 8 : 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help("Read-only connection — INSERT/UPDATE/DELETE/DDL are blocked by pgAgent.")
                        .accessibilityLabel("Read-only connection")
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
