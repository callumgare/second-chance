import CryptoKit
import Foundation

/// The hash of the page's source (`Tools/icon-lab/web`), written beside the built page as `source.sha256` by
/// `sc icon-lab build`, so a test can tell when the build is stale. `sc` computes it the same way
/// (`Tools/sc/Sources/SCKit/Commands/IconLab.swift`): keep the two in step.
///
/// Every file under the root but `node_modules`, `dist`, hidden files and `README.md`, in order of their relative
/// paths, each as `<path>\t<sha256 of its bytes>\n`; the hash is the SHA-256 of all those lines.
nonisolated public enum WebSourceHash {
    public static func compute(root: URL) throws -> String {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let skip: Set<String> = ["node_modules", "dist", "README.md"]
        var files: [String] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return "" }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let regular = (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
            if name.hasPrefix(".") || skip.contains(name) {
                // only a folder's: skipDescendants after a file skips the folder enumerated next
                if !regular { walker.skipDescendants() }
                continue
            }
            guard regular else { continue }
            let path = url.resolvingSymlinksInPath().path
            files.append(String(path.dropFirst(root.path.count + 1)))
        }
        var lines = ""
        for path in files.sorted() {
            let digest = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(path)))
            lines += "\(path)\t\(hex(digest))\n"
        }
        return hex(SHA256.hash(data: Data(lines.utf8)))
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
