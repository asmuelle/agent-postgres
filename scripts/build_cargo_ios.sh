#!/bin/bash
# Xcode build phase script: builds the Rust bridge for iOS/iPadOS.
#
# The macOS app links a universal Darwin static library from
# target/universal/release. iOS needs a different archive because simulator and
# device targets use iOS triples. This script builds only the architecture(s)
# Xcode asks for, then writes a lipo archive to target/ios/universal-ios/release
# so project.yml can use one stable LIBRARY_SEARCH_PATHS entry.

set -euo pipefail

# Ensure cargo and rustup can be found in non-interactive environments (e.g. Xcode GUI builds)
export PATH="$HOME/.cargo/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Script lives at <repo>/scripts/build_cargo_ios.sh — Cargo.toml sits one level up.
RUST_PROJECT_DIR="${RUST_PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUST_TARGET_DIR="${RUST_TARGET_DIR:-${RUST_PROJECT_DIR}/target/ios}"
export CARGO_TARGET_DIR="$RUST_TARGET_DIR"
LIB_NAME="libpg_agent.a"
CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}"
UNIVERSAL_DIR="$RUST_TARGET_DIR/universal-ios/release"
UNIVERSAL_LIB="$UNIVERSAL_DIR/$LIB_NAME"

case "${CONFIGURATION:-Debug}" in
    Release)
        CARGO_FLAG="--release"
        CARGO_PROFILE="release"
        ;;
    *)
        CARGO_FLAG=""
        CARGO_PROFILE="debug"
        # The iOS bridge pulls in OpenSSL/ring/Arrow/ICU through the external
        # core crates. In Xcode, parallel Rust debug builds can get jetsam-killed
        # before the compiler emits a useful error. Keep Swift debuggability, but
        # avoid Rust dependency debuginfo unless a developer opts back in.
        export CARGO_PROFILE_DEV_DEBUG="${CARGO_PROFILE_DEV_DEBUG:-0}"
        ;;
esac

platform="${PLATFORM_NAME:-iphonesimulator}"
archs="${ARCHS:-arm64}"

rust_target_for_arch() {
    local arch="$1"
    case "$platform:$arch" in
        iphoneos:arm64) echo "aarch64-apple-ios" ;;
        iphonesimulator:arm64) echo "aarch64-apple-ios-sim" ;;
        iphonesimulator:x86_64) echo "x86_64-apple-ios" ;;
        *)
            echo "unsupported iOS Rust target for PLATFORM_NAME=$platform ARCH=$arch" >&2
            return 1
            ;;
    esac
}

ensure_rust_target() {
    local triple="$1"
    if ! rustup target list --installed | grep -qx "$triple"; then
        echo "Missing Rust target: $triple"
        echo "   Install it with: rustup target add $triple"
        exit 1
    fi
}

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

rust_inputs_are_newer_than_universal_lib() {
    [ ! -f "$UNIVERSAL_LIB" ] && return 0
    find "$RUST_PROJECT_DIR/src" \
         "$RUST_PROJECT_DIR/Cargo.toml" \
         "$RUST_PROJECT_DIR/Cargo.lock" \
         "$RUST_PROJECT_DIR/build.rs" \
         "$RUST_PROJECT_DIR/uniffi-bindgen.rs" \
         -newer "$UNIVERSAL_LIB" | grep -q .
}

verify_prebuilt_static_lib() {
    if [ ! -f "$UNIVERSAL_LIB" ]; then
        echo "Missing prebuilt iOS static library: $UNIVERSAL_LIB"
        echo "Build it first with: PLATFORM_NAME=$platform ARCHS=\"$archs\" CONFIGURATION=${CONFIGURATION:-Debug} bash scripts/build_cargo_ios.sh"
        exit 1
    fi

    if command -v lipo >/dev/null 2>&1; then
        for arch in $archs; do
            if ! lipo "$UNIVERSAL_LIB" -verify_arch "$arch" >/dev/null 2>&1; then
                echo "Prebuilt iOS static library does not contain architecture '$arch': $UNIVERSAL_LIB"
                lipo -info "$UNIVERSAL_LIB" || true
                echo "Rebuild it with: PLATFORM_NAME=$platform ARCHS=\"$archs\" CONFIGURATION=${CONFIGURATION:-Debug} bash scripts/build_cargo_ios.sh"
                exit 1
            fi
        done
    fi
}

