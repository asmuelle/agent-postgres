// swift-tools-version: 5.9
// pgAgent SPM package — pure-Swift models shared by the native macOS app.
//
// ## Prerequisites
//
//   brew install xcodegen
//
// ## Setup (one-time)
//
//   1. Generate Xcode project:
//        cd pgAgent && xcodegen generate
//
//   2. Open Mc-Ssh.xcodeproj in Xcode
//
//   3. Select the PgAgentApp scheme, choose and macOS target, run
//
// The Xcode app target links the Rust static library directly. This SwiftPM
// package intentionally stays pure Swift so `swift test` can run without a
// prebuilt Cargo artifact or custom library search paths.
//
// ## Generating Swift bindings
//
// After every FFI change:
//
//   cargo build -p pgAgent --release --target aarch64-apple-darwin
//   uniffi-bindgen generate \
//     target/aarch64-apple-darwin/release/libmidnight_ssh.dylib \
//     --language swift \
//     --out-dir bindings
//
// Then add the generated `midnight_sshFFI.h` and `midnight_sshFFI.modulemap`
// to the Xcode project's "Swift Compiler — General" > "Import Paths".

import PackageDescription

let package = Package(
    name: "pgAgent",
    platforms: [
        .macOS(.v11),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "PgAgentMacOS",
            targets: ["PgAgentMacOS"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PgAgentMacOS",
            path: "Sources/PgAgentMacOS"
        ),
        .testTarget(
            name: "PgAgentMacOSTests",
            dependencies: ["PgAgentMacOS"],
            path: "Tests/PgAgentMacOSTests"
        ),
    ]
)
