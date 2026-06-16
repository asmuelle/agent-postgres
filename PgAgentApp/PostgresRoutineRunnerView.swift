#if os(macOS)
import AppKit
import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresRoutineRunnerView — run a function/procedure with typed parameters
// (Slice 2). Introspects the exact overload's input parameters, presents a
// per-argument form (value / NULL / Use DEFAULT), shows a live preview of the
// generated call, runs it, and renders results in the shared results grid.
//
// Saved fixtures (PostgresRoutineFixturesStore) let a parameter set be named,
// persisted, and replayed after editing the routine — a lightweight regression
// check.
//
// Note: this calls the COMMITTED routine in the database, not the editor's
// unsaved buffer — Apply first to test edits.
// =============================================================================

struct PostgresRoutineRunnerView: View {
    let connectionId: String?
    let profileId: String
    let schema: String
    let name: String
    let signature: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var fixturesStore = PostgresRoutineFixturesStore.shared

    private enum Phase: Equatable {
        case loading
        case ready
        case error(String)
    }

    @State private var phase: Phase = .loading
    @State private var info: RoutineCallInfo?
    /// Per-parameter form state, keyed by `RoutineParam.ordinal`.
    @State private var values: [Int: RoutineParamValue] = [:]
    @State private var result: FfiPgExecutionResult?
    @State private var runError: String?
    @State private var isRunning = false
    @State private var showSaveDialog = false
    @State private var saveName = ""

    private var routineKey: String {
        PostgresRoutineFixturesStore.routineKey(schema: schema, name: name, signature: signature)
    }

    private var fixtures: [PostgresRoutineFixture] {
        fixturesStore.fixtures(forProfile: profileId, routineKey: routineKey)
    }

