import XCTest
@testable import PgAgentMacOS

final class TerminalErgonomicsModelTests: XCTestCase {
    func testTerminalPathDetectorFindsAndNormalizesPaths() {
        let candidates = TerminalPathDetector.candidates(
            in: "error in /var/log/nginx/error.log, then ../app/config.yml",
            currentDirectory: "/srv/www/current",
            username: "deploy"
        )

        XCTAssertEqual(
            candidates.map(\.remotePath),
            ["/var/log/nginx/error.log", "/srv/www/app/config.yml"]
        )
    }

    func testTerminalPathDetectorSkipsURLsAndExpandsHome() {
        let candidates = TerminalPathDetector.candidates(
            in: "See https://example.com/a and ~/bin/deploy.sh",
            username: "deploy"
        )

        XCTAssertEqual(candidates.map(\.remotePath), ["/home/deploy/bin/deploy.sh"])
    }

    func testTerminalSnippetRendererSupportsVariablesDelaysAndControls() {
        let context = TerminalSnippetContext(
            profileName: "Prod",
            host: "api.example.com",
            username: "deploy",
            currentDirectory: "/srv",
            variables: ["service": "nginx"],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let steps = TerminalSnippetRenderer.terminalSteps(
            body: "echo {{profile.name}} {{service}}\n#delay 250ms\n{{ctrl:c}}",
            context: context
        )

        XCTAssertEqual(steps, [
            .send("echo Prod nginx\r"),
            .delay(milliseconds: 250),
            .send("\u{03}\r"),
        ])
    }

    func testDeepLinkParsesFolderRoute() {
        let link = MidnightSSHDeepLink(URL(string: "pgAgent://folder/prod?path=/var/log")!)

        XCTAssertEqual(link?.kind, .folder)
        XCTAssertEqual(link?.profileId, "prod")
        XCTAssertEqual(link?.remotePath, "/var/log")
    }
}
