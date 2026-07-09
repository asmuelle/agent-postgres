import Foundation
import OSLog
import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileActivityAIStore — drives the on-device AI analyses of the instance
// activity pane: triage digest, blocking root-cause, per-session explain,
// long-running advisor (EXPLAIN-grounded), and trend narration.
//
// One store per activity view. Every operation is on-demand (never on the
// 3-second refresh loop) and purely advisory — recommendations route back
// through the pane's existing confirm + biometric flows; the model never
// executes anything itself.
// =============================================================================

/// The finished analysis a sheet renders.
enum MobileActivityInsight: Equatable {
    case session(PgSessionInsightResult, pid: Int32, isLongRunning: Bool)
    case blocking(PgBlockingInsightResult)
    case digest(PgActivityDigestResult)
    case trend(PgActivityDigestResult)

    var title: String {
        switch self {
        case .session(_, let pid, let isLong):
            return isLong ? "Long-running query · PID \(pid)" : "Session · PID \(pid)"
        case .blocking: return "Blocking analysis"
        case .digest: return "Activity digest"
        case .trend: return "Trend analysis"
        }
    }
}

@MainActor
final class MobileActivityAIStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(String)
        case done(MobileActivityInsight)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var isPresented: Bool = false
    /// Last digest headline, kept for the pane header after the sheet closes.
    @Published private(set) var lastDigest: PgActivityDigestResult?

    /// Probed once per store; the pane hides all AI affordances when absent.
    let availability = PgAIAvailabilityProbe.current()

    private(set) var trendSamples: [PgActivityAIContext.TrendSample] = []
    /// ~2 minutes of samples at the pane's 3-second refresh cadence.
    private static let maxTrendSamples = 40
    /// EXPLAIN for the advisor must not hang the analysis on a busy instance.
    private static let explainRowCap: UInt32 = 200

    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.mc-ssh", category: "pg-activity-ai")
    /// Test seam: when set, used instead of the real SDK-backed assistant.
    private let makeAssistant: PgActivityAIAssistantFactory?

    init(makeAssistant: PgActivityAIAssistantFactory? = nil) {
        self.makeAssistant = makeAssistant
    }

    var canNarrateTrend: Bool { trendSamples.count >= 3 }

    // MARK: - Snapshot recording (feature 5 input)

    /// Called by the pane on every refresh; cheap, no model involvement.
    func recordSnapshot(sessions: [FfiPgSessionDetail]) {
        let sample = PgActivityAIContext.makeTrendSample(
            sessions: sessions,
            now: Date().timeIntervalSince1970,
            longRunningThreshold: FleetMonitorSettings.shared.longRunningThreshold
        )
        trendSamples.append(sample)
        if trendSamples.count > Self.maxTrendSamples {
            trendSamples.removeFirst(trendSamples.count - Self.maxTrendSamples)
        }
    }

    // MARK: - Analyses

    /// Explain one backend (feature 2). For long-running active queries this
    /// becomes the advisor (feature 4): we try to fetch an EXPLAIN plan for
    /// grounding when the session runs against the database we're connected to
    /// and the statement is provably read-only.
    func explainSession(
        _ session: FfiPgSessionDetail,
        connectionId: String?,
        connectedDatabase: String
    ) {
        let now = Date().timeIntervalSince1970
        let threshold = FleetMonitorSettings.shared.longRunningThreshold
        let isLong = session.state == "active"
            && (session.queryStart.map { now - Double($0) >= threshold } ?? false)

        run(label: isLong ? "Analyzing long-running query…" : "Explaining session…") { assistant in
            var planText: String?
            if isLong, let connectionId {
                planText = await Self.fetchPlan(
                    for: session,
                    connectionId: connectionId,
                    connectedDatabase: connectedDatabase
                )
            }
            let context = PgActivityAIContext.describeSession(
                session,
                now: now,
                longRunningThreshold: threshold,
                planText: planText
            )
            let result = try await assistant.explainSession(context: context, isLongRunning: isLong)
            return .session(result, pid: session.pid, isLongRunning: isLong)
        }
    }

    /// Root-cause the current lock-wait chain (feature 1).
    func analyzeBlocking(sessions: [FfiPgSessionDetail], locks: [FfiPgLockDetail]) {
        let now = Date().timeIntervalSince1970
        let threshold = FleetMonitorSettings.shared.longRunningThreshold
        run(label: "Analyzing blocking chain…") { assistant in
            let context = [
                PgActivityAIContext.packSessions(sessions, now: now, longRunningThreshold: threshold),
                PgActivityAIContext.packLocks(locks),
                "Identify the root blocker and the safest way to unblock the chain.",
            ].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let result = try await assistant.analyzeBlocking(context: context)
            return .blocking(result)
        }
    }

    /// One-glance triage digest of the snapshot (feature 3).
    func generateDigest(sessions: [FfiPgSessionDetail], locks: [FfiPgLockDetail]) {
        let now = Date().timeIntervalSince1970
        let threshold = FleetMonitorSettings.shared.longRunningThreshold
        run(label: "Summarizing activity…") { assistant in
            let context = [
                PgActivityAIContext.packSessions(sessions, now: now, longRunningThreshold: threshold),
                PgActivityAIContext.packLocks(locks),
                "Give the one-glance status of this instance.",
            ].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let result = try await assistant.summarizeActivity(context: context)
            return .digest(result)
        }
    }

    /// Narrate the recorded trend samples (feature 5).
    func narrateTrend() {
        let samples = trendSamples
        run(label: "Analyzing trend…") { assistant in
            let context = PgActivityAIContext.packTrend(samples)
                + "\n\nDescribe how activity evolved and call out anomalies."
            let result = try await assistant.narrateTrend(context: context)
            return .trend(result)
        }
    }

    func dismiss() {
        task?.cancel()
        task = nil
        isPresented = false
        phase = .idle
    }

    // MARK: - Shared run plumbing

    private func run(
        label: String,
        _ operation: @escaping (any PgActivityAIAssisting) async throws -> MobileActivityInsight
    ) {
        task?.cancel()
        phase = .running(label)
        isPresented = true
        task = Task { [weak self] in
            guard let self else { return }
            switch PgActivityAIAssistantResolver.resolve(factory: self.makeAssistant) {
            case .failure(let reason):
                self.phase = .failed(reason.message)
            case .success(let assistant):
                do {
                    let insight = try await operation(assistant)
                    if Task.isCancelled { return }
                    if case .digest(let digest) = insight { self.lastDigest = digest }
                    self.phase = .done(insight)
                } catch {
                    if Task.isCancelled { return }
                    self.logger.error("Activity AI failed: \(error.localizedDescription, privacy: .public)")
                    self.phase = .failed("Couldn't complete the analysis: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Best-effort EXPLAIN for the advisor. Returns `nil` (and the analysis
    /// proceeds plan-less) unless the statement is provably read-only and the
    /// session runs on the database this connection is attached to — EXPLAIN
    /// against the wrong database or with unbound $n parameters just errors.
    private static func fetchPlan(
        for session: FfiPgSessionDetail,
        connectionId: String,
        connectedDatabase: String
    ) async -> String? {
        guard session.datname == connectedDatabase,
              let query = session.query?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty,
              !query.contains("$1"),
              PostgresStatementClassifier.isReadOnly(query)
        else { return nil }

        let sessionId = "activity-ai-\(UUID().uuidString)"
        let result: FfiPgExecutionResult
        do {
            result = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: "EXPLAIN \(query)",
                pageSize: explainRowCap
            )
        } catch {
            _ = await BridgeManager.shared.pgReleaseSession(
                connectionId: connectionId,
                sessionId: sessionId
            )
            return nil
        }
        if let cursorId = result.cursorId {
            _ = await BridgeManager.shared.pgCloseQuery(
                connectionId: connectionId,
                sessionId: sessionId,
                cursorId: cursorId
            )
        }
        _ = await BridgeManager.shared.pgReleaseSession(
            connectionId: connectionId,
            sessionId: sessionId
        )
        let plan = result.rows
            .compactMap { $0.cells.first ?? nil }
            .joined(separator: "\n")
        return plan.isEmpty ? nil : plan
    }
}
