import Foundation

// Whether the app's copies of Bundles/ and Modules/ still match the
// checkout's. The app carries its own copies (Contents/Resources), and a
// build reads those, so a Wrappfile edited since the app was built isn't
// used by a run with --skip-app-build. Comparing them is cheap: a few
// megabytes, about 20 ms.

enum StaleAppData {
    /// The folders the app copies from the checkout.
    static let folders = ["Bundles", "Modules"]

    /// The first file, by path, that differs between `source` and `copy`
    /// (added, removed or changed), or nil when they match. Dotfiles
    /// (.DS_Store) are left out, as the app's copy leaves them out.
    static func firstDifference(source: URL, copy: URL) -> String? {
        let ours = files(in: source), theirs = files(in: copy)
        for path in Set(ours.keys).union(theirs.keys).sorted() {
            guard let mine = ours[path], let built = theirs[path] else { return path }
            if mine != built { return path }
            let a = try? Data(contentsOf: source.appendingPathComponent(path))
            let b = try? Data(contentsOf: copy.appendingPathComponent(path))
            if a != b { return path }
        }
        return nil
    }

    /// What `--skip-app-build` would build from that the checkout has since
    /// changed: one line per folder, naming its first differing file.
    static func differences(checkout: URL, appResources: URL) -> [String] {
        folders.compactMap { folder in
            let copy = appResources.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: copy.path) else { return nil }
            return firstDifference(source: checkout.appendingPathComponent(folder), copy: copy).map { "\(folder)/\($0)" }
        }
    }

    /// Every regular file under `root` that isn't a dotfile or in a dot
    /// folder, by its path from `root`, with its size.
    static func files(in root: URL) -> [String: Int] {
        var found: [String: Int] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return found }
        let prefix = root.resolvingSymlinksInPath().path.count + 1
        while let url = walker.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            found[String(url.resolvingSymlinksInPath().path.dropFirst(prefix))] = values.fileSize ?? 0
        }
        return found
    }
}
