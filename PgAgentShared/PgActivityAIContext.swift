import Foundation
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PgActivityAIContext — pure helpers that pack pg_stat_activity sessions,
// pg_locks rows, and activity-trend samples into compact prompt fragments for
// the on-device model (~4,096-token window shared by instructions + prompt +
// output, see PgAIContext).
//
// No FoundationModels dependency — just string shaping over the FFI value
// types, so everything here is unit-testable without the model.
// =============================================================================

enum PgActivityAIContext {
    /// One point-in-time summary of an instance's activity, recorded on each
    /// refresh so the model can narrate how load evolved.
    struct TrendSample: Equatable, Sendable {
        let epoch: Double
        let total: Int
        let active: Int
        let idleInTransaction: Int
        let waiting: Int
        let longRunning: Int
    }

    /// Budget clamps. Sessions dominate the prompt, so per-session query text
    /// is cut hard; full statements belong in the single-session context only.
    static let maxSessionLines = 20
    static let maxLockLines = 20
    static let maxTrendLines = 12
    static let maxQueryCharsInList = 100
    static let maxQueryCharsSingle = 800
    static let maxPlanChars = 1_200

    // MARK: - Single session (explain / long-running advisor)

    /// Full-detail context for one backend, used by "explain this session".
    /// `planText` carries EXPLAIN output when the caller could obtain one.
    static func describeSession(
        _ session: FfiPgSessionDetail,
        now: Double,
        longRunningThreshold: Double,
        planText: String? = nil
    ) -> String {
        var lines: [String] = ["--- SESSION ---"]
        lines.append("pid: \(session.pid)")
        lines.append("database: \(session.datname), user: \(session.usename)")
        if let addr = session.clientAddr { lines.append("client: \(addr)") }
        lines.append("state: \(session.state)")
        if let wait = session.waitEvent { lines.append("wait_event: \(wait) (currently blocked)") }
        if let start = session.queryStart {
            let secs = max(0, now - Double(start))
            let long = session.state == "active" && secs >= longRunningThreshold
            lines.append("running_for: \(Int(secs))s\(long ? " (exceeds the long-running threshold)" : "")")
        }
        let query = session.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lines.append("query:")
        lines.append(query.isEmpty ? "(none)" : PgAIContext.clamp(query, maxChars: maxQueryCharsSingle))
        if let planText, !planText.isEmpty {
            lines.append("")
            lines.append("--- EXPLAIN PLAN ---")
            lines.append(PgAIContext.clamp(planText, maxChars: maxPlanChars))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Session list (digest / blocking analysis)

    /// Compact one-line-per-backend rendering of the whole activity list,
    /// active + waiting sessions first (they carry the signal).
    static func packSessions(
        _ sessions: [FfiPgSessionDetail],
        now: Double,
        longRunningThreshold: Double
    ) -> String {
        guard !sessions.isEmpty else { return "--- SESSIONS ---\n(no backends)" }
        let ranked = sessions.sorted { lhs, rhs in
            rank(lhs) < rank(rhs)
        }
        var lines: [String] = ["--- SESSIONS (\(sessions.count) backends) ---"]
        for session in ranked.prefix(maxSessionLines) {
            var parts: [String] = ["pid=\(session.pid)", "state=\(session.state)"]
            if let wait = session.waitEvent { parts.append("wait=\(wait)") }
            if let start = session.queryStart, session.state != "idle" {
                let secs = Int(max(0, now - Double(start)))
                parts.append("for=\(secs)s")
                if session.state == "active", Double(secs) >= longRunningThreshold {
                    parts.append("LONG-RUNNING")
                }
            }
            parts.append("user=\(session.usename)")
            parts.append("db=\(session.datname)")
            let query = session.query?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !query.isEmpty, session.state != "idle" {
                parts.append("query=\(String(query.prefix(maxQueryCharsInList)))")
            }
            lines.append(parts.joined(separator: " "))
        }
        if sessions.count > maxSessionLines {
            lines.append("… and \(sessions.count - maxSessionLines) more backends (mostly idle)")
        }
        return lines.joined(separator: "\n")
    }

    /// Sort key: blocked first, then active, then idle-in-transaction, then rest.
    private static func rank(_ session: FfiPgSessionDetail) -> Int {
        if session.waitEvent != nil { return 0 }
        if session.state == "active" { return 1 }
        if session.state.hasPrefix("idle in transaction") { return 2 }
        return 3
    }

    // MARK: - Lock graph (blocking analysis)

    /// Waiter → blocker edges plus ungranted lock rows. Empty string when there
    /// is nothing lock-related to report, so callers can skip the section.
    static func packLocks(_ locks: [FfiPgLockDetail]) -> String {
        let interesting = locks.filter { $0.blockedByPid != nil || !$0.granted }
        guard !interesting.isEmpty else { return "" }
        var lines: [String] = ["--- LOCK WAITS ---"]
        for lock in interesting.prefix(maxLockLines) {
            var parts: [String] = ["pid=\(lock.pid)"]
            if let blocker = lock.blockedByPid { parts.append("blocked_by=\(blocker)") }
            parts.append("mode=\(lock.mode)")
            if let relation = lock.relation { parts.append("relation=\(relation)") }
            parts.append(lock.granted ? "granted" : "NOT granted")
            lines.append(parts.joined(separator: " "))
        }
        if interesting.count > maxLockLines {
            lines.append("… and \(interesting.count - maxLockLines) more waiting locks")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Trend samples (narration)

    /// Chronological table of activity samples with the time offset from the
    /// newest sample, e.g. `-120s total=14 active=3 idle_in_tx=2 waiting=1 long=0`.
    static func packTrend(_ samples: [TrendSample]) -> String {
        guard let newest = samples.map(\.epoch).max() else {
            return "--- TREND ---\n(no samples)"
        }
        let ordered = samples.sorted { $0.epoch < $1.epoch }
        // Keep the newest N, evenly thinning the middle would over-engineer:
        // the ring buffer is already short.
        let window = ordered.suffix(maxTrendLines)
        var lines: [String] = ["--- TREND (oldest to newest, offsets relative to now) ---"]
        for sample in window {
            let offset = Int(sample.epoch - newest)
            lines.append(
                "\(offset)s total=\(sample.total) active=\(sample.active) "
                    + "idle_in_tx=\(sample.idleInTransaction) waiting=\(sample.waiting) "
                    + "long_running=\(sample.longRunning)"
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Build a trend sample from a session snapshot.
    static func makeTrendSample(
        sessions: [FfiPgSessionDetail],
        now: Double,
        longRunningThreshold: Double
    ) -> TrendSample {
        let active = sessions.filter { $0.state == "active" }
        let longRunning = active.filter { session in
            guard let start = session.queryStart else { return false }
            return now - Double(start) >= longRunningThreshold
        }
        return TrendSample(
            epoch: now,
            total: sessions.count,
            active: active.count,
            idleInTransaction: sessions.filter { $0.state.hasPrefix("idle in transaction") }.count,
            waiting: sessions.filter { $0.waitEvent != nil }.count,
            longRunning: longRunning.count
        )
    }
}
