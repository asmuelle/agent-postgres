import SwiftUI

/// iOS "Add from provider…" sheet (roadmap 2.1). Token-paste only — no
/// OAuth, no telemetry. Fetch/selection/import logic lives in the shared
/// `ProviderImportModel`; tokens are stored in the iOS keychain via
/// `ProviderTokenStore`.
struct MobileProviderImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var profileStore: PostgresProfileStore
    @StateObject private var model = ProviderImportModel()

    private let accent = Color(red: 0.15, green: 0.75, blue: 0.85) // Cyan accent

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    tokenCard
                    databasesCard
                }
                .padding(.vertical)
            }
            .background(MidnightMobileDesign.ColorToken.groupedBackground.ignoresSafeArea())
            .navigationTitle("Add from Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(MidnightMobileDesign.FontToken.body)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(model.selectedIds.count)") {
                        _ = model.importSelection(into: profileStore)
                        dismiss()
                    }
                    .font(MidnightMobileDesign.FontToken.label)
                    .disabled(model.selectedIds.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Token entry

    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PROVIDER & TOKEN")
                .font(MidnightMobileDesign.FontToken.captionStrong)
                .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 14) {
                Picker("Provider", selection: $model.provider) {
                    ForEach(PostgresProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                SecureField(model.provider.tokenFieldLabel, text: $model.token)
                    .font(MidnightMobileDesign.FontToken.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .midnightMobileMinimumTapTarget()

                Button {
                    Task { await model.fetch() }
                } label: {
                    HStack {
                        if model.isLoading {
                            ProgressView().tint(.black)
                        }
                        Text(model.isLoading ? "Fetching…" : "Fetch Databases")
                            .font(MidnightMobileDesign.FontToken.label)
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(model.isLoading)

                Text("The token is stored in your keychain and only ever sent to \(model.provider.displayName). \(model.provider.tokenHelpText)")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .midnightMobileCard()
        }
        .padding(.horizontal)
    }

    // MARK: - Result list

    private var databasesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DATABASES")
                .font(MidnightMobileDesign.FontToken.captionStrong)
                .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 12) {
                switch model.state {
                case .idle:
                    Text("Paste a token and tap Fetch Databases.")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().tint(accent)
                        Text("Contacting \(model.provider.displayName)…")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                    }
                case .failed(let message):
                    Text(message)
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .loaded(let databases):
                    if databases.isEmpty {
                        Text("No databases found for this token.")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                    } else {
                        ForEach(databases) { database in
                            databaseRow(database)
                            if database.id != databases.last?.id {
                                Divider().background(MidnightMobileDesign.ColorToken.separator)
                            }
                        }
                    }
                }
            }
            .padding()
            .midnightMobileCard()
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func databaseRow(_ database: ProviderDatabase) -> some View {
        let isSelected = model.selectedIds.contains(database.id)
        Button {
            model.toggle(database.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? accent : MidnightMobileDesign.ColorToken.tertiaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(database.name)
                        .font(MidnightMobileDesign.FontToken.label)
                        .foregroundStyle(.primary)
                    Text(database.detail)
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                        .lineLimit(1)
                    if database.requiresPasswordOnFirstConnect {
                        Text("Password required on first connect")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .midnightMobileMinimumTapTarget()
        }
        .buttonStyle(.plain)
    }
}
