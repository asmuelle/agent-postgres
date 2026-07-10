import Foundation
import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresRoleEditorStore — loads a role's attributes + memberships, tracks
// edits against the loaded snapshot, and applies the generated DDL. Shared by
// the macOS and iOS property inspectors; all SQL shaping lives in
// PostgresRoleDDL (pure, tested).
// =============================================================================
@MainActor
final class PostgresRoleEditorStore: ObservableObject {
    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var phase: LoadPhase = .idle
    /// The editable working copy the form binds to.
    @Published var edited: PostgresRoleAttributes?
    /// Every role on the instance except the edited one — membership picker.
    @Published private(set) var availableRoles: [String] = []

    @Published private(set) var isApplying = false
    @Published private(set) var applyError: String?
    @Published private(set) var applySucceeded = false

    private(set) var original: PostgresRoleAttributes?

    var isDirty: Bool {
        guard let original, let edited else { return false }
        return original != edited
    }

    /// The statements the current edits would execute.
    var generatedDDL: String {
        guard let original, let edited else { return "" }
        return PostgresRoleDDL.alterStatements(from: original, to: edited)
            .joined(separator: "\n")
    }

    /// Roles that can still be added as a membership.
    var grantableRoles: [String] {
        guard let edited else { return [] }
        let current = Set(edited.memberships.map(\.role))
        return availableRoles.filter { $0 != edited.name && !current.contains($0) }
    }

    func load(roleName: String, connectionId: String) async {
        phase = .loading
        applyError = nil
        applySucceeded = false
        let sessionId = "role-editor-\(UUID().uuidString)"
        defer {
            Task {
                await BridgeManager.shared.pgReleaseSession(
                    connectionId: connectionId, sessionId: sessionId
                )
            }
        }
        do {
            let attrsResult = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: PostgresRoleDDL.attributesQuery(name: roleName),
                pageSize: 10
            )
            let membersResult = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: PostgresRoleDDL.membershipsQuery(name: roleName),
                pageSize: 500
            )
            let rolesResult = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: PostgresRoleDDL.allRolesQuery,
                pageSize: 1_000
            )
            guard let attrs = PostgresRoleDDL.parse(
                name: roleName,
                attributeRow: attrsResult.rows.first?.cells,
                membershipRows: membersResult.rows.map(\.cells)
            ) else {
                phase = .failed("Role \"\(roleName)\" no longer exists.")
                return
            }
            original = attrs
            edited = attrs
            availableRoles = rolesResult.rows.compactMap { $0.cells.first ?? nil }
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Execute the generated statements one by one (they are order-sensitive
    /// and `pgExecute` runs a single statement), then reload the role under
    /// its possibly-new name. Returns the new name on success.
    @discardableResult
    func apply(connectionId: String) async -> String? {
        guard let original, let edited, isDirty else { return nil }
        let statements = PostgresRoleDDL.alterStatements(from: original, to: edited)
        guard !statements.isEmpty else { return nil }

        isApplying = true
        applyError = nil
        applySucceeded = false
        let sessionId = "role-editor-apply-\(UUID().uuidString)"
        defer {
            isApplying = false
            Task {
                await BridgeManager.shared.pgReleaseSession(
                    connectionId: connectionId, sessionId: sessionId
                )
            }
        }
        for statement in statements {
            do {
                _ = try await BridgeManager.shared.pgExecute(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    sql: statement,
                    pageSize: 10
                )
            } catch {
                // Surface which statement failed — earlier ones have already
                // taken effect, so reload to resync the form with reality.
                applyError = "Failed at: \(statement)\n\(error.localizedDescription)"
                let currentName = original.name
                await load(roleName: currentName, connectionId: connectionId)
                return nil
            }
        }
        let newName = edited.name.trimmingCharacters(in: .whitespaces)
        let finalName = newName.isEmpty ? original.name : newName
        await load(roleName: finalName, connectionId: connectionId)
        applySucceeded = true
        return finalName
    }

    /// Discard edits back to the loaded snapshot.
    func revert() {
        edited = original
        applyError = nil
        applySucceeded = false
    }

    /// One-shot `CREATE ROLE …` reconstruction for DDL-source tabs. Failures
    /// come back as SQL comments so the pane never shows a bare error state.
    static func reconstructCreateDDL(name: String, connectionId: String) async -> String {
        let sessionId = "role-ddl-\(UUID().uuidString)"
        defer {
            Task {
                await BridgeManager.shared.pgReleaseSession(
                    connectionId: connectionId, sessionId: sessionId
                )
            }
        }
        do {
            let attrsResult = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: PostgresRoleDDL.attributesQuery(name: name),
                pageSize: 10
            )
            let membersResult = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: PostgresRoleDDL.membershipsQuery(name: name),
                pageSize: 500
            )
            guard let attrs = PostgresRoleDDL.parse(
                name: name,
                attributeRow: attrsResult.rows.first?.cells,
                membershipRows: membersResult.rows.map(\.cells)
            ) else {
                return "-- Role \(name) not found."
            }
            return PostgresRoleDDL.createStatement(attrs)
        } catch {
            return "-- Failed to fetch role DDL: \(error.localizedDescription)"
        }
    }
}
