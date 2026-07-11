import SwiftUI
import Charts
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// Postgres Activity & Lock Triage Dashboard (Pillar 3)
// Auto-polling dashboard displaying:
// 1. Live sessions (active query details, wait events, runtimes)
// 2. Lock contention tree (blocking vs blocked sessions on relations)
// 3. Real-time Swift Chart diagnostics (idle vs active vs lock waiting clients)
// 4. One-click query cancellation and session termination controls
// =============================================================================

struct HistoryPoint: Identifiable, Sendable {
    let id = UUID()
    let time: Date
    let count: Int
    let category: String // Active, Idle, Lock Waiting
}

struct PostgresActivityMonitorView: View {
    let connectionId: String?
    let profile: PostgresProfile?
    
    @State private var sessions: [FfiPgSessionDetail] = []
    @State private var locks: [FfiPgLockDetail] = []
    @State private var history: [HistoryPoint] = []
    @State private var selectedSession: FfiPgSessionDetail? = nil
    
    @State private var isPolling = true
    @State private var pollingInterval: Double = 3.0 // 3 seconds default
    @State private var errorMessage: String? = nil
    @State private var searchPattern: String = ""
    @State private var filterState: String = "All" // All, Active, Waiting
    @State private var pendingAction: PendingSessionAction?
    
    private let states = ["All", "Active", "Waiting"]
    
    var body: some View {
        VStack(spacing: 0) {
            toolbarHeader
            Divider()
            
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                        .font(MidnightMacDesign.FontToken.callout)
                    Spacer()
                    Button("Retry") {
                        Task { await fetchActivity() }
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.15))
                .foregroundStyle(.red)
            }
            
            HSplitView {
                // Left Panel: Charts & Table
                VStack(spacing: 0) {
                    if !history.isEmpty {
                        chartSection
                            .frame(height: 140)
                            .padding(14)
                        Divider()
                    }
                    
                    searchAndFilterBar
                    Divider()
                    
                    sessionTableSection
                }
                .frame(minWidth: 400, maxWidth: .infinity)
                
                // Right Panel: Lock Triage & Session details
                VStack(spacing: 0) {
                    lockContentionSection
                        .frame(height: 200)
                    
                    Divider()
                    
                    if selectedSession != nil {
                        sessionInspector
                    } else {
                        VStack {
                            Image(systemName: "hand.tap")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 6)
                            Text("Select a session to view details")
                                .font(MidnightMacDesign.FontToken.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 320)
            }
        }
        .background(MidnightMacDesign.ColorToken.windowBackground)
        .onAppear {
            startPollingTimer()
        }
        .onDisappear {
            isPolling = false
        }
        .sheet(item: $pendingAction) { pending in
            PostgresSessionActionConfirmationView(
                pending: pending,
                onCancel: { pendingAction = nil },
                onConfirm: { reason in
                    pendingAction = nil
                    performSessionAction(pending, reason: reason)
                }
            )
        }
    }
    
