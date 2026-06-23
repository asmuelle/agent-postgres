# pgAgent command surface — native macOS + iPadOS app.
#
# Install `just` once: `brew install just`. Run `just` (no args) to see all
# recipes. Naming convention:
#
#   <verb>          — workspace-wide (e.g. `check`, `test`, `fmt`)
#   mac-<verb>      — native macOS build
#   ios-<verb>      — native iPadOS / iOS build

set shell := ["bash", "-euc"]
set dotenv-load := false

# Paths
xcode_proj  := "pgAgent.xcodeproj"
mac_scheme  := "PgAgentApp"
mac_fw      := "PgAgentMacOS"
ios_scheme  := "PgAgentMobile"
ios_bundle  := "com.pgagent.mobile"
ios_sim_dd  := "/private/tmp/pgAgent-ios-dd"
ios_sim_app := ios_sim_dd + "/Build/Products/Debug-iphonesimulator/pgAgent.app"
mac_build   := env_var_or_default("APG_MAC_DERIVED_DATA", ".derivedData/macos")
mac_app     := mac_build + "/Build/Products/Release/pgAgent.app"
mac_debug_app := mac_build + "/Build/Products/Debug/pgAgent.app"
universal   := "target/universal/release/libpg_agent.a"


# ─── default: list recipes ──────────────────────────────────────────────

default:
    @just --list --unsorted


# ─── workspace ──────────────────────────────────────────────────────────

# One-time prerequisites for everything (macOS + iOS toolchains, xcodegen).
bootstrap: mac-bootstrap ios-bootstrap
    @echo "✅ Bootstrapped"

# Cargo check for the FFI crate (faster than build).
check:
    cargo check --all-targets

# Run Rust + Swift tests.
test: test-rust mac-test

test-rust:
    cargo test --all-targets

# Format Rust.
fmt:
    cargo fmt --all

# Strict lint pass — fails CI if anything is off.
lint:
    cargo fmt --all --check
    cargo clippy --all-targets -- -D warnings
    @command -v swift-format >/dev/null 2>&1 && (swift-format lint -r Sources Tests PgAgentApp PgAgentMobile PgAgentWidgets || xcrun swift-format lint -r Sources Tests PgAgentApp PgAgentMobile PgAgentWidgets) 2>/dev/null || echo "⚠️ swift-format not installed; skipping Swift lint"

# Local equivalent of CI checks that don't need signing certs.
ci-local: check test-rust mac-ci-build ios-ci-build
    @echo "✅ Local CI checks completed"

# Wipe Cargo + macOS + iOS build artifacts.
clean: mac-clean ios-clean
    cargo clean
    @echo "✅ Cleaned build artifacts"


# ─── native macOS build ─────────────────────────────────────────────────

# One-time prerequisites for the native macOS build.
mac-bootstrap:
    @command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
    rustup target add aarch64-apple-darwin x86_64-apple-darwin
    @echo "✅ macOS prereqs installed"

# Regenerate pgAgent.xcodeproj from project.yml. Run after editing project.yml.
mac-gen:
    xcodegen generate

# Build the universal Rust static lib (lipo'd, no Xcode link step).
mac-rust:
    cargo build --release --target aarch64-apple-darwin
    cargo build --release --target x86_64-apple-darwin
    mkdir -p target/universal/release
    lipo -create \
        target/aarch64-apple-darwin/release/libpg_agent.a \
        target/x86_64-apple-darwin/release/libpg_agent.a \
        -output {{universal}}
    @echo "✅ Universal static lib: {{universal}}"

# Local signed .app build. The widget/App Group entitlement requires a
# provisioning profile, so use development signing when a Team ID is set.
mac-build config="Release":
    @team="${DEVELOPMENT_TEAM:-${APPLE_DEVELOPMENT_TEAM:-}}"; \
      if [ -z "$team" ]; then \
        echo "❌ App Group/widget entitlements require development signing."; \
        echo "   Run: APPLE_DEVELOPMENT_TEAM=<Apple Team ID> just mac-build"; \
        echo "   For compiler-only validation without signing, run: just mac-ci-build"; \
        exit 1; \
      fi; \
      APPLE_DEVELOPMENT_TEAM="$team" just mac-build-dev "{{config}}"
    @echo "✅ Built {{mac_app}}"

