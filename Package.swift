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
//   cargo build --release --lib
//   cargo run --release --bin uniffi-bindgen -- \
//     generate \
//     --library target/release/libpg_agent.dylib \
//     --language swift \
//     --out-dir bindings
//
// Then add the generated `pg_agentFFI.h` and `pg_agentFFI.modulemap` (renamed to `module.modulemap`)
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
        .library(
            name: "PgAgentOperatorCore",
            targets: ["PgAgentOperatorCore"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PgAgentMacOS",
            path: "Sources/PgAgentMacOS"
        ),
        .target(
            name: "PgAgentOperatorCore",
            path: "PgAgentShared",
            sources: [
                "FleetAlertModel.swift",
                "FleetAlertLifecycleStore.swift",
                "FleetHealthModel.swift",
                "FleetOperatorCore.swift",
                "PostgresBackupCore.swift",
                "PostgresOperatorSafety.swift",
                "PostgresOperationsCore.swift",
                "PostgresStatementClassifier.swift",
                "PostgresStatementSplitter.swift",
            ]
        ),
        .testTarget(
            name: "PgAgentMacOSTests",
            dependencies: ["PgAgentMacOS"],
            path: "Tests/PgAgentMacOSTests"
        ),
        .testTarget(
            name: "PgAgentOperatorCoreTests",
            dependencies: ["PgAgentOperatorCore"],
            path: "Tests/PgAgentOperatorCoreTests"
        ),
    ]
)
