# Swift App & UI Guidelines

This directory contains the SwiftUI views, AppKit window shells, and feature controllers.

## 🛠️ Local Commands
- **Run SwiftUI Unit Tests**: `just mac-test`
- **Open Project**: `open pgAgent.xcodeproj`

## 🎨 Swift Style & Design Conventions
- **Architecture**: MVI/MVVM pattern. Use `Store` classes to manage complex state and FFI callbacks.
- **UI Mutability**: Annotate all UI-mutating methods and classes with `@MainActor`. Off-main thread work should be dispatched using Swift structured concurrency (`Task { @MainActor in ... }`).
- **Extensions**: Keep the FFI surface separated; write `BridgeManager` extensions in files matching `BridgeManager+<Feature>.swift`.
