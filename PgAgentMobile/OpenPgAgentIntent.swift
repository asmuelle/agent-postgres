import AppIntents

// =============================================================================
// OpenPgAgentIntent — open Pulse, Query or Browse. The action of the Control
// Center control (and usable from Shortcuts). An OpenIntent: the system
// brings the app forward and runs `perform` there.
//
// ⚠️ Dual-target file: also compiled into PgAgentMobileWidgets, which needs
// the type for the control's button (project.yml).
// =============================================================================

/// The parts of the app the system can open directly.
enum PgAgentDestination: String, AppEnum {
    case pulse
    case query
    case browse

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Place"
    static let caseDisplayRepresentations: [PgAgentDestination: DisplayRepresentation] = [
        .pulse: DisplayRepresentation(title: "Pulse", image: .init(systemName: "waveform.path.ecg")),
        .query: DisplayRepresentation(title: "Query", image: .init(systemName: "terminal")),
        .browse: DisplayRepresentation(title: "Browse", image: .init(systemName: "square.stack.3d.up")),
    ]
}

struct OpenPgAgentIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open pgAgent"
    static let description = IntentDescription("Opens Pulse, Query or Browse.")
    /// Only ever in the app: `perform` hands the destination to the app's
    /// navigator, and the extension's copy of it leads nowhere.
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Place", default: .pulse)
    var target: PgAgentDestination

    init() {}

    init(destination: PgAgentDestination) {
        target = destination
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let destination: MobileSystemDestination = switch target {
        case .pulse: .pulse
        case .query: .query(profileId: nil)
        case .browse: .browse(profileId: nil)
        }
        MobileSystemNavigator.shared.request(destination)
        return .result()
    }
}
