// Tests for the Tauri-export `authMethod` → `AuthMethod` mapping: every key
// spelling (camel/snake/kebab case, synonyms) is key auth, case-insensitive;
// unknown values stay password; a missing value falls back on the key path.

import PgAgentMacOS
import XCTest

@testable import PgAgentApp

final class E_ImportAuthMappingTests: XCTestCase {

    func testKeySpellingsMapToPublicKey() {
        let spellings = [
            "publicKey", "PublicKey", "publickey", "PUBLICKEY", "public_key",
            "public-key", "Public Key", "pubkey", "key", "Key", "privateKey",
            "private_key", "sshKey", "ssh-key", "keyFile", "agent", "ssh-agent",
        ]
        for value in spellings {
            XCTAssertEqual(
                ImportManager.authMethod(forExportValue: value, privateKeyPath: nil),
                .publicKey, value)
        }
    }

    func testPasswordAndUnknownValuesMapToPassword() {
        for value in ["password", "Password", "keyboard-interactive", "totp", "whatever"] {
            XCTAssertEqual(
                ImportManager.authMethod(forExportValue: value, privateKeyPath: "/k"),
                .password, value)
        }
    }

    func testMissingValueFallsBackOnKeyPath() {
        XCTAssertEqual(ImportManager.authMethod(forExportValue: nil, privateKeyPath: nil), .password)
        XCTAssertEqual(ImportManager.authMethod(forExportValue: nil, privateKeyPath: "  "), .password)
        XCTAssertEqual(
            ImportManager.authMethod(forExportValue: nil, privateKeyPath: "~/.ssh/id_ed25519"),
            .publicKey)
        XCTAssertEqual(
            ImportManager.authMethod(forExportValue: "", privateKeyPath: "~/.ssh/id_ed25519"),
            .publicKey)
    }

    func testImportFromJSONStringUsesMapping() throws {
        let json = """
        [
          {"id": "a", "host": "h1", "authMethod": "public_key"},
          {"id": "b", "host": "h2", "authMethod": "password"},
          {"id": "c", "host": "h3", "privateKeyPath": "/k"}
        ]
        """
        let data = try ImportManager.shared.importFromJSONString(json)
        let byId = Dictionary(uniqueKeysWithValues: data.connections.map { ($0.id, $0.authMethod) })
        XCTAssertEqual(byId["a"], .publicKey)
        XCTAssertEqual(byId["b"], .password)
        XCTAssertEqual(byId["c"], .publicKey)
    }
}
