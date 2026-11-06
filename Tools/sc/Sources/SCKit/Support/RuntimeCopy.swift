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
        let script = staging.appendingPathComponent("sc")
        try launcher.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try "A runtime copy made by sc --on; see docs/dev-cli.md#runtime-copies.\n"
            .write(to: staging.appendingPathComponent(Repo.runtimeMarker), atomically: true, encoding: .utf8)
        return staging
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
}