    // MARK: - Toolbar Header
    @ViewBuilder
    private var toolbarHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "pulse.circle.fill")
                .font(.title2)
                .foregroundStyle(.pink)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Database Diagnostics")
                    .font(MidnightMacDesign.FontToken.title)
                Text("Active sessions, locks, and query triage")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
            }
            
            Spacer()
            
            Toggle("Live Polling", isOn: $isPolling)
                .toggleStyle(.checkbox)
            
            Picker("Interval", selection: $pollingInterval) {
                Text("1s").tag(1.0)
                Text("3s").tag(3.0)
                Text("5s").tag(5.0)
                Text("Pause").tag(9999.0)
            }
            .frame(width: 130)
            .onChange(of: pollingInterval) { newVal in
                isPolling = newVal < 100.0
            }
            
            Button {
                Task { await fetchActivity() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh diagnostic counters")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
    
    // MARK: - Search & Filters
    @ViewBuilder
    private var searchAndFilterBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search by query, DB, user or client address...", text: $searchPattern)
                .textFieldStyle(.plain)
            
            Spacer()
            
            Picker("", selection: $filterState) {
                ForEach(states, id: \.self) { s in
                    Text(s).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(MidnightMacDesign.ColorToken.controlBackground)
    }
    
    // MARK: - Swift Charts Section
    @ViewBuilder
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLIENT CONCURRENCY TIMELINE")
                .font(MidnightMacDesign.FontToken.label)
                .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
            
            Chart(history) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value("Sessions", point.count)
                )
                .foregroundStyle(by: .value("Status", point.category))
                .interpolationMethod(.monotone)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .second, count: 10)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.minute().second())
                }
            }
        }
        .padding(10)
        .midnightMacCard()
        .border(MidnightMacDesign.ColorToken.separator, width: 1)
    }
    
    // MARK: - Sessions Table View
    @ViewBuilder
    private var sessionTableSection: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Table Header
                HStack(spacing: 10) {
                    Text("PID").font(MidnightMacDesign.FontToken.caption).bold().frame(width: 50, alignment: .leading)
                    Text("DB").font(MidnightMacDesign.FontToken.caption).bold().frame(width: 80, alignment: .leading)
                    Text("User").font(MidnightMacDesign.FontToken.caption).bold().frame(width: 80, alignment: .leading)
                    Text("IP Address").font(MidnightMacDesign.FontToken.caption).bold().frame(width: 100, alignment: .leading)
                    Text("Status").font(MidnightMacDesign.FontToken.caption).bold().frame(width: 80, alignment: .leading)
                    Text("Last Active Query").font(MidnightMacDesign.FontToken.caption).bold().frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(MidnightMacDesign.ColorToken.controlBackground)
                
                Divider()
                
                let filtered = sessions.filter { sess in
                    // Apply text search
                    if !searchPattern.isEmpty {
                        let queryMatch = sess.query?.localizedCaseInsensitiveContains(searchPattern) ?? false
                        let dbMatch = sess.datname.localizedCaseInsensitiveContains(searchPattern)
                        let userMatch = sess.usename.localizedCaseInsensitiveContains(searchPattern)
                        let clientMatch = sess.clientAddr?.localizedCaseInsensitiveContains(searchPattern) ?? false
                        if !queryMatch && !dbMatch && !userMatch && !clientMatch {
                            return false
                        }
                    }
                    
                    // Apply state filters
                    if filterState == "Active" && sess.state != "active" {
                        return false
                    }
                    if filterState == "Waiting" && sess.waitEvent == nil {
                        return false
                    }
                    
                    return true
                }
                
                if filtered.isEmpty {
                    VStack(spacing: 6) {
                        Text("No active sessions match the filters.")
                            .font(MidnightMacDesign.FontToken.callout)
                            .foregroundStyle(MidnightMacDesign.ColorToken.tertiaryText)
                    }
                    .padding(32)
                } else {
                    ForEach(filtered, id: \.pid) { sess in
                        let isSelected = selectedSession?.pid == sess.pid
                        let isWaiting = sess.waitEvent != nil
                        
                        Button {
                            selectedSession = sess
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(sess.pid)")
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 50, alignment: .leading)
                                
                                Text(sess.datname)
                                    .font(MidnightMacDesign.FontToken.body)
                                    .frame(width: 80, alignment: .leading)
                                
                                Text(sess.usename)
                                    .font(MidnightMacDesign.FontToken.body)
                                    .frame(width: 80, alignment: .leading)
                                
                                Text(sess.clientAddr ?? "local")
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 100, alignment: .leading)
                                    .foregroundStyle(sess.clientAddr == nil ? .secondary : .primary)
                                
                                // Status Pill
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(statusColor(sess.state, isWaiting))
                                        .frame(width: 6, height: 6)
                                    Text(isWaiting ? "LOCK WAIT" : sess.state.uppercased())
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(statusColor(sess.state, isWaiting).opacity(0.15))
                                .foregroundStyle(statusColor(sess.state, isWaiting))
                                .clipShape(Capsule())
                                .frame(width: 80, alignment: .leading)
                                
                                // Query Text
                                Text(sess.query?.prefix(120).trimmingCharacters(in: .whitespacesAndNewlines) ?? "-- IDLE --")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(sess.query == nil ? MidnightMacDesign.ColorToken.secondaryText : .primary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSelected ? MidnightMacDesign.ColorToken.selection : Color.clear)
                        }
                        .buttonStyle(.plain)
                        
                        Divider()
                    }
                }
            }
        }
    }
    
    // MARK: - Lock Contention Tree View
    @ViewBuilder
    private var lockContentionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.orange)
                Text("LOCK CONTENTION TREE")
                    .font(MidnightMacDesign.FontToken.label)
                Spacer()
                Text("\(locks.count) Locks")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(MidnightMacDesign.ColorToken.controlBackground)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let blockedLocks = locks.filter { $0.blockedByPid != nil }
                    
                    if blockedLocks.isEmpty {
                        VStack(spacing: 4) {
                            Image(systemName: "checkmark.shield")
                                .font(.title3)
                                .foregroundStyle(.green)
                            Text("No lock contentions detected.")
                                .font(MidnightMacDesign.FontToken.caption)
                                .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(blockedLocks, id: \.pid) { lock in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Text("PID \(lock.pid)")
                                        .bold()
                                        .font(.system(size: 11, design: .monospaced))
                                    Text("is BLOCKED by")
                                        .font(MidnightMacDesign.FontToken.caption)
                                        .foregroundStyle(.red)
                                    Text("PID \(lock.blockedByPid ?? 0)")
                                        .bold()
                                        .font(.system(size: 11, design: .monospaced))
                                }
                                
                                HStack {
                                    Image(systemName: "cube.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.orange)
                                    Text("Relation:")
                                        .font(MidnightMacDesign.FontToken.caption)
                                        .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                                    Text(lock.relation ?? "Unknown relation")
                                        .font(.system(size: 11, design: .monospaced))
                                }
                                .padding(.leading, 8)
                                
                                HStack {
                                    Image(systemName: "key.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                    Text("Acquiring Lock:")
                                        .font(MidnightMacDesign.FontToken.caption)
                                        .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                                    Text(lock.mode)
                                        .font(.system(size: 11, design: .monospaced))
                                }
                                .padding(.leading, 8)
                            }
                            .padding(8)
                            .midnightMacCard()
                            .border(.red.opacity(0.3), width: 1)
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(MidnightMacDesign.ColorToken.controlBackground.opacity(0.4))
    }
    
    // MARK: - Session Detail Inspector
    @ViewBuilder
    private var sessionInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                Text("SESSION CONTROL PANEL")
                    .font(MidnightMacDesign.FontToken.label)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(MidnightMacDesign.ColorToken.controlBackground)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Group {
                        inspectorDetail(label: "PID", value: "\(selectedSession?.pid ?? 0)")
                        inspectorDetail(label: "State", value: (selectedSession?.state ?? "unknown").uppercased())
                        
                        if let addr = selectedSession?.clientAddr {
                            inspectorDetail(label: "Client IP Address", value: addr)
                        }
                        
                        if let we = selectedSession?.waitEvent {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("WAIT EVENT (LOCK CONFLICT)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.red)
                                Text(we)
                                    .font(MidnightMacDesign.FontToken.body)
                                    .foregroundStyle(.red)
                                    .bold()
                            }
                        }
                    }
                    
                    if let queryText = selectedSession?.query {
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CURRENT EXECUTING QUERY")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                            
                            ScrollView {
                                Text(queryText)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 120)
                            .background(MidnightMacDesign.ColorToken.textBackground)
                            .border(MidnightMacDesign.ColorToken.separator, width: 1)
                        }
                    }
                    
                    Divider()
                    
                    // Admin Triage Actions
                    VStack(alignment: .leading, spacing: 10) {
                        Text("DIAGNOSTIC TRIAGE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                        
                        HStack(spacing: 12) {
                            Button { requestSessionAction(.cancel) } label: {
                                Label("Cancel Query", systemImage: "xmark.circle")
                                    .font(MidnightMacDesign.FontToken.caption)
                                    .bold()
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .border(Color.orange.opacity(0.3), width: 1)
                            
                            Button { requestSessionAction(.terminate) } label: {
                                Label("Terminate Session", systemImage: "bolt.fill")
                                    .font(MidnightMacDesign.FontToken.caption)
                                    .bold()
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.15))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .border(Color.red.opacity(0.3), width: 1)
                        }
                    }
                }
                .padding(14)
            }
        }
    }
    
    @ViewBuilder
    private func inspectorDetail(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
            Text(value)
                .font(MidnightMacDesign.FontToken.body)
        }
    }
    
    // MARK: - Diagnostic Helpers
    private func statusColor(_ state: String, _ isWaiting: Bool) -> Color {
        if isWaiting { return .red }
        switch state {
        case "active": return .green
        case "idle": return MidnightMacDesign.ColorToken.tertiaryText
        case "idle in transaction": return .orange
        default: return .secondary
        }
    }
    
    private func startPollingTimer() {
        Task {
            while isPolling {
                await fetchActivity()
                try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
            }
        }
    }
    
    private func fetchActivity() async {
        guard let connectionId else {
            errorMessage = "No Postgres database connected."
            return
        }
        
        do {
            let fetchedSessions = try await BridgeManager.shared.pgListSessions(connectionId: connectionId)
            let fetchedLocks = try await BridgeManager.shared.pgListLocks(connectionId: connectionId)
            
            await MainActor.run {
                self.sessions = fetchedSessions
                self.locks = fetchedLocks
                self.errorMessage = nil
                
                // Track selected session refresh
                if let selected = selectedSession {
                    selectedSession = fetchedSessions.first { $0.pid == selected.pid }
                }
                
                // Update history points for charts
                let now = Date()
                let activeCount = fetchedSessions.filter { $0.state == "active" && $0.waitEvent == nil }.count
                let idleCount = fetchedSessions.filter { $0.state.contains("idle") }.count
                let waitingCount = fetchedSessions.filter { $0.waitEvent != nil }.count
                
                history.append(HistoryPoint(time: now, count: activeCount, category: "Active"))
                history.append(HistoryPoint(time: now, count: idleCount, category: "Idle"))
                history.append(HistoryPoint(time: now, count: waitingCount, category: "Lock Waiting"))
                
                // Keep only last 2 minutes of history
                if history.count > 120 {
                    history.removeFirst(3)
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
        }
    }
    
    private func requestSessionAction(_ action: PostgresSessionAction) {
        guard let sess = selectedSession else { return }
        let challenge = PostgresSessionActionPolicy.challenge(
            action: action,
            isProduction: profile?.effectiveEnvironment == .production,
            profileName: profile?.name ?? "PostgreSQL",
            pid: sess.pid
        )
        pendingAction = PendingSessionAction(
            action: action, session: sess, challenge: challenge)
    }

    private func performSessionAction(_ pending: PendingSessionAction, reason: String) {
        guard let connectionId else { return }
        Task {
            do {
                let success: Bool
                switch pending.action {
                case .cancel:
                    success = try await BridgeManager.shared.pgCancelBackend(
                        connectionId: connectionId, pid: pending.session.pid)
                case .terminate:
                    success = try await BridgeManager.shared.pgTerminateBackend(
                        connectionId: connectionId, pid: pending.session.pid)
                }
                auditSessionAction(pending, reason: reason, error: success ? nil : "backend no longer active")
                if pending.action == .terminate, success {
                    await MainActor.run { selectedSession = nil }
                }
                if !success {
                    await MainActor.run { errorMessage = "The backend was no longer active." }
                }
                await fetchActivity()
            } catch {
                auditSessionAction(pending, reason: reason, error: error.localizedDescription)
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func auditSessionAction(
        _ pending: PendingSessionAction,
        reason: String,
        error: String?
    ) {
        guard let profile else { return }
        let action: PostgresAuditRecord.Action = pending.action == .cancel
            ? .cancelBackend : .terminateBackend
        Task.detached(priority: .utility) {
            await PostgresAuditLog.shared.record(
                profileName: profile.name,
                host: profile.host,
                database: profile.database,
                user: profile.user,
                action: action,
                statement: "pid=\(pending.session.pid); reason=\(reason)",
                error: error,
                rowsAffected: nil
            )
        }
    }
}

private struct PendingSessionAction: Identifiable {
    let id = UUID()
    let action: PostgresSessionAction
    let session: FfiPgSessionDetail
    let challenge: PostgresSessionActionChallenge
}

private struct PostgresSessionActionConfirmationView: View {
    let pending: PendingSessionAction
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var phrase = ""
    @State private var reason = ""

    private var canConfirm: Bool {
        !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pending.challenge.accepts(phrase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pending.challenge.title).font(.headline)
            Text("PID \(pending.session.pid) · \(pending.session.usename) · \(pending.session.datname)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(pending.session.query ?? "No query text available")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(6)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            TextField("Reason for the audit log", text: $reason)
                .textFieldStyle(.roundedBorder)
            if let required = pending.challenge.requiredPhrase {
                Text("Type \(required) to continue.").font(.caption)
                TextField(required, text: $phrase).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(pending.action == .cancel ? "Cancel Query" : "Terminate Session") {
                    onConfirm(reason.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .buttonStyle(.borderedProminent)
                .tint(pending.action == .terminate ? .red : .orange)
                .disabled(!canConfirm)
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}
