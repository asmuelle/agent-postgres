# pgAgent Codebase Guide (Claude Code Entry Point)

Welcome to the pgAgent codebase. This is a hybrid SwiftUI (AppKit/iOS) and Rust (FFI via UniFFI) project.

## 🛠️ Quick Commands

- **Full Build (Xcode & Rust)**: `just mac-build`
- **Generate Xcode Project**: `just mac-gen`
- **Regenerate FFI Bindings**: `just mac-bindings`
- **Run All Tests**: `just test`
- **Run Rust Tests**: `just test-rust`
- **Run Swift Tests**: `just mac-test`

## ⚠️ Critical Gotchas & Architecture Rules

1. **FFI Checksum Match**: DO NOT edit `bindings/midnight_ssh.swift` directly. UniFFI bakes in per-function checksums; any signature changes in Rust FFI must be regenerated using `just mac-bindings` and committed immediately, otherwise the app will crash at startup (`rshellInit` FFI checksum mismatch).
2. **XcodeGen Configuration**: The Xcode project (`pgAgent.xcodeproj`) is fully generated from `project.yml`. Never edit Xcode project settings directly in Xcode; modify `project.yml` and run `just mac-gen`.
3. **Rust Threading**: All FFI functions in `src/ffi.rs` hitting the network must use `RUNTIME.block_on(async { ... })` to resolve on the Tokio runtime thread pool.
4. **Swift Styling & UI**: SwiftUI views and dedicated `*Store` / `*Manager` classes handle state. Apply `@MainActor` to any class or function modifying the UI.

## 🔁 Verification Loop (run after edits)

The harness gives you a fast deterministic sensor — use it instead of guessing.

- **Fast check (Rust)**: `just check` — `cargo check --all-targets`. Run after a batch of Rust edits.
- **Strict gate**: `just lint` — `cargo fmt --check` + `cargo clippy -D warnings`. Run before declaring done.
- **Tests**: `just test-rust` (Rust) / `just mac-test` (Swift) / `just test` (both).
- A **Stop hook** auto-runs `just check` when you finish a turn: silent if clean, and it will block + show errors if Rust is broken so you can fix them. Swift changes are not covered there — verify those with `just mac-test` / `just mac-build` yourself.
- Formatting is automatic on save (rustfmt / swift-format via PostToolUse) — don't hand-format.

## 🛡️ Safety Guard (enforced, not advisory)

A PreToolUse guard (`scripts/guard_agent.py`) hard-blocks known footguns. If you see "⛔ Harness guard blocked", read the message — it tells you the correct path:

- Editing generated `bindings/*.swift|h|modulemap` → change `src/ffi.rs` + `just mac-bindings`.
- Editing `pgAgent.xcodeproj` / `*.pbxproj` → edit `project.yml` + `just mac-gen`.
- `rm -rf`, `git push --force`, `git reset --hard`, `git clean -f`, live `DROP`/`TRUNCATE` → confirm with a human / do it narrowly.

## 🪜 Harness Ratchet (keep this file earning its place)

When you hit a *new* class of failure that a rule could have prevented, close the loop: add a one-line rule here (or a guard rule in `scripts/guard_agent.py`, or a memory file) so it can't recur. Every line in this file should trace to a real failure or a hard constraint — prune lines that no longer do.

## 📂 Subsystem Specific Guides

**This file (`CLAUDE.md`) is the always-loaded checklist** — keep it tight. **`AGENTS.md` is the deep on-demand tour** — read it when you need architecture, FFI lifecycle, or the full pitfall list.

- Rust FFI & Core: [src/CLAUDE.md](file:///Users/andreasmuller/experiments/appstore/apps/agent-postgres/src/CLAUDE.md)
- Swift App & UI: [PgAgentApp/CLAUDE.md](file:///Users/andreasmuller/experiments/appstore/apps/agent-postgres/PgAgentApp/CLAUDE.md)
- Deep codebase tour: [AGENTS.md](file:///Users/andreasmuller/experiments/appstore/apps/agent-postgres/AGENTS.md)
