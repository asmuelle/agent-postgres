#if os(macOS)
import AppKit
import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresRoutineAttributesView — structured attribute editor + security lens
// (Slice 3). Edits volatility / parallel / security / strict / leakproof /
// cost / rows / SET search_path as real controls, emits a minimal ALTER
// FUNCTION/PROCEDURE (never touches the body), and surfaces deterministic
// security findings with one-click fixes.
//
// Self-contained: it introspects, applies, and re-introspects on its own.
// `onApplied` lets the host editor refresh its Source buffer, since an ALTER
// changes the routine's catalog definition.
// =============================================================================

struct PostgresRoutineAttributesView: View {
    let connectionId: String?
    let profileId: String
    let schema: String
    let name: String
    let signature: String
    /// Called after a successful ALTER / fix so the editor can reload Source.
    var onApplied: () -> Void = {}

    private enum Phase: Equatable {
        case loading
        case ready
        case error(String)
    }

    @State private var phase: Phase = .loading
    @State private var original = RoutineAttributes()
    @State private var edited = RoutineAttributes()
    @State private var isApplying = false
    @State private var applyError: String?
    @State private var applied = false

    private var isDirty: Bool { edited != original }

    private var alterSQL: String? {
        PostgresRoutineAttributes.alterStatement(
            schema: schema, name: name, signature: signature, from: original, to: edited)
    }

    private var findings: [RoutineSecurityFinding] {
        PostgresRoutineAttributes.securityFindings(
            edited, schema: schema, name: name, signature: signature)
    }

    var body: some View {
        switch phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading attributes…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: routineKey) { await introspect() }

