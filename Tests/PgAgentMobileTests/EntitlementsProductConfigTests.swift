import StoreKit
import StoreKitTest
import XCTest

// `MobileEntitlementsStore.swift` is compiled directly into this logic-test
// target (see project.yml), so the ids under test are the exact same source of
// truth the app ships — no `@testable import` of the full iOS app required.

/// Guards against the "empty paywall" failure mode: if any id in
/// `MobileEntitlementsStore.configuredProductIds` is not actually a sellable
/// product, `Product.products(for:)` returns fewer products and the paywall
/// renders with no buy button — silently shipping a $0 release.
///
/// This test resolves every configured id against `Products.storekit`, which
/// must mirror what is registered in App Store Connect. If you add a product id
/// to the app (e.g. a Pro Annual subscription), add it to `Products.storekit`
/// and App Store Connect too, or this test fails first.
@MainActor
final class EntitlementsProductConfigTests: XCTestCase {
    private var session: SKTestSession!

    override func setUpWithError() throws {
        session = try SKTestSession(configurationFileNamed: "Products")
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() {
        session = nil
    }

    func testConfiguredProductIdsAreNotEmpty() {
        XCTAssertFalse(
            MobileEntitlementsStore.shared.configuredProductIds.isEmpty,
            "configuredProductIds is empty — the paywall has nothing to sell."
        )
    }

    func testEveryConfiguredProductIdResolvesToASellableProduct() async throws {
        let expected = MobileEntitlementsStore.shared.configuredProductIds
        let products = try await Product.products(for: expected)
        let resolved = Set(products.map(\.id))

        for id in expected {
            XCTAssertTrue(
                resolved.contains(id),
                """
                Product id '\(id)' did not resolve. The paywall would render with no \
                buy button. Add it to Products.storekit AND to this app's App Store \
                Connect record before shipping.
                """
            )
        }
        XCTAssertEqual(
            resolved.count, expected.count,
            "Resolved \(resolved.count) of \(expected.count) configured products."
        )
    }

    /// The lifetime id must stay namespaced to this app's bundle. A shared id
    /// (the original `com.mc-ssh.*` bug) collides across apps because StoreKit
    /// product ids are unique per developer account.
    func testLifetimeProductIdIsNamespacedToThisApp() {
        XCTAssertTrue(
            MobileEntitlementsStore.proLifetimeProductId.hasPrefix("com.pgagent.mobile"),
            "Lifetime product id must be namespaced to com.pgagent.mobile to avoid cross-app collision."
        )
    }
}