# Development-signed app build for local widget/App Group testing.
# Set DEVELOPMENT_TEAM or APPLE_DEVELOPMENT_TEAM to your Apple Developer Team ID.
mac-build-dev config="Debug":
    @just _ensure-xcodeproj
    @team="${DEVELOPMENT_TEAM:-${APPLE_DEVELOPMENT_TEAM:-}}"; \
      test -n "$team" || (echo "❌ Set DEVELOPMENT_TEAM=<Apple Team ID> or APPLE_DEVELOPMENT_TEAM=<Apple Team ID>"; exit 1); \
      xcodebuild \
        -allowProvisioningUpdates \
        -project {{xcode_proj}} \
        -scheme {{mac_scheme}} \
        -configuration {{config}} \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath {{mac_build}} \
        CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M%S)" \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM="$team" \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGNING_ALLOWED=YES \
        build
    @echo "✅ Built development-signed app"

# CI-style app build without signing. Use this for compiler validation
# in environments without a Developer ID certificate.
mac-ci-build:
    @just _ensure-xcodeproj
    xcodebuild \
        -project {{xcode_proj}} \
        -scheme {{mac_scheme}} \
        -destination 'platform=macOS' \
        -derivedDataPath /private/tmp/pgAgent-dd \
        CODE_SIGNING_ALLOWED=NO \
        build

# Build with a real Developer ID (requires APPLE_SIGNING_IDENTITY env).
mac-build-signed:
    @just _ensure-xcodeproj
    @test -n "${APPLE_SIGNING_IDENTITY:-}" || (echo "❌ APPLE_SIGNING_IDENTITY not set"; exit 1)
    xcodebuild \
        -project {{xcode_proj}} \
        -scheme {{mac_scheme}} \
        -configuration Release \
        -derivedDataPath {{mac_build}} \
        CODE_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY" \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGNING_ALLOWED=YES \
        OTHER_CODE_SIGN_FLAGS="--timestamp" \
        build

# Build and open the development-signed app.
mac-run:
    @just mac-build
    touch {{mac_app}}
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R {{mac_app}}
    open {{mac_app}}

# Build and open a development-signed app so WidgetKit can load the extension.
mac-run-dev:
    @just mac-build-dev
    touch {{mac_debug_app}}
    osascript -e 'tell application id "com.pgagent.macos" to quit' >/dev/null 2>&1 || true
    pkill -f 'PgAgentWidgets' >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Containers/com.pgagent.macos.widgets/Data/SystemData/com.apple.chrono" || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R {{mac_debug_app}}
    pluginkit -r {{mac_debug_app}}/Contents/PlugIns/PgAgentWidgets.appex || true
    pluginkit -a {{mac_debug_app}}/Contents/PlugIns/PgAgentWidgets.appex || true
    killall chronod >/dev/null 2>&1 || true
    open {{mac_debug_app}}

# xcodebuild test — runs the framework scheme (pure-Swift unit tests over
# PgAgentMacOS models + helpers) and the app scheme (FFI integration tests
# that exercise the uniffi bindings inside the app's process).
mac-test:
    @just _ensure-xcodeproj
    xcodebuild test \
        -project {{xcode_proj}} \
        -scheme {{mac_fw}} \
        -destination 'platform=macOS'
    xcodebuild test \
        -project {{xcode_proj}} \
        -scheme {{mac_scheme}} \
        -destination 'platform=macOS' \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGNING_ALLOWED=YES

# Verify the .app's signature & Gatekeeper status.
mac-verify:
    @test -d {{mac_app}} || (echo "❌ {{mac_app}} not found"; exit 1)
    codesign -dv --verbose=4 {{mac_app}} 2>&1 | grep -E '(Identifier|Authority|Signature|TeamIdentifier)' || true
    @echo "---"
    codesign --verify --deep --strict --verbose=2 {{mac_app}}
    @echo "---"
    spctl -a -t exec -vv {{mac_app}} || true

