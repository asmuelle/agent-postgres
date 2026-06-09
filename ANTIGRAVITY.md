# 🛰️ pgAgent — Antigravity 2.0 Agentic Playbook

Welcome to `pgAgent`! This repository is designed to be highly compatible with **Antigravity 2.0** agentic workflows. Since this is a hybrid, high-performance project—combining a SwiftUI macOS/iOS interface with a robust Rust core connected via UniFFI—following these procedures will ensure extremely fast, safe, and automated development.

---

## 🗺️ Project Architecture at a Glance

For full architectural details, always consult [AGENTS.md](file:///Users/andreasmuller/projects/experiments/appstore/apps/agent-postgres/AGENTS.md) and [CLAUDE.md](file:///Users/andreasmuller/projects/experiments/appstore/apps/agent-postgres/CLAUDE.md).

```
┌──────────────────────────────────────┐
│  SwiftUI App UI (PgAgentApp/Mobile)   │  ← Web dev aesthetics / @MainActor
└──────────────────┬───────────────────┘
                   │ Swift FFI Facade
┌──────────────────▼───────────────────┐
│     bindings/pg_agent.swift           │  ← GENERATED. DO NOT HAND-EDIT!
└──────────────────┬───────────────────┘
                   │ FFI Boundary (uniffi)
┌──────────────────▼───────────────────┐
│       Rust FFI Surface (src/)        │  ← block_on(async { ... }) Tokio tasks
└──────────────────────────────────────┘
```

---

## ⚡ Antigravity 2.0 Protocol Checklist

### 1. Planning Mode Optimization
When Antigravity goes into **Planning Mode**:
* **Research**: Use the read tools (`grep_search`, `list_dir`, `view_file`) first. Never execute modifying build commands until your plan is approved.
* **Plan Construction**: Create/update the `implementation_plan.md` in the current conversation directory. 
* **Verification Design**: Your verification plans must include:
  * Rust only: `just test-rust` and `just lint`
  * Full project: `just test` (runs both Swift and Rust integration suites)
  * UI modifications: Interactive/manual testing plans for macOS/iPadOS.
* **Execution**: Track progress by marking checkboxes (`[ ]` to `[/]` to `[x]`) in `task.md`.
* **Completion**: Summarize with screenshots/recordings in `walkthrough.md`.

### 2. Specialized Subagent Architectures
Avoid running all operations inside a single, bloated conversation context. The `pgAgent` codebase is highly modular. Leverage the `define_subagent` tool to spawn specialized builders:

* **🖌️ SwiftUI Design & Layout Subagent**:
  * **Role**: `SwiftUI Styling & UX Designer`
  * **Context**: `PgAgentApp/`, `PgAgentMobile/`, `Sources/`
  * **Purpose**: UI modifications, visual alignment, Premium Aesthetics, AppKit view wrappers, and responsive layouts.
  * **Rules**: Always verify visual changes. Maintain `@MainActor` and App Group entitlements.
* **🦀 Rust FFI Engine Subagent**:
  * **Role**: `Rust FFI Engine Architect`
  * **Context**: `src/`, `Cargo.toml`, `build.rs`
  * **Purpose**: Performance, networking, SFTP operations, Postgres explorer queries.
  * **Rules**: Block on async Tokio tasks via `RUNTIME.block_on`. Maintain Rust safety profiles.
* **⛓️ Bindings & Build Subagent**:
  * **Role**: `FFI Bindings & Build Automator`
  * **Context**: `bindings/`, `project.yml`, `justfile`
  * **Purpose**: XcodeGen builds, UniFFI generation, and dependency wiring.
  * **Rules**: Ensure `just mac-bindings` is run immediately after changing any Rust FFI signatures.

Pre-configured subagent blueprints are stored in [.antigravity/subagents/](file:///Users/andreasmuller/projects/experiments/appstore/apps/agent-postgres/.antigravity/subagents/).

### 3. FFI Checksum Protection Rule (CRITICAL)
UniFFI computes unique per-function checksums from Rust signatures and generates matching bindings in `bindings/midnight_ssh.swift`.
> [!WARNING]
> Hand-editing the generated `bindings/pg_agent.swift` is strictly forbidden. Any mismatch between Swift and Rust FFI symbols will cause an immediate crash at startup during `rshellInit()`.
> **To modify FFI signatures safely:**
> 1. Edit the Rust signatures in `src/ffi.rs`.
> 2. Run `just mac-bindings` to regenerate the Swift side.
> 3. Verify the diff and commit both.

### 4. Native OS Notifications & Formatting
Antigravity integrates with the macOS native system:
* Post-tool execution: Swift and Rust code are automatically formatted using `rustfmt` and `swift-format` when utilizing the `scripts/antigravity_hooks.sh` system.
* Background alerts: Long builds (like `just mac-build`) can run in the background. Use `just antigravity-notify "<message>"` to trigger native macOS notification banners and a chime when background operations finish, waking you up immediately.

---

## 🛠️ Essential Commands & Automation

| Command | Action | Recommended Scenario |
|---------|--------|----------------------|
| `just check` | Rust syntax validation | Fast compilation verification |
| `just test-rust` | Cargo test suite | Validating Rust FFI/core logic |
| `just mac-test` | Swift FFI + View tests | Validating Swift wrapper integration |
| `just mac-gen` | Xcode project regeneration | Must run if `project.yml` is modified |
| `just mac-bindings` | UniFFI code generation | Run after any FFI signature edits in `src/ffi.rs` |
| `just test` | Combined Swift + Rust test runner | Final verification before PR/walkthrough |

---

## 🚀 Useful Slash Commands to Recommend

Encourage the user to execute:
* `/goal`: For running deep diagnostic passes or comprehensive FFI refactoring.
* `/grill-me`: For interactive architecture alignment before changing core SSH components.
* `/schedule`: To schedule automated background checks (e.g., cron checks for memory leaks or security audits).
