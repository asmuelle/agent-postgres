import XCTest
import PgAgentMacOS
@testable import PgAgentApp

final class D2ConnectionFolderTreeTests: XCTestCase {
    private func folder(_ path: String) -> ConnectionFolder {
        let parts = path.split(separator: "/").map(String.init)
        let parent = parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
        return ConnectionFolder(id: "id:\(path)", name: parts.last!, path: path, parentPath: parent)
    }

    private func connection(_ id: String, in path: String?) -> ConnectionProfile {
        ConnectionProfile(id: id, name: id, host: "h", username: "u", folderPath: path)
    }

    private func paths(_ tree: ConnectionFolderTree) -> [String] {
        tree.folders.map(\.path).sorted()
    }

    private func folderPath(of id: String, in tree: ConnectionFolderTree) -> String?? {
        tree.connections.first { $0.id == id }.map(\.folderPath)
    }

    func testChildrenAndConnectionsMoveUpToParent() throws {
        let tree = ConnectionFolderTree(
            folders: [folder("Work"), folder("Work/Prod"), folder("Work/Prod/EU")],
            connections: [connection("c1", in: "Work"), connection("c2", in: "Work/Prod/EU")]
        )
        let result = try tree.deletingFolder(id: "id:Work")
        XCTAssertEqual(paths(result), ["Prod", "Prod/EU"])
        XCTAssertEqual(result.folders.first { $0.path == "Prod/EU" }?.parentPath, "Prod")
        XCTAssertEqual(result.folders.first { $0.path == "Prod" }?.parentPath, nil)
        XCTAssertEqual(folderPath(of: "c1", in: result), .some(nil))
        XCTAssertEqual(folderPath(of: "c2", in: result), .some("Prod/EU"))
    }

    /// The reported bug: a sibling `Prod` already exists at the parent level,
    /// so the old code's `try? moveFolder` failed silently and `Work/Prod`
    /// (with its connections) vanished from the tree.
    func testDuplicateChildIsMergedNotOrphaned() throws {
        let tree = ConnectionFolderTree(
            folders: [
                folder("Prod"), folder("Prod/US"),
                folder("Work"), folder("Work/Prod"), folder("Work/Prod/US"), folder("Work/Prod/EU"),
            ],
            connections: [
                connection("inWorkProd", in: "Work/Prod"),
                connection("inWorkProdUS", in: "Work/Prod/US"),
                connection("inWorkProdEU", in: "Work/Prod/EU"),
                connection("inProd", in: "Prod"),
            ]
        )
        let result = try tree.deletingFolder(id: "id:Work")

        XCTAssertEqual(paths(result), ["Prod", "Prod/EU", "Prod/US"])
        XCTAssertEqual(folderPath(of: "inWorkProd", in: result), .some("Prod"))
        XCTAssertEqual(folderPath(of: "inWorkProdUS", in: result), .some("Prod/US"))
        XCTAssertEqual(folderPath(of: "inWorkProdEU", in: result), .some("Prod/EU"))
        XCTAssertEqual(folderPath(of: "inProd", in: result), .some("Prod"))
        // The pre-existing folders keep their identity.
        XCTAssertEqual(result.folders.first { $0.path == "Prod" }?.id, "id:Prod")

        // Every connection still sits in a folder that exists.
        let existing = Set(result.folders.map(\.path))
        for c in result.connections {
            if let p = c.folderPath { XCTAssertTrue(existing.contains(p), "orphaned \(c.id) in \(p)") }
        }
    }

    func testChildNamedLikeDeletedFolder() throws {
        let tree = ConnectionFolderTree(
            folders: [folder("Work"), folder("Work/Work"), folder("Work/Work/Inner")],
            connections: [connection("deep", in: "Work/Work/Inner"), connection("mid", in: "Work/Work")]
        )
        let result = try tree.deletingFolder(id: "id:Work")
        let existing = Set(result.folders.map(\.path))
        XCTAssertTrue(existing.contains("Inner"))
        XCTAssertFalse(existing.contains("Work/Work"))
        XCTAssertEqual(folderPath(of: "deep", in: result), .some("Inner"))
        for c in result.connections {
            if let p = c.folderPath { XCTAssertTrue(existing.contains(p), "orphaned \(c.id) in \(p)") }
        }
    }

    func testNestedDeleteMovesToGrandparent() throws {
        let tree = ConnectionFolderTree(
            folders: [folder("A"), folder("A/B"), folder("A/B/C")],
            connections: [connection("c", in: "A/B")]
        )
        let result = try tree.deletingFolder(id: "id:A/B")
        XCTAssertEqual(paths(result), ["A", "A/C"])
        XCTAssertEqual(folderPath(of: "c", in: result), .some("A"))
    }

    func testUnknownFolderThrowsAndLeavesTreeUntouched() {
        let tree = ConnectionFolderTree(folders: [folder("A")], connections: [])
        XCTAssertThrowsError(try tree.deletingFolder(id: "missing"))
        XCTAssertEqual(paths(tree), ["A"])
    }
}