# Regenerate Swift FFI bindings (run after changing src/).
# Uses the crate-local uniffi-bindgen bin so the version is pinned to the
# crate's uniffi dependency — no global install drift.
mac-bindings:
    cargo build --release --lib
    cargo run --release --bin uniffi-bindgen -- \
        generate \
        --library target/release/libpg_agent.dylib \
        --language swift \
        --out-dir bindings
    # Swift auto-discovers `module.modulemap` along SWIFT_INCLUDE_PATHS;
    # the uniffi-named file would be ignored, so rename in place.
    mv -f bindings/pg_agentFFI.modulemap \
          bindings/module.modulemap
    @echo "✅ Swift bindings written to bindings/"

# Package the built .app as a DMG.
mac-dmg:
    @test -d {{mac_app}} || (echo "❌ {{mac_app}} not found — run 'just mac-build' first"; exit 1)
    bash PgAgentApp/build_dmg.sh {{mac_app}}

# Build a local release bundle: clean build, DMG, checksum, release notes,
# and an optional notarization pass when Apple credentials are available.
mac-release notarize="false":
    scripts/mac_release.sh "{{notarize}}"

# Print the Sparkle EdDSA public key for Info.plist. Run once after the
# Swift package has resolved, then keep the private key safe in Keychain.
mac-sparkle-keygen:
    "$(scripts/find_sparkle_tool.sh generate_keys)"

# Generate a Sparkle appcast from a folder that contains release DMGs.
mac-sparkle-appcast release_dir:
    "$(scripts/find_sparkle_tool.sh generate_appcast)" "{{release_dir}}"

# Submit an already-built DMG to Apple notarization and staple the ticket.
mac-notarize dmg:
    @test -f "{{dmg}}" || (echo "❌ DMG not found: {{dmg}}"; exit 1)
    @test -n "${APPLE_ID:-}" || (echo "❌ APPLE_ID not set"; exit 1)
    @test -n "${APPLE_TEAM_ID:-}" || (echo "❌ APPLE_TEAM_ID not set"; exit 1)
    @test -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" || (echo "❌ APPLE_APP_SPECIFIC_PASSWORD not set"; exit 1)
    xcrun notarytool submit "{{dmg}}" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait
    xcrun stapler staple "{{dmg}}"
    spctl -a -t open -vv "{{dmg}}"

# Open pgAgent.xcodeproj in Xcode.
mac-open:
    @just _ensure-xcodeproj
    open {{xcode_proj}}

# Clean only macOS build outputs.
mac-clean:
    rm -rf {{mac_build}}
    rm -rf target/universal
    rm -rf target/aarch64-apple-darwin target/x86_64-apple-darwin
    @echo "✅ macOS build artifacts cleaned"


# ─── native iPadOS / iOS build ──────────────────────────────────────────

# One-time prerequisites for the iPadOS / iOS build.
ios-bootstrap:
    @command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
    rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
    @echo "✅ iOS / iPadOS prereqs installed"

_ios-sim-rust config="Debug":
    @rust_arch="$(uname -m)"; \
      case "$rust_arch" in \
        arm64|x86_64) ;; \
        *) echo "Unsupported simulator host arch: $rust_arch"; exit 1 ;; \
      esac; \
      PLATFORM_NAME=iphonesimulator ARCHS="$rust_arch" CONFIGURATION="{{config}}" bash scripts/build_cargo_ios.sh

_ios-device-rust config="Debug":
    @PLATFORM_NAME=iphoneos ARCHS=arm64 CONFIGURATION="{{config}}" bash scripts/build_cargo_ios.sh

