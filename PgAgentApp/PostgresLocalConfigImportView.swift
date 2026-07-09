import SwiftUI
import PgAgentMacOS

/// macOS-only import sheet for ~/.pgpass and ~/.pg_service.conf
/// (roadmap 2.1). Parsing lives in `PostgresLocalConfig` (PgAgentShared);
/// this view reads the files (the app is not sandboxed), previews the
/// concrete entries with checkboxes, and imports the selected ones as
/// profiles — passwords go to the keychain, never into the profile store.
struct PostgresLocalConfigImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PostgresProfileStore

    /// One selectable row, unified across both source files.
    struct Candidate: Identifiable {
        let id: String
        let sourceLabel: String
        let name: String
        let host: String
        let port: UInt16
        let database: String
        let user: String
        let password: String?
        let tls: PostgresTlsMode?
        let alreadyExists: Bool

        var summary: String { "\(user)@\(host):\(port)/\(database)" }
    }

    @State private var candidates: [Candidate] = []
    @State private var selectedIds: Set<String> = []
    @State private var loaded = false
    @State private var resultMessage: String?

    private var selectableCandidates: [Candidate] {
        candidates.filter { !$0.alreadyExists }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Import from ~/.pgpass and ~/.pg_service.conf")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if candidates.isEmpty && loaded {
                emptyMessage
            } else {
                candidateList
            }

            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 380)
        .onAppear(perform: loadCandidates)
    }

    private var emptyMessage: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No importable entries found")
                .font(.headline)
            Text("Neither ~/.pgpass nor ~/.pg_service.conf contains concrete host entries (wildcard-only lines are skipped).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var candidateList: some View {
        List {
            ForEach(candidates) { candidate in
                HStack(spacing: 10) {
                    Toggle("", isOn: binding(for: candidate))
                        .labelsHidden()
                        .disabled(candidate.alreadyExists)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(candidate.name)
                                .font(.body.weight(.medium))
                            Text(candidate.sourceLabel)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                            if candidate.alreadyExists {
                                Text("already imported")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if candidate.password == nil {
                                Text("no password on file")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text(candidate.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .opacity(candidate.alreadyExists ? 0.5 : 1)
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(selectedIds.isEmpty ? "Select All" : "Deselect All") {
                if selectedIds.isEmpty {
                    selectedIds = Set(selectableCandidates.map(\.id))
                } else {
                    selectedIds = []
                }
            }
            .disabled(selectableCandidates.isEmpty)
            Button("Import \(selectedIds.count) Connection\(selectedIds.count == 1 ? "" : "s")") {
                importSelected()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedIds.isEmpty)
        }
        .padding()
    }

    private func binding(for candidate: Candidate) -> Binding<Bool> {
        Binding(
            get: { selectedIds.contains(candidate.id) },
            set: { isOn in
                if isOn {
                    selectedIds.insert(candidate.id)
                } else {
                    selectedIds.remove(candidate.id)
                }
            }
        )
    }

    // MARK: - Load

    private func loadCandidates() {
        guard !loaded else { return }
        loaded = true

        let home = FileManager.default.homeDirectoryForCurrentUser
        let existingAccounts = Set(store.profiles.map(\.keychainAccount))
        var found: [Candidate] = []

        if let text = try? String(
            contentsOf: home.appendingPathComponent(".pgpass"), encoding: .utf8
        ) {
            for entry in PostgresLocalConfig.parsePgPass(text) {
                let account = "\(entry.user)@\(entry.host):\(entry.port)/\(entry.database)"
                found.append(Candidate(
                    id: "pgpass:\(account)",
                    sourceLabel: ".pgpass",
                    name: "\(entry.database) @ \(entry.host)",
                    host: entry.host,
                    port: entry.port,
                    database: entry.database,
                    user: entry.user,
                    password: entry.password,
                    tls: nil,
                    alreadyExists: existingAccounts.contains(account)
                ))
            }
        }

        if let text = try? String(
            contentsOf: home.appendingPathComponent(".pg_service.conf"), encoding: .utf8
        ) {
            for entry in PostgresLocalConfig.parsePgServiceConf(text) {
                let account = "\(entry.user)@\(entry.host):\(entry.port)/\(entry.database)"
                found.append(Candidate(
                    id: "pgservice:\(entry.name)",
                    sourceLabel: "pg_service.conf",
                    name: entry.name,
                    host: entry.host,
                    port: entry.port,
                    database: entry.database,
                    user: entry.user,
                    password: entry.password,
                    tls: entry.tls,
                    alreadyExists: existingAccounts.contains(account)
                ))
            }
        }

        candidates = found
        selectedIds = Set(found.filter { !$0.alreadyExists }.map(\.id))
    }

    // MARK: - Import

    private func importSelected() {
        var imported = 0
        for candidate in candidates
        where selectedIds.contains(candidate.id) && !candidate.alreadyExists {
            // No explicit sslmode: default to the app's secure `.require`.
            // Users with a deliberately plaintext local server can still opt
            // down explicitly in the connection editor.
            let profile = PostgresProfile(
                name: candidate.name,
                host: candidate.host,
                port: candidate.port,
                database: candidate.database,
                user: candidate.user,
                auth: .keychain,
                tls: candidate.tls ?? .require
            )
            if let password = candidate.password, !password.isEmpty {
                KeychainManager.shared.savePassword(
                    kind: .postgresPassword,
                    account: profile.keychainAccount,
                    secret: password
                )
            }
            store.saveOrUpdate(profile)
            imported += 1
        }
        resultMessage = "Imported \(imported)."
        dismiss()
    }
}
