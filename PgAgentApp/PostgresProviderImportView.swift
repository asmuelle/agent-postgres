import SwiftUI
import PgAgentMacOS

/// macOS "Add from provider…" sheet (roadmap 2.1). Token-paste only —
/// no OAuth, no telemetry. All fetch/selection/import logic lives in the
/// shared `ProviderImportModel`; API tokens live in the keychain via
/// `ProviderTokenStore`.
struct PostgresProviderImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PostgresProfileStore
    @StateObject private var model = ProviderImportModel()

    @State private var resultSummary: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Connections from a Provider")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Form {
                Section {
                    Picker("Provider", selection: $model.provider) {
                        ForEach(PostgresProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 8) {
                        SecureField(model.provider.tokenFieldLabel, text: $model.token)
                            .textFieldStyle(.roundedBorder)
                        Button("Fetch") {
                            Task { await model.fetch() }
                        }
                        .disabled(model.isLoading)
                    }
                    Text("The token is stored in your keychain and only ever sent to \(model.provider.displayName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.provider.tokenHelpText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section("Databases") {
                    switch model.state {
                    case .idle:
                        Text("Paste a token and press Fetch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .loading:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Contacting \(model.provider.displayName)…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .failed(let message):
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    case .loaded(let databases):
                        if databases.isEmpty {
                            Text("No databases found for this token.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(databases) { database in
                                databaseRow(database)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let resultSummary {
                    Text(resultSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import \(model.selectedIds.count) Connection\(model.selectedIds.count == 1 ? "" : "s")") {
                    resultSummary = model.importSelection(into: store)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedIds.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 540, minHeight: 440)
    }

    @ViewBuilder
    private func databaseRow(_ database: ProviderDatabase) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.selectedIds.contains(database.id) },
                set: { _ in model.toggle(database.id) }
            ))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(database.name)
                        .font(.body.weight(.medium))
                    if database.requiresPasswordOnFirstConnect {
                        Text("password on first connect")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(database.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