# Build the iOS simulator app without signing. Use this for compiler validation.
ios-ci-build:
    @just _ensure-xcodeproj
    @just _ios-sim-rust Debug
    @rust_arch="$(uname -m)"; \
      case "$rust_arch" in \
        arm64|x86_64) ;; \
        *) echo "Unsupported simulator host arch: $rust_arch"; exit 1 ;; \
      esac; \
      xcodebuild \
        -project {{xcode_proj}} \
        -scheme {{ios_scheme}} \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath {{ios_sim_dd}} \
        ARCHS="$rust_arch" \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGNING_ALLOWED=NO \
        build

# Build the iOS simulator app signed for local launch. Keychain APIs need the
# simulator entitlements emitted by Xcode, so this is separate from CI build.
ios-sim-build:
    @just _ensure-xcodeproj
    @just _ios-sim-rust Debug
    @rust_arch="$(uname -m)"; \
      case "$rust_arch" in \
        arm64|x86_64) ;; \
        *) echo "Unsupported simulator host arch: $rust_arch"; exit 1 ;; \
      esac; \
      xcodebuild \
        -project {{xcode_proj}} \
        -scheme {{ios_scheme}} \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath {{ios_sim_dd}} \
        ARCHS="$rust_arch" \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGN_IDENTITY="-" \
        build

# Build, install, and launch on an iPad simulator. Pass a simulator name
# fragment if you want a specific iPad, e.g. `just run-on-ipad "iPad Pro"`.
run-on-ipad name="":
    @just ios-sim-build
    @app="{{ios_sim_app}}"; \
    bundle="{{ios_bundle}}"; \
    name="{{name}}"; \
    test -d "$app" || (echo "iOS simulator app not found: $app"; exit 1); \
    if [ -n "$name" ]; then \
        udid="$(xcrun simctl list devices available | grep 'iPad' | grep -F "$name" | sed -nE 's/.*\(([0-9A-F-]{36})\).*/\1/p' | head -n1 || true)"; \
    else \
        udid="$(xcrun simctl list devices available | grep 'iPad' | grep 'Booted' | sed -nE 's/.*\(([0-9A-F-]{36})\).*/\1/p' | head -n1 || true)"; \
        if [ -z "$udid" ]; then \
            udid="$(xcrun simctl list devices available | grep 'iPad' | sed -nE 's/.*\(([0-9A-F-]{36})\).*/\1/p' | head -n1 || true)"; \
        fi; \
    fi; \
    test -n "$udid" || (echo "No available iPad simulator found"; xcrun simctl list devices available; exit 1); \
    if ! xcrun simctl list devices | grep "$udid" | grep -q 'Booted'; then \
        xcrun simctl boot "$udid" || true; \
        xcrun simctl bootstatus "$udid" -b; \
    fi; \
    open -a Simulator; \
    xcrun simctl install "$udid" "$app"; \
    xcrun simctl launch "$udid" "$bundle"; \
    echo "Launched pgAgent on iPad simulator $udid"

# Build, install, and launch on an iPhone simulator. Pass a simulator name
# fragment if you want a specific iPhone, e.g. `just run-on-iphone "iPhone 16 Pro"`.
run-on-iphone name="":
    @just ios-sim-build
    @app="{{ios_sim_app}}"; \
    bundle="{{ios_bundle}}"; \
    name="{{name}}"; \
    test -d "$app" || (echo "iOS simulator app not found: $app"; exit 1); \
    if [ -n "$name" ]; then \
        udid="$(xcrun simctl list devices available | grep 'iPhone' | grep -F "$name" | sed -nE 's/.*\(([0-9A-F-]{36})\).*/\1/p' | head -n1 || true)"; \
    else \
        udid="$(xcrun simctl list devices available | grep 'iPhone' | grep 'Booted' | sed -nE 's/.*\(([0-9A-F-]{36})\).*/\1/p' | head -n1 || true)"; \
        if [ -z "$udid" ]; then \
            udid="$(xcrun simctl list devices available | grep 'iPhone' | sed -nE 's/.*\(([0-9A-F-]{36})\).*/\1/p' | head -n1 || true)"; \
        fi; \
    fi; \
    test -n "$udid" || (echo "No available iPhone simulator found"; xcrun simctl list devices available; exit 1); \
    if ! xcrun simctl list devices | grep "$udid" | grep -q 'Booted'; then \
        xcrun simctl boot "$udid" || true; \
        xcrun simctl bootstatus "$udid" -b; \
    fi; \
    open -a Simulator; \
    xcrun simctl install "$udid" "$app"; \
    xcrun simctl launch "$udid" "$bundle"; \
    echo "Launched pgAgent on iPhone simulator $udid"

