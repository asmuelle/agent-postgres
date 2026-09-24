// Tests for the Sparkle appcast helper: it refuses to emit an enclosure
// without a real EdDSA signature (Sparkle 2 rejects unsigned updates) and
// writes the signature + XML-escaped values when one is supplied.

import XCTest

@testable import PgAgentApp

final class E_AppcastGenerationTests: XCTestCase {

    /// 64 bytes, base64 — the shape `sign_update` prints.
    private let signature = Data(repeating: 0xAB, count: 64).base64EncodedString()

    func testMissingSignatureThrows() {
        for empty in ["", "   \n"] {
            XCTAssertThrowsError(try UpdateManager.generateAppcast(
                version: "1.0", build: "1", downloadURL: "https://x/y.dmg", size: 1,
                edSignature: empty
            )) { error in
                XCTAssertEqual(error as? UpdateManager.AppcastError, .missingSignature)
            }
        }
    }

    func testMalformedSignatureThrows() {
        for bad in ["not-base64!!", Data(count: 32).base64EncodedString()] {
            XCTAssertThrowsError(try UpdateManager.generateAppcast(
                version: "1.0", build: "1", downloadURL: "https://x/y.dmg", size: 1,
                edSignature: bad
            )) { error in
                XCTAssertEqual(error as? UpdateManager.AppcastError, .malformedSignature)
            }
        }
    }

    func testSignedAppcastEmbedsSignatureAndEscapes() throws {
        let xml = try UpdateManager.generateAppcast(
            version: "1.4.0", build: "42",
            downloadURL: "https://example.com/pgAgent.dmg?a=1&b=2", size: 1234,
            edSignature: signature
        )
        XCTAssertTrue(xml.contains("sparkle:edSignature=\"\(signature)\""))
        XCTAssertFalse(xml.contains("sparkle:edSignature=\"\""))
        XCTAssertTrue(xml.contains("url=\"https://example.com/pgAgent.dmg?a=1&amp;b=2\""))
        XCTAssertTrue(xml.contains("length=\"1234\""))
        XCTAssertTrue(xml.contains("<sparkle:version>42</sparkle:version>"))
        XCTAssertNotNil(try XMLDocument(xmlString: xml))
    }

    func testBundleFeedPointsAtThisProduct() {
        // Guards against re-pointing the feed at another product's appcast.
        let feed = Bundle(for: UpdateManager.self)
            .object(forInfoDictionaryKey: "SUFeedURL") as? String
        XCTAssertEqual(
            feed, "https://github.com/asmuelle/agent-postgres/releases/latest/download/appcast.xml")
    }
}
