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
        return [job.tree.appendingPathComponent("Frameworks/SDL2.framework"),
                job.tree.appendingPathComponent("MacOS/BasiliskII")]
    }
}
