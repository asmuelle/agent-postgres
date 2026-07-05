import ActivityKit
import Foundation

// =============================================================================
// LiveActivityManager — tiny app-side helper for the Postgres operation Live
// Activity (PgOperationActivityAttributes). Call sites stay to three lines:
// start when a long-running operation kicks off, update on phase change, end
// with success/failure. Everything is a silent no-op when the user has Live
// Activities disabled, so callers never branch on availability.
// =============================================================================
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    /// Terminal state lingers briefly on the lock screen, then auto-dismisses.
    private static let terminalDismissalDelay: TimeInterval = 8

    private var activities: [String: Activity<PgOperationActivityAttributes>] = [:]

    private init() {}

    /// Begin a Live Activity for a long-running operation. Returns an opaque
    /// token for update/end, or nil when activities are unavailable.
    func start(
        operationKind: String,
        instanceName: String,
        targetName: String? = nil,
        detail: String? = nil
    ) -> String? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        let attributes = PgOperationActivityAttributes(
            operationKind: operationKind,
            instanceName: instanceName,
            targetName: targetName
        )
        let state = PgOperationActivityAttributes.ContentState(
            phase: "Running",
            startedAt: Date(),
            progress: nil,
            detail: detail,
            succeeded: nil
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
            activities[activity.id] = activity
            return activity.id
        } catch {
            // OS-level refusal (rate limit, disabled mid-flight) — the
            // operation itself must proceed regardless.
            return nil
        }
    }

    /// Push a phase change (and optionally determinate progress) to the
    /// activity. No-op for nil/unknown tokens.
    func update(id: String?, phase: String, progress: Double? = nil, detail: String? = nil) {
        guard let id, let activity = activities[id] else { return }
        var state = activity.content.state
        state.phase = phase
        state.progress = progress.map { min(1, max(0, $0)) } ?? state.progress
        state.detail = detail ?? state.detail
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.update(content) }
    }

    /// Finish the activity with a success/failure state; it lingers briefly on
    /// the lock screen and then dismisses itself.
    func end(id: String?, success: Bool, detail: String? = nil) {
        guard let id, let activity = activities.removeValue(forKey: id) else { return }
        var state = activity.content.state
        state.phase = success ? "Done" : "Failed"
        state.succeeded = success
        if success, state.progress != nil { state.progress = 1 }
        state.detail = detail ?? state.detail
        let content = ActivityContent(state: state, staleDate: nil)
        let dismissal = Date().addingTimeInterval(Self.terminalDismissalDelay)
        Task { await activity.end(content, dismissalPolicy: .after(dismissal)) }
    }
}
