//
//  EnginePreparer.swift
//  WrappBuilder
//
//  Turning an engine version's downloads into the tree a wrapp gets, on
//  any Mac, with the tools every macOS has.

import Foundation
import Logging
import ProcessKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappBuilder.EnginePreparer")

/// Prepares an engine version (docs/modules.md#engine-packages): fetches its
/// package's sources, has its module's Swift lay them out as a wrapp's
/// `Contents/` (`BuildModule.prepare`), lists the files, and hashes the
/// tree, which must be the package's `prepared` when it has one, then signs
/// what the module said needs it. Uses only what every macOS has (`tar`,
/// `ditto`, `hdiutil`, `codesign`), so it runs on the person's Mac as it
/// does on ours.
///
/// The hash is taken before signing: `codesign` writes a different ad hoc
/// signature for the same file on another macOS (15.6 and 26.2 do), so a
/// signed tree's hash would only hold on the macOS it was made on.
public nonisolated struct EnginePreparer: Sendable {
    let downloader: Downloader

    public init(downloader: Downloader) {
        self.downloader = downloader
    }

    /// A prepared engine: its tree and that tree's hash, before signing.
    public struct Prepared: Sendable {
        public let module: String
        public let version: String
        public let tree: URL
        public let hash: String
    }

    /// Prepare `version` of `module` (its newest with a package when nil)
    /// into `tree`, which must not exist yet. `checked` false leaves a hash
    /// that isn't the package's to the caller, for making a new version.
    public func prepare(_ module: ModuleFolder, version: String? = nil, into tree: URL, checked: Bool = true,
                        progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Prepared {
        let id = module.manifest.id
        guard let (version, package) = module.manifest.package(version: version) else {
            throw EngineError("\(id) has no engine package\(version.map { " for version \($0)" } ?? "")")
        }
        guard let native = module.manifest.native.flatMap(BuildModules.native) else {
            throw EngineError("\(id) has no Swift to prepare its engine")
        }
        var sources: [String: URL] = [:]
        for source in package.sources {
            progress("Downloading \(source.id)")
            sources[source.id] = try await downloader.fetch(source.request).file
        }
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        progress("Preparing \(id) \(version)")
        let job = EngineJob(sources: sources, package: package, tree: tree, scratch: scratch)
        let toSign = try await native.prepare(job)
        try await Blocking.run { try EngineTree.writeList(module: id, in: tree) }
        let hash = try await Blocking.run { try EngineTree.hash(of: tree) }
        logger.notice("[Engine] Prepared \(id) \(version): \(hash)")
        if checked, let expected = package.prepared, expected != hash {
            throw EngineError("\(id) \(version) prepared as \(hash), not the \(expected) its package says")
        }
        progress("Signing \(id) \(version)")
        try await job.sign(toSign)
        logger.notice("[Engine] Signed \(toSign.count) of \(id)'s files")
        return Prepared(module: id, version: version, tree: tree, hash: hash)
    }
}

/// What a module's `prepare` works with: its package's downloaded sources
/// by id, the tree to lay them out in, and a folder of its own to unpack
/// into, removed afterwards.
public nonisolated struct EngineJob: Sendable {
    public let sources: [String: URL]
    public let package: EnginePackage
    public let tree: URL
    public let scratch: URL

    public func source(_ id: String) throws -> URL {
        guard let url = sources[id] else { throw EngineError("no source \(id) was downloaded") }
        return url
    }

    /// Run one of the system's tools, failing with what it said.
    func run(_ tool: String, _ arguments: [String]) async throws {
        let result = try await Process.output(of: tool, arguments)
        guard result.succeeded else {
            let said = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError("\((tool as NSString).lastPathComponent) \(arguments.first ?? "") failed (\(result.status)): \(said)")
        }
    }

    /// Attach a disk image read-only at `mount`, giving up (and releasing
    /// it) if the attach hangs (`DiskImage.attach`).
    func attach(_ image: URL, at mount: URL) async throws {
        let result = try await DiskImage.attach(image, options: ["-mountpoint", mount.path, "-nobrowse", "-readonly", "-noautoopen", "-quiet"])
        guard result.succeeded else {
            let said = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError("hdiutil attach failed (\(result.status)): \(said)")
        }
    }

    /// Ad hoc sign `files`, one at a time, deepest first. Signing a
    /// framework's binary seals the framework: the hashes of every file in
    /// it go into its `_CodeSignature`, so its files must be signed before
    /// it ("a sealed resource is missing or invalid"), and not at the same
    /// time as it, which trips over the seal being written.
    func sign(_ files: [URL]) async throws {
        let deepestFirst = files.sorted {
            let (left, right) = ($0.pathComponents.count, $1.pathComponents.count)
            return left != right ? left > right : $0.path < $1.path
        }
        for file in deepestFirst {
            try await run("/usr/bin/codesign", ["--force", "--sign", "-", file.path])
        }
    }

    /// Which of `files` have no signature, asked a few at once.
    func unsigned(_ files: [URL]) async throws -> [URL] {
        var unsigned: Set<URL> = []
        var next = files.makeIterator()
        try await withThrowingTaskGroup(of: URL?.self) { group in
            func add() -> Bool {
                guard let file = next.next() else { return false }
                group.addTask {
                    let check = try await Process.output(of: "/usr/bin/codesign", ["-dvv", file.path])
                    return check.succeeded ? nil : file
                }
                return true
            }
            for _ in 0..<8 where add() {}
            while let result = try await group.next() {
                if let result { unsigned.insert(result) }
                _ = add()
            }
        }
        return files.filter(unsigned.contains)
    }
}

nonisolated extension WineBuild {
    /// Where the patched driver looks for the helpers: Contents/Frameworks,
    /// five levels up from winemac.so's folder, relative to it so the patch
    /// survives the wrapp being renamed or moved.
    static let helpersReference = "@loader_path/../../../../../Frameworks/in_process_helpers.dylib"
    /// Contents/Frameworks from SharedSupport/wine/bin.
    static let frameworksRunPath = "@executable_path/../../../Frameworks"

    /// Sikarugir's Wine (`wine`) in `SharedSupport/wine`, and the frameworks
    /// of its wrapper template (`wineskin`) in `Frameworks`: its Mac driver
    /// patched to load the in-process helpers, the wrapper's Swift modules
    /// dropped, and its 32-bit ntdll given the Rosetta fault fix
    /// (`RosettaFaultFix`); the driver, what got a run path, and every
    /// unsigned program and DLL of the wrapper's are to be signed. Wine finds the
    /// frameworks through `DYLD_FALLBACK_LIBRARY_PATH` (`Wine`), but a
    /// program asking for `@rpath/` (wineserver's libinotify) needs a run
    /// path to them, which is added as `install_name_tool` would. The
    /// wrapper's cabextract is kept in `build-tools/`, for winetricks.
    public static func prepare(_ job: EngineJob) async throws -> [URL] {
        var toSign: [URL] = []
        let wine = job.tree.appendingPathComponent("SharedSupport/wine")
        let frameworks = job.tree.appendingPathComponent("Frameworks")
        try FileManager.default.createDirectory(at: wine, withIntermediateDirectories: true)
        try await job.run("/usr/bin/tar", ["-xf", try job.source("wine").path, "-C", wine.path, "--strip-components=1"])

        let wrapper = job.scratch.appendingPathComponent("wineskin")
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        try await job.run("/usr/bin/tar", ["-xf", try job.source("wineskin").path, "-C", wrapper.path, "--strip-components=1"])
        try await job.run("/usr/bin/ditto", ["--rsrc", wrapper.appendingPathComponent("Contents/Frameworks").path, frameworks.path])

        // The wrapper's cabextract, which winetricks needs for any verb that
        // unpacks a Microsoft redistributable (directmusic, d3dx9, vcrun):
        // kept for builds, and never installed into a wrapp.
        let cabextract = job.tree.appendingPathComponent("\(EngineTree.buildTools)/cabextract")
        try FileManager.default.createDirectory(at: cabextract.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: wrapper.appendingPathComponent("Contents/Configure.app/Contents/Resources/cabextract"), to: cabextract)
        toSign.append(cabextract)

        for program in try FileManager.default.contentsOfDirectory(at: wine.appendingPathComponent("bin"), includingPropertiesForKeys: nil)
        where try MachOPatch.dependencies(of: program).contains(where: { $0.hasPrefix("@rpath/") }) {
            if try MachOPatch.addRunPath(program, path: frameworksRunPath) { toSign.append(program) }
        }

        let driver = wine.appendingPathComponent("lib/wine/x86_64-unix/winemac.so")
        if try MachOPatch.addWeakDylib(driver, reference: helpersReference) { toSign.append(driver) }

        // Rosetta 2 raises faults Windows wouldn't for two things the DRM on
        // Big Fish's games (Armadillo) does: an fs: access with the 0x67
        // address-size prefix, which it can't run, and the Windows 9x SoftICE
        // probes, which code takes because Wine on macOS runs 32-bit code in
        // an LDT segment. The patch has Wine's 32-bit ntdll deal with them
        // before any exception handler sees them. A Windows DLL: nothing to sign.
        // See docs/big-fish.md#armadillo-under-rosetta.
        let ntdll = wine.appendingPathComponent("lib/wine/i386-windows/ntdll.dll")
        try await Blocking.run {
            let (patched, outcome) = try RosettaFaultFix.patch(Data(contentsOf: ntdll))
            if outcome == .patched { try patched.write(to: ntdll) }
        }

        // A framework that loses its Swift modules is sealed again, or its
        // seal names files that are gone ("a sealed resource is missing or
        // invalid", as SikarugirSdk.framework's was in the template).
        let unsealed = try await Blocking.run {
            let files = FileManager.default
            var unsealed: Set<String> = []
            for path in try EngineTree.entries(in: frameworks).map(\.path).reversed()
            where path.hasSuffix(".swiftmodule") || path.contains(".swiftmodule/") {
                try files.removeItem(at: frameworks.appendingPathComponent(path))
                if let bundle = path.split(separator: "/").first, bundle.hasSuffix(".framework") { unsealed.insert(String(bundle)) }
            }
            return unsealed
        }
        let programs = try EngineTree.entries(in: frameworks).compactMap { entry -> URL? in
            guard case .file(let executable) = entry.kind, executable || entry.path.hasSuffix(".dll") else { return nil }
            return frameworks.appendingPathComponent(entry.path)
        }
        return toSign + (try await job.unsigned(programs)) + unsealed.sorted().map { frameworks.appendingPathComponent($0) }
    }
}

nonisolated extension ScummVMBuild {
    /// What ScummVM needs of its app's Resources beyond the engines' data.
    static let sharedResources = ["shaders.dat", "translations.dat", "gui-icons.dat"]

    /// ScummVM's program from its disk image (`scummvm`) in `MacOS`, where
    /// it runs as the wrapp itself, with its frameworks and the data the
    /// package's `engine-data` names: a game whose engine's file is missing
    /// stops at "Unable to locate the '<engine>.dat' engine data file".
    public static func prepare(_ job: EngineJob) async throws -> [URL] {
        let mount = job.scratch.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await job.attach(try job.source("scummvm"), at: mount)
        do {
            let app = mount.appendingPathComponent("ScummVM.app/Contents")
            let resources = job.tree.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: job.tree.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try await job.run("/usr/bin/ditto", ["--rsrc", app.appendingPathComponent("MacOS/scummvm").path,
                                                 job.tree.appendingPathComponent("MacOS/scummvm").path])
            for name in (job.package.engineData ?? []) + sharedResources {
                try await job.run("/usr/bin/ditto", ["--rsrc", app.appendingPathComponent("Resources/\(name)").path,
                                                     resources.appendingPathComponent(name).path])
            }
            try await job.run("/usr/bin/ditto", ["--rsrc", app.appendingPathComponent("Frameworks").path,
                                                 job.tree.appendingPathComponent("Frameworks").path])
        } catch {
            try? await job.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
            throw error
        }
        try await job.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
        return [job.tree.appendingPathComponent("MacOS/scummvm")]
    }
}