echo "Building pgAgent Rust library for iOS"
echo "   Project:  $RUST_PROJECT_DIR"
echo "   Target:   $RUST_TARGET_DIR"
echo "   Platform: $platform"
echo "   Archs:    $archs"
echo "   Config:   ${CONFIGURATION:-Debug}"
echo "   Jobs:     $CARGO_BUILD_JOBS"

cd "$RUST_PROJECT_DIR"

if is_truthy "${AGENT_POSTGRES_XCODE_PHASE:-}" || is_truthy "${AGENT_POSTGRES_SKIP_RUST_BUILD:-${SKIP_RUST_BUILD:-}}"; then
    verify_prebuilt_static_lib
    echo "Reusing prebuilt iOS static library: $UNIVERSAL_LIB"
    exit 0
fi

if [ -f "$UNIVERSAL_LIB" ] && ! rust_inputs_are_newer_than_universal_lib; then
    verify_prebuilt_static_lib
    echo "iOS static library up to date: $UNIVERSAL_LIB"
    exit 0
fi

libs=()
for arch in $archs; do
    triple="$(rust_target_for_arch "$arch")"
    ensure_rust_target "$triple"
    cargo build -p pg-agent --jobs "$CARGO_BUILD_JOBS" $CARGO_FLAG --target "$triple"

    lib="$RUST_TARGET_DIR/$triple/$CARGO_PROFILE/$LIB_NAME"
    if [ ! -f "$lib" ]; then
        echo "Missing static lib: $lib"
        exit 1
    fi
    libs+=("$lib")
done

mkdir -p "$UNIVERSAL_DIR"

if [ "${#libs[@]}" -eq 1 ]; then
    cp -f "${libs[0]}" "$UNIVERSAL_LIB"
else
    lipo -create "${libs[@]}" -output "$UNIVERSAL_LIB"
fi

echo "iOS static library: $UNIVERSAL_LIB"
if command -v lipo >/dev/null 2>&1; then
    echo "   Archs: $(lipo -info "$UNIVERSAL_LIB")"
fi

# Keep Swift bindings fresh using a host macOS dylib. UniFFI's Swift file and C
# header are platform-neutral for this bridge; only the linked static library is
# platform-specific.
BINDINGS_DIR="$SCRIPT_DIR/../bindings"
BINDINGS_SWIFT="$BINDINGS_DIR/pg_agent.swift"
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    arm64) HOST_TARGET="aarch64-apple-darwin" ;;
    x86_64) HOST_TARGET="x86_64-apple-darwin" ;;
    *) echo "Unknown host architecture: $HOST_ARCH"; exit 1 ;;
esac
HOST_DYLIB="$RUST_TARGET_DIR/$HOST_TARGET/$CARGO_PROFILE/libpg_agent.dylib"

needs_regen=0
for src in "$RUST_PROJECT_DIR/src/ffi.rs" \
           "$RUST_PROJECT_DIR/src/lib.rs"; do
    if [ ! -f "$BINDINGS_SWIFT" ] || [ "$src" -nt "$BINDINGS_SWIFT" ]; then
        needs_regen=1
        break
    fi
done

if [ "$needs_regen" -eq 1 ]; then
    ensure_rust_target "$HOST_TARGET"
    cargo build -p pg-agent --jobs "$CARGO_BUILD_JOBS" $CARGO_FLAG --target "$HOST_TARGET"

    UNIFFI_BIN="$RUST_TARGET_DIR/release/uniffi-bindgen"
    if [ ! -x "$UNIFFI_BIN" ]; then
        cargo build -p pg-agent --jobs "$CARGO_BUILD_JOBS" --release --bin uniffi-bindgen
    fi

    "$UNIFFI_BIN" generate \
        --library "$HOST_DYLIB" \
        --language swift \
        --out-dir "$BINDINGS_DIR"

    if [ -f "$BINDINGS_DIR/pg_agentFFI.modulemap" ]; then
        mv -f "$BINDINGS_DIR/pg_agentFFI.modulemap" "$BINDINGS_DIR/module.modulemap"
    fi
    echo "Swift bindings regenerated"
else
    echo "Swift bindings up to date (skipping regen)"
fi
