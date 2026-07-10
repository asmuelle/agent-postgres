#if os(macOS)
import SwiftUI

// =============================================================================
// PostgresRoleEditorView — pgAdmin-style role property editor (macOS): the
// role's privilege attributes (LOGIN, SUPERUSER, CREATEDB, …), connection
// limit, expiry, comment, and role memberships with ADMIN OPTION. Edits build
// ALTER/GRANT/REVOKE DDL live (PostgresRoleDDL) and apply on demand.
// =============================================================================
struct PostgresRoleEditorView: View {
    let roleName: String
    let connectionId: String?
    /// Invoked after a successful apply with the (possibly renamed) role name
    /// so the owner can refresh the roles tree.
    var onApplied: (String) -> Void = { _ in }

    @StateObject private var store = PostgresRoleEditorStore()

    var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading role…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { reload() }
                }
                .padding()
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

    /// Non-optional binding into `store.edited`, valid only when loaded.
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Role name", text: attrs.name)
                        .textFieldStyle(.roundedBorder)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Privileges").font(.subheadline.bold())
                    Toggle("Can login?", isOn: attrs.canLogin)
                    Toggle("Superuser?", isOn: attrs.superuser)
                    Toggle("Create databases?", isOn: attrs.createDB)
                    Toggle("Create roles?", isOn: attrs.createRole)
                    Toggle("Replication?", isOn: attrs.replication)
                    Toggle("Bypass RLS?", isOn: attrs.bypassRLS)
                    Toggle("Inherit rights from parent roles?", isOn: attrs.inherit)
                }
                .toggleStyle(.checkbox)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Connection & Expiry").font(.subheadline.bold())
                    HStack {
                        Text("Connection limit").font(.caption).foregroundStyle(.secondary)
                        TextField(
                            "-1",
                            value: attrs.connectionLimit,
                            format: IntegerFormatStyle<Int32>().grouping(.never)
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        Text("(-1 = no limit)").font(.caption).foregroundStyle(.tertiary)
                    }
                    HStack {
                        Text("Valid until").font(.caption).foregroundStyle(.secondary)
                        TextField("never (e.g. 2027-01-01)", text: attrs.validUntil)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Divider()

                membershipSection(attrs)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Comment").font(.caption).foregroundStyle(.secondary)
                    TextField("Description", text: attrs.comment, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }

                Divider()

                ddlPreview
                applyControls
            }
            .padding()
        }
    }

    private func membershipSection(_ attrs: Binding<PostgresRoleAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Member of").font(.subheadline.bold())
                Spacer()
                Menu {
                    ForEach(store.grantableRoles, id: \.self) { candidate in
                        Button(candidate) {
                            attrs.wrappedValue.memberships.append(
                                PostgresRoleMembership(role: candidate, adminOption: false)
                            )
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(store.grantableRoles.isEmpty)
            }

            if attrs.wrappedValue.memberships.isEmpty {
                Text("Not a member of any role.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(attrs.memberships) { $membership in
                    HStack {
                        Image(systemName: "person.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(membership.role)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Toggle("Admin", isOn: $membership.adminOption)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .help("WITH ADMIN OPTION — may grant this membership to others")
                        Button {
                            attrs.wrappedValue.memberships.removeAll { $0.role == membership.role }
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Revoke membership")
                    }
                }
            }
        }
    }

    private var ddlPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Real-Time DDL SQL").font(.subheadline.bold())
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.generatedDDL, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.plain)
                .help("Copy SQL")
            }
            Text(store.generatedDDL.isEmpty ? "-- No changes" : store.generatedDDL)
                .font(.system(.caption, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                )
        }
    }

    private var applyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = store.applyError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Revert") { store.revert() }
                    .disabled(!store.isDirty || store.isApplying)
                Spacer()
                if store.applySucceeded && !store.isDirty {
                    Label("Changes applied", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline.bold())
                } else {
                    Button {
                        guard let connectionId else { return }
                        Task {
                            if let newName = await store.apply(connectionId: connectionId) {
                                onApplied(newName)
                            }
                        }
                    } label: {
                        if store.isApplying {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Execute Changes")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.isDirty || store.isApplying || connectionId == nil)
                }
            }
        }
    }
}
#endif
