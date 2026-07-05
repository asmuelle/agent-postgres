import ActivityKit
import Foundation

// =============================================================================
// PgOperationActivityAttributes — the Live Activity contract for long-running
// Postgres operations (VACUUM / fixes / health checks) surfaced on the lock
// screen and in the Dynamic Island.
//
// ⚠️ Dual-target file: compiled into BOTH PgAgentMobile (via the group source
// entry) and PgAgentMobileWidgets (via an explicit per-file entry in
// project.yml). ActivityKit matches activities across processes by the encoded
// attribute payload, so both sides must build the exact same type.
// =============================================================================

struct PgOperationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Human phase label, e.g. "Running", "Done", "Failed".
        var phase: String
        /// When the operation actually started — drives the elapsed timer text.
        var startedAt: Date
        /// 0…1 for determinate work; nil renders elapsed time instead.
        var progress: Double?
        /// Optional extra line (error message, row counts, …).
        var detail: String?
        /// nil while running; set on end so the UI can color success/failure.
        var succeeded: Bool?
    }

    /// e.g. "VACUUM ANALYZE", "VACUUM FULL", "Fix", "Health check".
    var operationKind: String
    /// Profile display name, e.g. "steel-prod".
    var instanceName: String
    /// Optional object the operation targets, e.g. "public.orders".
    var targetName: String?
}
