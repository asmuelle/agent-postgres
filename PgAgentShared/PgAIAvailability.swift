import Foundation
import FoundationModels

// =============================================================================
// PgAIAvailability — runtime gate for the on-device language model.
//
// FoundationModels is always present at pgAgent's deployment target, but the
// model itself may not be usable (ineligible hardware, Apple Intelligence off,
// model still downloading), so the UI asks `PgAIAvailabilityProbe.current()`
// before showing any AI affordance.
// =============================================================================

/// Plain, `Sendable` mirror of the model's availability so SwiftUI views and
/// stores can switch on it without importing FoundationModels themselves.
enum PgAIAvailability: Equatable, Sendable {
    case available
    /// Hardware can't run Apple Intelligence (e.g. unsupported chip).
    case deviceNotEligible
    /// User hasn't turned Apple Intelligence on in Settings.
    case appleIntelligenceNotEnabled
    /// Model is still downloading or warming up.
    case modelNotReady
    /// A reason the SDK reports that we don't model explicitly yet.
    case unknown(String)

    var isAvailable: Bool { self == .available }

    /// Short, user-facing explanation for the unavailable cases. `nil` when
    /// available (nothing to explain).
    var userMessage: String? {
        switch self {
        case .available:
            return nil
        case .deviceNotEligible:
            return "This device isn't eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Enable Apple Intelligence in System Settings to use AI features."
        case .modelNotReady:
            return "The on-device model is downloading or not ready yet."
        case .unknown(let detail):
            return "On-device AI is unavailable: \(detail)"
        }
    }
}

/// Probes the live model state. Cheap to call; the UI may call it per render.
enum PgAIAvailabilityProbe {
    static func current() -> PgAIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable(let other):
            return .unknown(String(describing: other))
        @unknown default:
            return .unknown("unrecognized availability case")
        }
    }
}
