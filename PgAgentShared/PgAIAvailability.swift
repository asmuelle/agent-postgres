import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// =============================================================================
// PgAIAvailability — runtime gate for the on-device language model.
//
// FoundationModels ships in the macOS 26 / iOS 26 SDK, but pgAgent's
// deployment target is macOS 13 / iOS 17. The framework is weak-linked, so
// every symbol that touches it lives behind `@available(macOS 26, iOS 26, *)`
// and the UI asks `PgAIAvailabilityProbe.current()` before showing any AI
// affordance. On older OSes this returns `.osTooOld` without ever calling
// into the (absent) framework.
// =============================================================================

/// Plain, `Sendable` mirror of the model's availability so SwiftUI views and
/// stores can switch on it without importing FoundationModels or carrying an
/// `@available` annotation themselves.
enum PgAIAvailability: Equatable, Sendable {
    case available
    /// OS is below macOS 26 / iOS 26 — the framework isn't present at runtime.
    case osTooOld
    /// Hardware can't run Apple Intelligence (e.g. unsupported chip).
    case deviceNotEligible
    /// User hasn't turned Apple Intelligence on in Settings.
    case appleIntelligenceNotEnabled
    /// Model is still downloading or warming up.
    case modelNotReady
    /// Built without the FoundationModels SDK at all.
    case frameworkMissing
    /// A reason the SDK reports that we don't model explicitly yet.
    case unknown(String)

    var isAvailable: Bool { self == .available }

    /// Short, user-facing explanation for the unavailable cases. `nil` when
    /// available (nothing to explain).
    var userMessage: String? {
        switch self {
        case .available:
            return nil
        case .osTooOld:
            return "On-device AI needs macOS 26 / iOS 26 or later."
        case .deviceNotEligible:
            return "This device isn't eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Enable Apple Intelligence in System Settings to use AI features."
        case .modelNotReady:
            return "The on-device model is downloading or not ready yet."
        case .frameworkMissing:
            return "This build doesn't include on-device AI support."
        case .unknown(let detail):
            return "On-device AI is unavailable: \(detail)"
        }
    }
}

/// Why no assistant could be resolved, carrying a user-facing message.
struct PgAIUnavailable: Error, Equatable {
    let message: String
}

/// Probes the live model state. Cheap to call; the UI may call it per render.
enum PgAIAvailabilityProbe {
    static func current() -> PgAIAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
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
        } else {
            return .osTooOld
        }
        #else
        return .frameworkMissing
        #endif
    }
}
