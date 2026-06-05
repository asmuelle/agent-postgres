# Rust FFI & Core Guidelines

This directory contains the UniFFI bridge, ffi runtime, and glue code connecting to `ssh-commander-core`.

## 🛠️ Local Commands
- **Test Core**: `cargo test`
- **Run Rust Tests (via Just)**: `just test-rust`
- **Build universal static library**: `just mac-rust`

## 🎨 Rust Style & Design Conventions
- **Naming**: `PascalCase` for types, `snake_case` for functions/variables.
- **Error Handling**: Use `Result<T, FfiPgError>` at the FFI boundary, and `anyhow::Result<T>` internally. Translate internal errors to readable strings or custom FfiPgError variants.
- **FFI Structure**: Define new exported functions in `src/ffi.rs` annotated with `#[uniffi::export]`. Ensure the static Tokio `RUNTIME` in `src/bridge.rs` is utilized for blocking executions.
