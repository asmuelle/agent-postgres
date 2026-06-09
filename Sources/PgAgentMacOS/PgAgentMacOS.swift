// PgAgentMacOS — pure-Swift models shared by the macOS app target.
//
// ## Architecture
//
// The Rust crate is built by Cargo as a universal static library and
// linked into the **app** target (PgAgentApp). The uniffi-generated Swift
// bindings live at `bindings/pg_agent.swift` and are
// also compiled into the app target — frameworks cannot link the Rust
// static lib directly, so the FFI surface lives where the symbols can
// actually be resolved.
//
// This framework owns only the pure-Swift models (`ConnectionProfile`,
// `WorkspaceLayout`, `LayoutConstants`, …) shared between app sources
// and tests.
//
// ## Bridge lifecycle (in the app target)
//
//   AppDelegate
//     └─ applicationDidFinishLaunching
//          └─ BridgeManager.shared.initialize()
//               ├─ rshell_init()                — create Tokio runtime + ConnectionManager
//               └─ rshell_set_event_callback()  — register event bus listener

import Foundation

/// Logger subsystem identifier used across the app.
public let PgAgentLogSubsystem = "com.mc-ssh"

/// Per-tab live connection state, surfaced from the
/// `connection_status` event-bus payload (`{"status":"..."}`). Drives
/// the status symbol in the workspace tab strip.
public enum TerminalConnectionStatus: String, Sendable, Equatable, Codable {
    case connected
    case disconnected
    case error
    case connecting

    /// Decode from the JSON payload Rust ships
    /// (`{"status":"connected"}` etc.). Anything unrecognised maps to
    /// `error` so we surface the unexpected state rather than silently
    /// dropping it.
    public static func parse(payload: String) -> TerminalConnectionStatus {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["status"] as? String
        else { return .error }
        return TerminalConnectionStatus(rawValue: raw) ?? .error
    }
}

/// Decoded contents of a `pty_output` event-bus payload.
public struct PtyOutputFrame: Equatable, Sendable {
    public let generation: UInt64
    public let data: Data
}

/// Decodes a `pty_output` event-bus payload of the form
/// `{"generation": N, "bytes": [...]}` into a typed frame.
///
/// `generation` is the PTY session counter from `rshell_pty_start` and
/// lets the consumer drop frames whose generation doesn't match the
/// currently registered session — needed because the forwarder task on
/// the Rust side can briefly continue draining an old session's
/// `output_rx` after a new session has been started for the same
/// connection id.
///
/// Returns nil on malformed JSON, missing fields, or out-of-range byte
/// values. The caller logs and drops in that case.
public enum PtyPayloadDecoder {
    public static func decode(_ payload: String) -> PtyOutputFrame? {
        guard let utf8 = payload.data(using: .utf8) else { return nil }

        struct Wire: Decodable {
            let generation: UInt64
            let bytes: [UInt8]
        }

        guard let wire = try? JSONDecoder().decode(Wire.self, from: utf8) else {
            return nil
        }
        return PtyOutputFrame(generation: wire.generation, data: Data(wire.bytes))
    }
}
