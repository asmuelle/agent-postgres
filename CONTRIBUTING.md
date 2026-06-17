# Contributing to pgAgent

Thanks for your interest in pgAgent — a native macOS & iPadOS workspace for
PostgreSQL and SSH, built with SwiftUI/AppKit over a Rust core via
[UniFFI](https://mozilla.github.io/uniffi-rs/).

This document covers how to get set up, the conventions the codebase follows,
and what a mergeable pull request looks like. Please also read the
[Contributor License Agreement](CLA.md) — opening a PR signals your agreement to
it.

## License

pgAgent is licensed under the **GNU Affero General Public License v3.0**
([LICENSE](LICENSE)). By contributing you agree that your contribution is
provided under those terms, and under the additional grant in [CLA.md](CLA.md).
Note the AGPL's network clause (§13): if you run a modified version that users
interact with over a network, you must offer them its source.

## Getting set up

Prerequisites (macOS):

- macOS 14+ with Xcode 15+ and command-line tools (`xcode-select --install`)
- Rust **1.95+** (edition 2024) — `rustup default stable`
- [`just`](https://github.com/casey/just) — `brew install just`
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

```bash
just bootstrap     # one-time: xcodegen + macOS + iOS Rust targets
just mac-build     # build the native macOS app
just mac-run       # build & launch
just               # list every recipe
```

The Xcode project is **generated** from `project.yml` by xcodegen — never edit
project settings in Xcode directly. After pulling commits that add or remove
Swift files, re-run `just mac-gen`.

## The two gotchas that will bite you

1. **FFI bindings are generated and checksum-verified.** Don't hand-edit
   `bindings/*`. Change `src/ffi.rs` (or `src/lib.rs`), then regenerate and
   commit the bindings:
   ```bash
   just mac-bindings
   just mac-build
   ```
   Hand-patching a binding appears to work but diverges the per-function uniffi
   checksums from what the Rust lib reports at runtime, and the app panics at
   startup.

2. **All network-touching FFI runs on the Tokio runtime.** FFI functions in
   `src/ffi.rs` that hit the network must resolve on the runtime thread pool
   (`RUNTIME.block_on(async { … })`), not the calling thread.

## Conventions

- **Swift:** SwiftUI views + dedicated `*Store` / `*Manager` classes for state.
  Annotate any UI-mutating class or method with `@MainActor`; do off-main work
  with structured concurrency. Prefer `let`; value types by default.
- **Rust:** keep the FFI surface in `src/ffi.rs`; the heavy lifting lives in the
  `ssh-commander-core` crate. Handle errors explicitly — no `unwrap()` on
  fallible I/O.
- **SQL that mutates the catalog** (DDL, GRANT, etc.) must be injection-safe:
  quote identifiers and literals through the existing helpers, and prefer the
  transactional, review-before-commit paths (see the routine editor) over firing
  destructive statements directly.
- **Files small and focused** (≈200–400 lines, 800 max); organize by feature.
- **Commits:** Conventional Commits — `feat:`, `fix:`, `refactor:`, `docs:`,
  `test:`, `chore:`, `perf:`, `ci:`.

## Before you open a PR

Run the local checks and make them pass:

```bash
just lint        # cargo fmt --check + clippy -D warnings
just test-rust   # Rust unit/integration tests
just mac-test    # Swift tests
just ci-local    # the full local CI pass
```

A good PR:

- does one thing, with a clear title and a description of the *why*;
- adds or updates tests for new behavior (pure logic especially — the Swift
  layers extract testable helpers for exactly this reason);
- keeps the build green (`just check` runs on save and at session end);
- regenerates `bindings/` and the Xcode project if the FFI or file set changed;
- includes a short test plan (what you ran, what you observed).

Database-affecting features should be validated against a real PostgreSQL
instance, not just unit tests — say which version in the PR.

## Reporting bugs & proposing features

Open a GitHub issue with steps to reproduce (and your macOS / Postgres / Xcode
versions for bugs). For larger changes, open an issue to discuss the approach
before investing in a big PR.

## Code of conduct

Be respectful and constructive. Harassment or abuse isn't tolerated; maintainers
may remove comments, commits, or contributors that violate this.
