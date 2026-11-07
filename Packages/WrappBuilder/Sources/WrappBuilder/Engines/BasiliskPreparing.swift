//
//  BasiliskPreparing.swift
//  WrappBuilder
//
//  Preparing Basilisk II, and the System 7.5.3 it boots, from their
//  downloads.

import Foundation

nonisolated extension BasiliskBuild {
    /// Where the Mac's startup disk as Apple's download installs it lies in
    /// a prepared tree, and so in an app with the engine: the module's set-up
    /// step copies it to `WrappLayout.basiliskBootDisk`, which the build then
    /// changes (a startup item, QuickTime) and the app keeps.
    public static let systemDisk = "SharedSupport/basilisk/system.hfv"

    /// Basilisk II's program from its makers' zip (`basilisk`), in `MacOS`,
    /// with SDL2 in `Frameworks` beside it, where its run path finds it, and
    /// its credits (its licence notice); and System 7.5.3, which Apple gave
    /// away, installed on a disk image (`system`). The program and SDL2 are
    /// signed again, ad hoc: notarized, they'd refuse the inserted helpers.
    public static func prepare(_ job: EngineJob) async throws -> [URL] {
        let unzipped = job.scratch.appendingPathComponent("basilisk")
        try await job.run("/usr/bin/ditto", ["-x", "-k", try job.source("basilisk").path, unzipped.path])
        let app = unzipped.appendingPathComponent("BasiliskII.app/Contents")
        let files = FileManager.default
        for folder in ["MacOS", "Frameworks", "Resources", "SharedSupport/basilisk"] {
            try files.createDirectory(at: job.tree.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try await job.run("/usr/bin/ditto", ["--rsrc", app.appendingPathComponent("MacOS/BasiliskII").path,
                                             job.tree.appendingPathComponent("MacOS/BasiliskII").path])
        try await job.run("/usr/bin/ditto", ["--rsrc", app.appendingPathComponent("Frameworks/SDL2.framework").path,
                                             job.tree.appendingPathComponent("Frameworks/SDL2.framework").path])
        try await job.run("/usr/bin/ditto", [app.appendingPathComponent("Resources/Credits.html").path,
                                             job.tree.appendingPathComponent("Resources/Basilisk II Credits.html").path])
        try await job.run("/usr/bin/ditto", [try job.source("system").path,
                                             job.tree.appendingPathComponent(systemDisk).path])
        let tools = try await prepareHFSUtils(job)
        return [job.tree.appendingPathComponent("Frameworks/SDL2.framework"),
                job.tree.appendingPathComponent("MacOS/BasiliskII")] + tools
    }

    /// The hfsutils commands the build changes the Mac's disks with, in the
    /// engine's build tools (never in an app): Homebrew's builds for Apple
    /// silicon and Intel, each command made one universal binary with lipo,
    /// each slice aligned to 16 KB as said rather than lipo's choice, which
    /// changed with Xcode (4 KB for the Intel slice in macOS 26's) and made
    /// the prepared tree's hash differ from Mac to Mac.
    static let hfsutils = ["hmount", "humount", "hls", "hcopy", "hmkdir", "hrename", "hdel", "hattrib", "hvol"]

    /// Where they are in a prepared tree.
    public static let hfsutilsFolder = "\(EngineTree.buildTools)/hfsutils"

    static func prepareHFSUtils(_ job: EngineJob) async throws -> [URL] {
        let folder = job.tree.appendingPathComponent(hfsutilsFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var unpacked: [String: URL] = [:]
        for arch in ["arm64", "x86-64"] {
            let into = job.scratch.appendingPathComponent("hfsutils-\(arch)")
            try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
            try await job.run("/usr/bin/tar", ["-xzf", try job.source("hfsutils-\(arch)").path, "-C", into.path])
            unpacked[arch] = into.appendingPathComponent("hfsutils/3.2.6/bin")
        }
        guard let arm64 = unpacked["arm64"], let x86 = unpacked["x86-64"] else { return [] }
        var tools: [URL] = []
        for tool in hfsutils {
            let out = folder.appendingPathComponent(tool)
            try await job.run("/usr/bin/lipo", ["-create", arm64.appendingPathComponent(tool).path,
                                                x86.appendingPathComponent(tool).path,
                                                "-segalign", "x86_64", "4000", "-segalign", "arm64", "4000",
                                                "-output", out.path])
            tools.append(out)
        }
        return tools
    }
}
