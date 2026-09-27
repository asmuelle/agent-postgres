#!/bin/bash
# Xcode build phase script — builds the arm64 Rust static library (macOS 27+
# runs only on Apple silicon, so there is no x86_64 slice).
#
# Add this as a "Run Script" build phase in Xcode:
#   1. Select the PgAgentApp target → Build Phases → + → New Run Script Phase
#   2. Set Shell: /bin/bash
#   3. Paste the path to this script (e.g. "$SRCROOT/build_cargo.sh")
#   4. Move it before "Compile Sources"
#
# Environment variables expected by this script (set by Xcode automatically):
#   SRCROOT       — path to the Xcode project directory ($PROJECT_DIR)
#   CONFIGURATION — Debug or Release
#
# Config (override via Xcode build settings):
#   RUST_PROJECT_DIR — workspace root (default: $SRCROOT/..)
#   RUST_TARGET_DIR  — cargo target (default: $RUST_PROJECT_DIR/target)

set -euo pipefail

# Ensure cargo and rustup can be found in non-interactive environments (e.g. Xcode GUI builds)
export PATH="$HOME/.cargo/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Script lives at <repo>/PgAgentApp/build_cargo.sh — Cargo.toml sits one level up.
RUST_PROJECT_DIR="${RUST_PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUST_TARGET_DIR="${RUST_TARGET_DIR:-${RUST_PROJECT_DIR}/target}"
export CARGO_TARGET_DIR="$RUST_TARGET_DIR"
LIB_NAME="libpg_agent.a"

# Map Xcode CONFIGURATION → cargo profile (flag + directory name).
case "${CONFIGURATION:-Debug}" in
    Release)
        CARGO_FLAG="--release"
        CARGO_PROFILE="release"
        ;;
    *)
        CARGO_FLAG=""
        CARGO_PROFILE="debug"
        ;;
esac

echo "🚀 Building pgAgent Rust library"
echo "   Project:     $RUST_PROJECT_DIR"
echo "   Target:      $RUST_TARGET_DIR"
echo "   Config:      ${CONFIGURATION:-Debug}"
echo "   Profile dir: $CARGO_PROFILE"

cd "$RUST_PROJECT_DIR"

# cargo build accepts an empty $CARGO_FLAG.
cargo build -p pg-agent $CARGO_FLAG --target aarch64-apple-darwin

ARM64_LIB="$RUST_TARGET_DIR/aarch64-apple-darwin/$CARGO_PROFILE/$LIB_NAME"

# Sanity-check before copying so we get a clear error rather than a cryptic one.
if [ ! -f "$ARM64_LIB" ]; then
    echo "❌ Missing static lib: $ARM64_LIB"
    echo "   (cargo build did not produce the expected artifact)"
    exit 1
fi

# project.yml's LIBRARY_SEARCH_PATHS points at target/universal/release (the
# name predates the arm64-only build), so copy the output there for both Debug
# and Release. Different cargo profiles still build into different directories
# above, so this overwrite is safe.
UNIVERSAL_DIR="$RUST_TARGET_DIR/universal/release"
mkdir -p "$UNIVERSAL_DIR"
UNIVERSAL_LIB="$UNIVERSAL_DIR/$LIB_NAME"

cp "$ARM64_LIB" "$UNIVERSAL_LIB"

echo "✅ Static library: $UNIVERSAL_LIB"
echo "   Size: $(du -h "$UNIVERSAL_LIB" | cut -f1)"
echo "   Archs: $(lipo -info "$UNIVERSAL_LIB")"

# ---------------------------------------------------------------------------
# Regenerate Swift bindings whenever ffi.rs/lib.rs changed. Without this,
# every edit to the FFI surface needs a manual `just mac-bindings` run, and
# forgetting trips the uniffi checksum check at app launch with a fatalError.
# ---------------------------------------------------------------------------

BINDINGS_DIR="$SCRIPT_DIR/../bindings"
BINDINGS_SWIFT="$BINDINGS_DIR/pg_agent.swift"
# uniffi-bindgen only reads the library's metadata (it never loads it), so the
# arm64 dylib built above works regardless of the host architecture.
HOST_DYLIB="$RUST_TARGET_DIR/aarch64-apple-darwin/$CARGO_PROFILE/libpg_agent.dylib"

# Skip regen if the bindings file is already newer than every FFI source —
# protects incremental builds from a needless rebuild of the bindgen tool.
needs_regen=0
for src in "$RUST_PROJECT_DIR/src/ffi.rs" \
           "$RUST_PROJECT_DIR/src/lib.rs"; do
    if [ ! -f "$BINDINGS_SWIFT" ] || [ "$src" -nt "$BINDINGS_SWIFT" ]; then
        needs_regen=1
        break
    fi
done

if [ "$needs_regen" -eq 1 ]; then
    UNIFFI_BIN="$RUST_TARGET_DIR/release/uniffi-bindgen"
    if [ ! -x "$UNIFFI_BIN" ]; then
        echo "🔧 Building uniffi-bindgen (one-time)"
        cargo build -p pg-agent --release --bin uniffi-bindgen
    fi

    echo "📝 Regenerating Swift bindings from $HOST_DYLIB"
    "$UNIFFI_BIN" generate \
        --library "$HOST_DYLIB" \
        --language swift \
        --out-dir "$BINDINGS_DIR"

    # Swift's SWIFT_INCLUDE_PATHS auto-discovers `module.modulemap`, not the
    # uniffi-named file — rename in place.
    if [ -f "$BINDINGS_DIR/pg_agentFFI.modulemap" ]; then
        mv -f "$BINDINGS_DIR/pg_agentFFI.modulemap" "$BINDINGS_DIR/module.modulemap"
    fi

    echo "✅ Swift bindings regenerated"
else
    echo "✅ Swift bindings up to date (skipping regen)"
fi
