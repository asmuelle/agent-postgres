import SwiftUI

/// Empty host app for `PgAgentMobileTests`. StoreKit Testing only serves a
/// `.storekit` configuration to an app process: in a hostless logic test the
/// client is `com.apple.dt.xctest.tool`, storekitd rejects the session
/// (SKInternalErrorDomain 4) and `Product.products(for:)` resolves nothing.
/// Kept separate from the real app so the tests don't link Rust or run its
/// launch path.
@main
struct StoreKitTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
    }
}
