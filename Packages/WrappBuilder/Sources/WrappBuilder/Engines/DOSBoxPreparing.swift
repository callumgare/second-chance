//
//  DOSBoxPreparing.swift
//  WrappBuilder
//
//  Preparing DOSBox Staging from its makers' disk image.

import Foundation

nonisolated extension DOSBoxBuild {
    /// What of DOSBox Staging's Resources it runs with: its key maps, code
    /// pages, keyboard layouts, shaders, translations and disk noises; not
    /// its manual (40 MB), web server or build files.
    static let keptResources = [
        "disk-noises", "drives", "freedos-cpi", "freedos-keyboard", "mapperfiles", "mapping", "mapping-freedos.org",
        "mapping-unicode.org", "mapping-wikipedia.org", "shader-presets", "shaders", "translations",
    ]

    /// DOSBox Staging's program and the libraries beside it (`MacOS/lib`),
    /// from its disk image (`dosbox`), in `MacOS`, where it runs as the
    /// wrapp itself, with what it needs of its Resources in the wrapp's,
    /// where it looks for them, and its licence. Its program and libraries are
    /// signed again, ad hoc: they come signed with hardened runtime, which
    /// would refuse the puppet control's inserted library.
    public static func prepare(_ job: EngineJob) async throws -> [URL] {
        let mount = job.scratch.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await job.run("/usr/bin/hdiutil", ["attach", try job.source("dosbox").path, "-mountpoint", mount.path,
                                               "-nobrowse", "-readonly", "-noautoopen", "-quiet"])
        do {
            let app = mount.appendingPathComponent("DOSBox Staging.app/Contents")
            let macOS = job.tree.appendingPathComponent("MacOS")
            let resources = job.tree.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try await job.run("/usr/bin/ditto", ["--rsrc", app.appendingPathComponent("MacOS/dosbox").path,
                                                 macOS.appendingPathComponent("dosbox").path])
            try await job.run("/usr/bin/ditto", ["--rsrc", app.appendingPathComponent("MacOS/lib").path,
                                                 macOS.appendingPathComponent("lib").path])
            for name in keptResources {
                try await job.run("/usr/bin/ditto", ["--rsrc", app.appendingPathComponent("Resources/\(name)").path,
                                                     resources.appendingPathComponent(name).path])
            }
            try await job.run("/usr/bin/ditto", ["--rsrc", app.appendingPathComponent("SharedSupport/LICENSE").path,
                                                 resources.appendingPathComponent("DOSBox LICENSE").path])
        } catch {
            try? await job.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
            throw error
        }
        try await job.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
        let libraries = try FileManager.default.contentsOfDirectory(at: job.tree.appendingPathComponent("MacOS/lib"),
                                                                    includingPropertiesForKeys: nil)
        return libraries.filter { $0.pathExtension == "dylib" }.sorted { $0.path < $1.path }
            + [job.tree.appendingPathComponent("MacOS/dosbox")]
    }
}