# Build the iOS app for a connected device or archive workflow.
ios-build config="Debug":
    @just _ensure-xcodeproj
    @just _ios-device-rust "{{config}}"
    xcodebuild \
        -project {{xcode_proj}} \
        -scheme {{ios_scheme}} \
        -configuration {{config}} \
        -destination 'generic/platform=iOS' \
        -derivedDataPath /private/tmp/pgAgent-ios-device-dd \
        ARCHS=arm64 \
        build

# Clean only iOS build outputs.
ios-clean:
    rm -rf {{ios_sim_dd}} /private/tmp/pgAgent-ios-device-dd
    rm -rf target/ios target/universal-ios
    rm -rf target/aarch64-apple-ios target/aarch64-apple-ios-sim target/x86_64-apple-ios
    @echo "✅ iOS build artifacts cleaned"


# ─── private helpers ────────────────────────────────────────────────────

_ensure-xcodeproj:
    @if [ ! -d {{xcode_proj}} ] || \
        [ project.yml -nt {{xcode_proj}}/project.pbxproj ] || \
        find PgAgentApp PgAgentMobile PgAgentWidgets PgAgentMobileWidgets Sources Tests -name '*.swift' -newer {{xcode_proj}}/project.pbxproj | grep -q .; then \
        just mac-gen; \
    fi

# ─── antigravity 2.0 agent optimizations ────────────────────────────────

# Bootstraps the workspace and verifies developer toolchains for Antigravity.
antigravity-bootstrap:
    @echo "🛰️ Bootstrapping Antigravity 2.0 Agentic Environment..."
    @command -v xcodebuild >/dev/null 2>&1 || (echo "❌ Xcode Command Line Tools not found!"; exit 1)
    @command -v cargo >/dev/null 2>&1 || (echo "❌ Rust/Cargo not found!"; exit 1)
    @command -v xcodegen >/dev/null 2>&1 || (echo "⚠️ xcodegen not found! Attempting bootstrap..."; just mac-bootstrap)
    @echo "📦 Generating Xcode Project..."
    @just mac-gen
    @echo "🧹 Checking file formatters..."
    @command -v rustfmt >/dev/null 2>&1 && echo "✅ rustfmt is available" || echo "⚠️ rustfmt is missing (run 'rustup component add rustfmt')"
    @command -v swift-format >/dev/null 2>&1 && echo "✅ swift-format is available" || echo "⚠️ swift-format is missing (install via Homebrew or Swift Toolchain)"
    @echo "🎉 Antigravity Bootstrap Complete! Workspace is optimized."

# Dispatches a native macOS user notification.
antigravity-notify title msg status="true":
    @./scripts/antigravity_hooks.sh notify "{{title}}" "{{msg}}" "{{status}}"

# Formats a single file (Swift or Rust) in-place.
antigravity-format file:
    @./scripts/antigravity_hooks.sh format "{{file}}"

# Runs a full project build (CI compilation without certificates) and notifies on completion.
antigravity-build-app:
    @echo "🛰️ Starting full project build in background..."
    @if just mac-ci-build; then \
        just antigravity-notify "Antigravity Build" "Build completed successfully!" "true"; \
    else \
        just antigravity-notify "Antigravity Build" "Build failed. Check build logs." "false"; \
        exit 1; \
    fi

# Runs the complete Swift + Rust test suites and notifies on completion.
antigravity-run-tests:
    @echo "🛰️ Executing full test suites..."
    @if just test; then \
        just antigravity-notify "Antigravity Tests" "All tests passed successfully!" "true"; \
    else \
        just antigravity-notify "Antigravity Tests" "Some tests failed. Check logs." "false"; \
        exit 1; \
    fi