    private var generatedSQL: String {
        guard let info else { return "" }
        return PostgresRoutineCall.buildInvocation(
            schema: schema, name: name, info: info, values: values)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 820,
               minHeight: 440, idealHeight: 620, maxHeight: 900)
        .task { await introspect() }
        .alert("Save parameter set", isPresented: $showSaveDialog) {
            TextField("Fixture name", text: $saveName)
            Button("Save") { saveFixture() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Replay these inputs later — e.g. to re-test the routine after an edit.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Run \(name)")
                    .font(.headline)
                Text("\(schema).\(name)(\(signature))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if case .ready = phase {
                fixtureMenu
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var fixtureMenu: some View {
        Menu {
            if fixtures.isEmpty {
                Text("No saved fixtures")
            } else {
                ForEach(fixtures) { fixture in
                    Button(fixture.name) { load(fixture) }
                }
                Divider()
                Menu("Delete") {
                    ForEach(fixtures) { fixture in
                        Button(fixture.name, role: .destructive) {
                            fixturesStore.remove(id: fixture.id, fromProfile: profileId)
                        }
                    }
                }
            }
            Divider()
            Button("Save current as fixture…") {
                saveName = ""
                showSaveDialog = true
            }
            .disabled(info == nil)
        } label: {
            Label("Fixtures", systemImage: "bookmark")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Inspecting parameters…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error(let msg):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle).foregroundStyle(.orange)
                Text("Couldn't inspect this routine").font(.headline)
                Text(msg)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
                Button("Retry") { Task { await introspect() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready:
            VStack(spacing: 0) {
                paramForm
                Divider()
                sqlPreview
                if result != nil || runError != nil {
                    Divider()
                    resultsArea
                }
            }
        }
    }

    @ViewBuilder
    private var paramForm: some View {
        if let info, !info.params.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(info.params) { param in
                        paramRow(param)
                        if param.ordinal < info.params.count {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 120, maxHeight: 260)
        } else {
            Text("This routine takes no input parameters.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    private func paramRow(_ param: RoutineParam) -> some View {
        let v = values[param.ordinal] ?? RoutineParamValue()
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(param.label)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if param.mode == "b" { modeBadge("INOUT", .orange) }
                    if param.isVariadic { modeBadge("VARIADIC", .purple) }
                }
                Text(param.type)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                TextField("value", text: bindingText(param.ordinal))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(v.isNull || v.useDefault)

                HStack(spacing: 16) {
                    Toggle("NULL", isOn: bindingNull(param.ordinal))
                    if param.hasDefault {
                        Toggle("Use DEFAULT", isOn: bindingDefault(param.ordinal))
                            .help("Omit this argument so the routine's DEFAULT applies")
                    }
                    Spacer()
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func modeBadge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var sqlPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CALL")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(generatedSQL)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(NSColor.separatorColor)))
        }
        .padding(12)
    }

    @ViewBuilder
    private var resultsArea: some View {
        if let runError {
            ScrollView {
                Label(runError, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 80, maxHeight: 200)
        } else if let result {
            let visibleColumns = result.columns.filter { !$0.name.hasPrefix("__pg_") }
            if visibleColumns.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(result.rowsAffected.map { "\($0) row(s) affected" } ?? "Completed.")
                        .font(.callout)
                    Spacer()
                }
                .padding(12)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(result.rows.count) row(s)")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.top, 8)
                    PostgresResultsTable(result: result)
                        .frame(minHeight: 160, maxHeight: 280)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if case .ready = phase {
                Text("Calls the saved routine in the database.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await run() }
            } label: {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Run", systemImage: "play.fill")
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(connectionId == nil || info == nil || isRunning)
        }
        .padding(16)
    }

    // MARK: - Bindings

    private func bindingText(_ ordinal: Int) -> Binding<String> {
        Binding(
            get: { values[ordinal]?.text ?? "" },
            set: { values[ordinal, default: RoutineParamValue()].text = $0 }
        )
    }

    private func bindingNull(_ ordinal: Int) -> Binding<Bool> {
        Binding(
            get: { values[ordinal]?.isNull ?? false },
            set: { newValue in
                values[ordinal, default: RoutineParamValue()].isNull = newValue
                if newValue { values[ordinal]?.useDefault = false }
            }
        )
    }

    private func bindingDefault(_ ordinal: Int) -> Binding<Bool> {
        Binding(
            get: { values[ordinal]?.useDefault ?? false },
            set: { newValue in
                values[ordinal, default: RoutineParamValue()].useDefault = newValue
                if newValue { values[ordinal]?.isNull = false }
            }
        )
    }

    // MARK: - Actions

    private func introspect() async {
        guard let connectionId else {
            phase = .error("Not connected.")
            return
        }
        phase = .loading
        let sessionId = "routine-runner-\(UUID().uuidString)"
        let outcome: Result<FfiPgExecutionResult, Error>
        do {
            let res = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: PostgresRoutineCall.introspectionQuery(
                    schema: schema, name: name, signature: signature),
                pageSize: 200
            )
            outcome = .success(res)
        } catch {
            outcome = .failure(error)
        }
        await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)

        switch outcome {
        case .success(let res):
            guard let parsed = PostgresRoutineCall.parseParams(rows: res.rows.map(\.cells)) else {
                phase = .error("This overload wasn't found — it may have been changed. Close and reopen.")
                return
            }
            info = parsed
            // Seed defaults: params that declare a DEFAULT start omitted.
            var seed: [Int: RoutineParamValue] = [:]
            for p in parsed.params where p.hasDefault {
                seed[p.ordinal] = RoutineParamValue(useDefault: true)
            }
            values = seed
            phase = .ready
        case .failure(let error):
            phase = .error((error as? PostgresBridgeError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func run() async {
        guard let connectionId, let info else { return }
        let sql = PostgresRoutineCall.buildInvocation(
            schema: schema, name: name, info: info, values: values)
        isRunning = true
        runError = nil
        result = nil
        let sessionId = "routine-run-\(UUID().uuidString)"
        let outcome: Result<FfiPgExecutionResult, Error>
        do {
            let res = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId, sessionId: sessionId, sql: sql, pageSize: 500)
            outcome = .success(res)
        } catch {
            outcome = .failure(error)
        }
        await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
        isRunning = false
        switch outcome {
        case .success(let res):
            result = res
        case .failure(let error):
            runError = (error as? PostgresBridgeError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func load(_ fixture: PostgresRoutineFixture) {
        guard let info else { return }
        var next: [Int: RoutineParamValue] = [:]
        for p in info.params {
            if let saved = fixture.values[p.label] {
                next[p.ordinal] = RoutineParamValue(
                    text: saved.text, isNull: saved.isNull, useDefault: saved.useDefault)
            } else if p.hasDefault {
                next[p.ordinal] = RoutineParamValue(useDefault: true)
            }
        }
        values = next
        result = nil
        runError = nil
    }

    private func saveFixture() {
        guard let info else { return }
        var dict: [String: PostgresFixtureValue] = [:]
        for p in info.params {
            let v = values[p.ordinal] ?? RoutineParamValue()
            dict[p.label] = PostgresFixtureValue(
                text: v.text, isNull: v.isNull, useDefault: v.useDefault)
        }
        fixturesStore.save(
            profileId: profileId, routineKey: routineKey, name: saveName, values: dict)
    }
}
#endif
