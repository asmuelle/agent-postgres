import SwiftUI

// =============================================================================
// MobileRoleEditorView — pgAdmin-style role property editor (iPad): privilege
// attributes, connection limit, expiry, comment, and role memberships with
// ADMIN OPTION. Shares PostgresRoleEditorStore + PostgresRoleDDL with macOS;
// only the midnight styling is platform-specific.
// =============================================================================
struct MobileRoleEditorView: View {
    let roleName: String
    let connectionId: String?
    /// Invoked after a successful apply with the (possibly renamed) role name.
    var onApplied: (String) -> Void = { _ in }

    @StateObject private var store = PostgresRoleEditorStore()

    var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                VStack(spacing: 12) {
                    ProgressView().tint(MidnightColors.accentCyan)
                    Text("Loading role…")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { reload() }
                        .buttonStyle(.borderedProminent)
                        .tint(MidnightColors.accentCyan)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if let binding = editedBinding {
                    editorForm(binding)
                }
            }
        }
        .task(id: "\(roleName)|\(connectionId ?? "")") {
            reload()
        }
    }

    private var editedBinding: Binding<PostgresRoleAttributes>? {
        guard store.edited != nil else { return nil }
        return Binding(
            get: { store.edited! },
            set: { store.edited = $0 }
        )
    }

    private func reload() {
        guard let connectionId else { return }
        Task { await store.load(roleName: roleName, connectionId: connectionId) }
    }

    // MARK: - Form

    private func editorForm(_ attrs: Binding<PostgresRoleAttributes>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                card("ROLE") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name").font(.caption).foregroundStyle(.secondary)
                        TextField("Role name", text: attrs.name)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(10)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                card("PRIVILEGES") {
                    VStack(spacing: 4) {
                        privilegeToggle("Can login?", isOn: attrs.canLogin)
                        privilegeToggle("Superuser?", isOn: attrs.superuser)
                        privilegeToggle("Create databases?", isOn: attrs.createDB)
                        privilegeToggle("Create roles?", isOn: attrs.createRole)
                        privilegeToggle("Replication?", isOn: attrs.replication)
                        privilegeToggle("Bypass RLS?", isOn: attrs.bypassRLS)
                        privilegeToggle("Inherit rights from parent roles?", isOn: attrs.inherit)
                    }
                }

                card("CONNECTION & EXPIRY") {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Connection limit (-1 = no limit)")
                                .font(.caption).foregroundStyle(.secondary)
                            TextField(
                                "-1",
                                value: attrs.connectionLimit,
                                format: IntegerFormatStyle<Int32>().grouping(.never)
                            )
                            .textFieldStyle(.plain)
                            .keyboardType(.numbersAndPunctuation)
                            .padding(10)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Valid until (empty = never)")
                                .font(.caption).foregroundStyle(.secondary)
                            TextField("e.g. 2027-01-01", text: attrs.validUntil)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(10)
                                .background(Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                card("MEMBER OF") {
                    membershipList(attrs)
                }

                card("COMMENT") {
                    TextField("Description", text: attrs.comment, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...4)
                        .padding(10)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                card("GENERATED DDL SQL") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Spacer()
                            Button {
                                UIPasteboard.general.string = store.generatedDDL
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .foregroundStyle(MidnightColors.accentCyan)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(store.generatedDDL.isEmpty ? "-- No changes" : store.generatedDDL)
                            .font(.system(.caption2, design: .monospaced))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                if let error = store.applyError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                applyControls
            }
            .padding(.vertical)
        }
    }

    private func membershipList(_ attrs: Binding<PostgresRoleAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if attrs.wrappedValue.memberships.isEmpty {
                Text("Not a member of any role.")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(attrs.memberships) { $membership in
                    HStack(spacing: 10) {
                        Image(systemName: "person.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(membership.role)
                            .font(.system(.callout, design: .monospaced))
                        Spacer()
                        Toggle(isOn: $membership.adminOption) {
                            Text("Admin")
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(.secondary)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: MidnightColors.accentCyan))
                        .fixedSize()
                        Button {
                            attrs.wrappedValue.memberships.removeAll { $0.role == membership.role }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Menu {
                ForEach(store.grantableRoles, id: \.self) { candidate in
                    Button(candidate) {
                        attrs.wrappedValue.memberships.append(
                            PostgresRoleMembership(role: candidate, adminOption: false)
                        )
                    }
                }
            } label: {
                Label("Add membership", systemImage: "plus")
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .foregroundStyle(MidnightColors.accentCyan)
            }
            .disabled(store.grantableRoles.isEmpty)
        }
    }

    private var applyControls: some View {
        HStack(spacing: 12) {
            Button("Revert") { store.revert() }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .disabled(!store.isDirty || store.isApplying)

            if store.applySucceeded && !store.isDirty {
                Label("Changes applied", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    guard let connectionId else { return }
                    Task {
                        if let newName = await store.apply(connectionId: connectionId) {
                            onApplied(newName)
                        }
                    }
                } label: {
                    HStack {
                        if store.isApplying {
                            ProgressView().tint(.black)
                        } else {
                            Text("Execute Changes").font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        !store.isDirty || connectionId == nil
                            ? Color.gray.opacity(0.2) : MidnightColors.accentCyan
                    )
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!store.isDirty || store.isApplying || connectionId == nil)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Card chrome

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(MidnightMobileDesign.FontToken.captionStrong)
                .foregroundStyle(MidnightColors.accentCyan)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func privilegeToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .font(MidnightMobileDesign.FontToken.caption)
        }
        .toggleStyle(SwitchToggleStyle(tint: MidnightColors.accentCyan))
        .padding(.vertical, 2)
    }
}