        case .error(let msg):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle).foregroundStyle(.orange)
                Text("Couldn't read attributes").font(.headline)
                Text(msg).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
                Button("Retry") { Task { await introspect() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: routineKey) { await introspect() }

        case .ready:
            ready
        }
    }

    private var routineKey: String {
        "\(connectionId ?? "-")|\(schema).\(name)(\(signature))"
    }

    @ViewBuilder
    private var ready: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !findings.isEmpty { securitySection }
                    metadataSection
                    attributesSection
                }
                .padding(16)
            }
            Divider()
            footer
        }
    }

    // MARK: - Security lens

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Security")
            ForEach(findings) { finding in
                findingRow(finding)
            }
        }
    }

    private func findingRow(_ finding: RoutineSecurityFinding) -> some View {
        let (icon, tint) = severityStyle(finding.severity)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).font(.callout.weight(.semibold))
                Text(finding.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let fix = finding.fixSQL {
                Button("Fix") { Task { await runStatement(fix) } }
                    .controlSize(.small)
                    .disabled(isApplying || connectionId == nil)
                    .help(fix)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func severityStyle(_ s: RoutineSecurityFinding.Severity) -> (String, Color) {
        switch s {
        case .critical: return ("exclamationmark.shield.fill", .red)
        case .warning:  return ("exclamationmark.triangle.fill", .orange)
        case .info:     return ("info.circle.fill", .blue)
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(edited.isProcedure ? "Procedure" : "Function")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 340), spacing: 12)],
                spacing: 12
            ) {
                PropertyCard(label: "Language",
                             value: edited.language.uppercased(),
                             statusPill: edited.languageTrusted ? "TRUSTED" : "UNTRUSTED",
                             pillColor: edited.languageTrusted ? .green : .orange)
                if let returns = edited.returns, !returns.isEmpty {
                    PropertyCard(label: "Returns", value: returns)
                }
                PropertyCard(label: "Arguments",
                             value: edited.arguments.isEmpty ? "(none)" : edited.arguments)
            }
        }
    }

    // MARK: - Attributes

    private var attributesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Attributes")

            attrRow("Security") {
                Picker("", selection: Binding(
                    get: { edited.securityDefiner },
                    set: { edited.securityDefiner = $0 }
                )) {
                    Text("INVOKER").tag(false)
                    Text("DEFINER").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }

            if !edited.isProcedure {
                attrRow("Volatility") {
                    Picker("", selection: $edited.volatility) {
                        ForEach(RoutineVolatility.allCases, id: \.self) {
                            Text($0.keyword).tag($0)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                }
                attrRow("Parallel") {
                    Picker("", selection: $edited.parallel) {
                        ForEach(RoutineParallel.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                }
                attrRow("On NULL input") {
                    Toggle("STRICT (return NULL on any NULL argument)", isOn: $edited.strict)
                        .toggleStyle(.checkbox)
                }
                attrRow("Leakproof") {
                    Toggle("LEAKPROOF", isOn: $edited.leakproof)
                        .toggleStyle(.checkbox)
                        .help("Asserts no side effects / no information leak; lets the planner "
                              + "push predicates below security barriers. Requires superuser to set.")
                }
                attrRow("Cost") {
                    TextField("", value: $edited.cost, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 120)
                    Text("estimated execution cost").font(.caption2).foregroundStyle(.tertiary)
                }
                if edited.returnsSet {
                    attrRow("Rows") {
                        TextField("", value: $edited.rows, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 120)
                        Text("estimated result rows").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            attrRow("search_path") {
                TextField("not pinned", text: Binding(
                    get: { edited.searchPath ?? "" },
                    set: { edited.searchPath = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: 320)
            }
            if !edited.otherConfig.isEmpty {
                Text("Other SET: \(edited.otherConfig.joined(separator: ", "))")
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .padding(.leading, 150)
            }

            if let alterSQL {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ALTER").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    Text(alterSQL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(NSColor.separatorColor)))
                }
                .padding(.top, 4)
            }
        }
    }

    private func attrRow<Content: View>(
        _ label: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 138, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let applyError {
                Label(applyError, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(2)
            } else if applied {
                Label("Applied.", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if isDirty {
                Label("Modified.", systemImage: "pencil")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert") { edited = original; applyError = nil; applied = false }
                .disabled(!isDirty || isApplying)
            Button {
                Task { if let sql = alterSQL { await runStatement(sql) } }
            } label: {
                if isApplying {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Apply attributes", systemImage: "checkmark.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isDirty || isApplying || alterSQL == nil || connectionId == nil)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func introspect() async {
        guard let connectionId else { phase = .error("Not connected."); return }
        if phase != .ready { phase = .loading }
        let sessionId = "routine-attrs-\(UUID().uuidString)"
        let outcome: Result<FfiPgExecutionResult, Error>
        do {
            let res = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId, sessionId: sessionId,
                sql: PostgresRoutineAttributes.introspectionQuery(
                    schema: schema, name: name, signature: signature),
                pageSize: 1)
            outcome = .success(res)
        } catch {
            outcome = .failure(error)
        }
        await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
        switch outcome {
        case .success(let res):
            guard let row = res.rows.first?.cells,
                  let attrs = PostgresRoutineAttributes.parse(row: row) else {
                phase = .error("This overload wasn't found — it may have changed. Reopen the tab.")
                return
            }
            original = attrs
            edited = attrs
            phase = .ready
        case .failure(let error):
            phase = .error((error as? PostgresBridgeError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Run an ALTER / GRANT statement, then re-introspect and notify the host.
    private func runStatement(_ sql: String) async {
        guard let connectionId else { return }
        isApplying = true
        applyError = nil
        applied = false
        let sessionId = "routine-attrs-apply-\(UUID().uuidString)"
        let outcome: Result<Void, Error>
        do {
            _ = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId, sessionId: sessionId, sql: sql, pageSize: 1)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
        isApplying = false
        switch outcome {
        case .success:
            await introspect()
            onApplied()
            applied = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            applied = false
        case .failure(let error):
            applyError = (error as? PostgresBridgeError)?.errorDescription ?? error.localizedDescription
        }
    }
}
#endif
