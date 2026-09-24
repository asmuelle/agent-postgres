import Foundation
import PgAgentMacOS

/// Pure folder-hierarchy operations over a snapshot of folders + connection
/// profiles. Every operation works on a copy and returns the new state, so
/// `ConnectionStoreManager` only commits a fully consistent result — a
/// half-applied delete can never strand a subtree.
struct ConnectionFolderTree: Equatable, Sendable {
    private(set) var folders: [ConnectionFolder]
    private(set) var connections: [ConnectionProfile]

    init(folders: [ConnectionFolder], connections: [ConnectionProfile]) {
        self.folders = folders
        self.connections = connections
    }

    enum TreeError: Error, Equatable {
        case notFound
    }

    /// Delete a folder, moving its sub-folders and connections up to its
    /// parent. When a child's name is already taken at the parent level
    /// (deleting `Work` while a top-level `Prod` exists next to `Work/Prod`)
    /// the two folders are MERGED — contents of the child move into the
    /// existing folder, recursively — instead of the child being skipped and
    /// then orphaned when its parent disappears.
    func deletingFolder(id: String) throws -> ConnectionFolderTree {
        guard let folder = folders.first(where: { $0.id == id }) else {
            throw TreeError.notFound
        }
        var tree = self
        // Re-query each pass: merging a child named like the deleted folder
        // (`Work/Work`) lands its contents back under the deleted folder,
        // and those must move up as well.
        while let child = tree.folders.first(where: {
            $0.parentPath == folder.path && $0.id != folder.id
        }) {
            tree.relocate(folderId: child.id, toParent: folder.parentPath)
        }
        tree.moveConnections(from: folder.path, to: folder.parentPath)
        tree.folders.removeAll { $0.id == folder.id }
        return tree
    }

    /// Move one folder under `newParent`, merging into an existing folder of
    /// the same name there. Recurses level by level (never a blind prefix
    /// rewrite) so every descendant gets its own collision check.
    private mutating func relocate(folderId: String, toParent newParent: String?) {
        guard let index = folders.firstIndex(where: { $0.id == folderId }) else { return }
        let folder = folders[index]
        let target = Self.composedPath(name: folder.name, parent: newParent)
        let oldPath = folder.path
        let childIds = folders
            .filter { $0.parentPath == oldPath && $0.id != folderId }
            .map(\.id)

        if folders.contains(where: { $0.path == target && $0.id != folderId }) {
            // Merge: fold this folder's contents into the existing one.
            for childId in childIds {
                relocate(folderId: childId, toParent: target)
            }
            moveConnections(from: oldPath, to: target)
            folders.removeAll { $0.id == folderId }
        } else {
            folders[index].path = target
            folders[index].parentPath = newParent
            moveConnections(from: oldPath, to: target)
            for childId in childIds {
                relocate(folderId: childId, toParent: target)
            }
        }
    }

    private mutating func moveConnections(from oldPath: String, to newPath: String?) {
        for i in connections.indices where connections[i].folderPath == oldPath {
            connections[i].folderPath = newPath
        }
    }

    static func composedPath(name: String, parent: String?) -> String {
        if let parent, !parent.isEmpty {
            return "\(parent)/\(name)"
        }
        return name
    }
}
