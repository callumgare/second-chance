import Foundation

/// What `--on` makes on the other Mac or user, besides the build and data it
/// syncs (`Remote.syncFilters`): sc's own binary, built here, a `./sc` that
/// runs it without building, and the marker that says this is a copy to run
/// in (`Repo.isRuntimeCopy`). Nothing compiles there.
enum RuntimeCopy {
    /// The `./sc` a runtime copy runs: the binary beside it, as the
    /// checkout's `./sc` runs the one it builds.
    static let launcher = """
    #!/bin/bash
    # A runtime copy's sc, written by `sc --on` (docs/dev-cli.md#runtime-copies):
    # it runs the sc built on the Mac that sent it. Nothing here is built.
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SC_REPO_ROOT="$root" exec "$root/.sc/sc" "$@"

    """

    /// Lay out the runtime copy's own files in `DerivedData/sc-runtime/`,
    /// for the sync to send: `sc`, `.sc/sc` (this sc's binary) and the
    /// marker. The binary is copied whole, never linked, as the keep-alive
    /// and the signing export there copy it in turn.
    static func stage(in repo: Repo) throws -> URL {
        guard let executable = Bundle.main.executablePath else {
            throw SCError("Couldn't find sc's own executable to send.")
        }
        let fm = FileManager.default
        let staging = repo.derivedData.appendingPathComponent("sc-runtime")
        let binaries = staging.appendingPathComponent(".sc")
        try fm.createDirectory(at: binaries, withIntermediateDirectories: true)
        let binary = binaries.appendingPathComponent("sc")
        if fm.fileExists(atPath: binary.path) { try fm.removeItem(at: binary) }
        try fm.copyItem(at: URL(fileURLWithPath: executable), to: binary)
        // Its time is the stamp's (`stamp(of:)`), so it must be the original's.
        if let modified = try fm.attributesOfItem(atPath: executable)[.modificationDate] {
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: binary.path)
        }
        let script = staging.appendingPathComponent("sc")
        try launcher.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try "A runtime copy made by sc --on; see docs/dev-cli.md#runtime-copies.\n"
            .write(to: staging.appendingPathComponent(Repo.runtimeMarker), atomically: true, encoding: .utf8)
        return staging
    }

    /// sc's own binary, which a copy there runs.
    static func ownExecutable() throws -> URL {
        guard let executable = Bundle.main.executablePath else {
            throw SCError("Couldn't find sc's own executable to send.")
        }
        return URL(fileURLWithPath: executable)
    }

    /// A binary's size and modification time, as `stat -f '%z %m'` prints
    /// them: whether a copy there already runs this sc, since the sync and
    /// the clone keep the time `stage` gives it. Comparing them saves
    /// syncing, or hashing, the binary for a command that needs nothing else.
    static func stamp(of binary: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: binary.path)
        guard let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else {
            throw SCError("Couldn't read the size and time of \(binary.path).")
        }
        return "\(size.int64Value) \(Int(modified.timeIntervalSince1970))"
    }

    /// Where a copy keeps the binaries sent beside a run still going there
    /// (`Remote.sendBinaryBeside`): one folder each, by stamp, removed by the
    /// next sync, which only happens once nothing runs there.
    static let versionsFolder = ".sc/versions"

    /// The binary with this stamp, relative to the copy's root.
    static func versionPath(stamp: String) -> String {
        "\(versionsFolder)/\(stamp.replacingOccurrences(of: " ", with: "-"))/sc"
    }

    /// The rsyncs that send the paths under `.local` a command names
    /// (`Remote.localPaths`), each to the same place in the copy there. A
    /// worktree's `.local` is a link to the main checkout's, which is
    /// resolved; links inside are sent as links, never followed (a Wine
    /// prefix's `z:` is a link to `/`). Nothing is deleted there: a
    /// workspace keeps what was made in it on that side.
    static func localSyncs(_ paths: [String], root: URL, target: Remote.Target) -> [[String]] {
        let local = root.appendingPathComponent(".local").resolvingSymlinksInPath()
        return paths.map { path in
            let rest = String(path.dropFirst(".local/".count))
            let source = local.appendingPathComponent(rest)
            let isDirectory = FileManager.default.isDirectory(source)
            return ["-aE", "--rsync-path=/usr/bin/rsync", "--exclude", ".DS_Store",
                    source.path + (isDirectory ? "/" : ""),
                    "\(target.host):\(target.path)/\(path)" + (isDirectory ? "/" : "")]
        }
    }

    // MARK: - On this Mac

    /// Whether `host` (`[user@]host`) is this Mac: then the copy is cloned
    /// rather than sent (`cloneScript`).
    static func isThisMac(_ host: String, localNames: [String] = thisMacNames()) -> Bool {
        let name = (host.split(separator: "@").last.map(String.init) ?? host).lowercased()
        let short = name.split(separator: ".").first.map(String.init) ?? name
        return ["localhost", "127.0.0.1", "::1"].contains(name) || localNames.contains(name) || localNames.contains(short)
    }

    static func thisMacNames() -> [String] {
        let full = ProcessInfo.processInfo.hostName.lowercased()
        return [full, full.split(separator: ".").first.map(String.init) ?? full]
    }

    /// A path for the clone script: `~/` as `$HOME/`, so the user running
    /// it there gets their own home, the rest quoted.
    static func scriptPath(_ path: String) -> String {
        path.hasPrefix("~/") ? "\"$HOME\"/" + Remote.quote(String(path.dropFirst(2))) : Remote.quote(path)
    }

    /// The bash a user on this Mac runs to make its runtime copy from this
    /// checkout with APFS clones (`ditto --clone`), taking next to no time
    /// or disk, instead of an rsync of hundreds of megabytes into its own
    /// home: test users can read the checkout (they're in `staff`), and what
    /// they clone is theirs. `Bundles`, `Modules` and the Debug products are
    /// cloned beside the old and swapped in, so nothing stale is left; sc's
    /// own files are cloned over the old; the named `.local` paths are cloned
    /// in with nothing there deleted, as `localSyncs` sends them.
    static func cloneScript(root: URL, staging: URL, named: [String], targetPath: String, products: Bool) -> String {
        let src = { (relative: String) in Remote.quote(root.appendingPathComponent(relative).path) }
        let dst = { (relative: String) in scriptPath(targetPath + "/" + relative) }
        var lines = ["set -e", "mkdir -p \(scriptPath(targetPath))"]
        func swap(_ relative: String) {
            lines.append("rm -rf \(dst(relative + ".new")) && mkdir -p \(dst((relative as NSString).deletingLastPathComponent))")
            lines.append("ditto --clone \(src(relative)) \(dst(relative + ".new"))")
            lines.append("rm -rf \(dst(relative)) && mv \(dst(relative + ".new")) \(dst(relative))")
        }
        for folder in Remote.dataFolders { swap(folder) }
        if products {
            swap("DerivedData/Build/Products/Debug")
            lines.append("rm -f \(dst("DerivedData/Build/Products"))/*.xctestrun")
            lines.append("for f in \(src("DerivedData/Build/Products"))/*.xctestrun; do [ -e \"$f\" ] && cp -c \"$f\" \(dst("DerivedData/Build/Products"))/; done")
        }
        lines.append("ditto --clone \(Remote.quote(staging.path)) \(scriptPath(targetPath))")
        let local = root.appendingPathComponent(".local").resolvingSymlinksInPath()
        for path in named {
            let source = local.appendingPathComponent(String(path.dropFirst(".local/".count)))
            lines.append("mkdir -p \(dst((path as NSString).deletingLastPathComponent))")
            lines.append("ditto --clone \(Remote.quote(source.path)) \(dst(path))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
