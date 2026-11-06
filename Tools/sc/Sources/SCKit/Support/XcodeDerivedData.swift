import Foundation

/// The folders Xcode's own window built this repo into, in
/// `~/Library/Developer/Xcode/DerivedData`, its default location: one per
/// checkout it opened, `<project>-<28 letters hashed from its path>`, never
/// removed with the checkout. `sc` builds into each checkout's `DerivedData`
/// instead, so these are only the window's.
enum XcodeDerivedData {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    /// One folder there: its name, and the workspace its `info.plist` says it
    /// was for, if it has one (a folder Xcode gave up on, partway through
    /// fetching packages say, can lack it).
    struct Folder: Equatable {
        let name: String
        let workspace: String?
    }

    /// Those of this repo's: the workspace in a checkout (a worktree removed
    /// since included, while it was under the main checkout), or, with no
    /// `info.plist` to say, named after one of the repo's Xcode projects.
    /// Xcode's shared caches (`ModuleCache.noindex`…) and other projects' are
    /// left alone.
    static func ours(_ folders: [Folder], checkouts: [URL], projects: Set<String>) -> [String] {
        let roots = checkouts.map { $0.standardizedFileURL.path }
        return folders.filter { folder in
            guard let project = projectName(folder.name) else { return false }
            if let workspace = folder.workspace {
                return roots.contains { workspace.hasPrefix($0 + "/") }
            }
            return projects.contains(project)
        }.map(\.name)
    }

    /// `SecondChance` for `SecondChance-avrtzuliojkaijeesdwswiqtzgev`; nil for
    /// a name that isn't a workspace's folder.
    static func projectName(_ folder: String) -> String? {
        guard let dash = folder.lastIndex(of: "-") else { return nil }
        let hash = folder[folder.index(after: dash)...]
        guard hash.count == 28, hash.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
        return String(folder[..<dash])
    }

    /// The folders of this repo's checkouts, whose projects are `projects`.
    static func folders(checkouts: [URL], projects: Set<String>) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        let folders = names.map { name in
            let plist = root.appendingPathComponent(name).appendingPathComponent("info.plist")
            let info = (try? Data(contentsOf: plist))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            return Folder(name: name, workspace: info?["WorkspacePath"] as? String)
        }
        return ours(folders, checkouts: checkouts, projects: projects).map { root.appendingPathComponent($0) }
    }
}
