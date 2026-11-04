//
//  CoreInstructions.swift
//  WrappBuilder
//
//  The core's instructions, which the runner carries out itself: COPY, ADD,
//  EDIT, MOVE, REMOVE and RUN.

import Foundation
import Logging
import ProcessKit
import WrappFormat

/// The core's instructions, carried out in the step's tree. Each step that
/// needs a mount says so with its own `--mount`.
nonisolated enum CoreInstructions {
    static func run(_ step: PlannedStep, in context: LocalStepContext) async throws {
        switch step.instruction {
        case "COPY": try await copy(step, in: context)
        case "ADD": try await add(step, in: context)
        case "EDIT": try await edit(step, in: context)
        case "MOVE": try await move(step, in: context)
        case "REMOVE": try await remove(step, in: context)
        case "RUN": try await runProgram(step, in: context)
        case "ENGINE": try await engine(step, in: context)
        case "APP": try await app(step, in: context)
        default: throw StepFailure.recipe("\(step.origin): the core has no instruction \(step.instruction)")
        }
    }

    // MARK: - COPY

    /// `COPY <file> <dest>`: a bundle's or module's file. `COPY --from=<input>
    /// <path> <dest>`: what's at the path in the input, `.` for all of it.
    /// `COPY --from=<stage> <path> <dest>`: a folder or file of that stage's.
    /// A folder's contents are merged into the destination; a file goes into
    /// it when it names a folder (`…/`).
    static func copy(_ step: PlannedStep, in context: LocalStepContext) async throws {
        guard step.arguments.count == 2 else { throw StepFailure.recipe("\(step.origin): COPY takes what to copy and where") }
        let destination = try context.location(step.arguments[1])
        let destinationIsFolder = step.arguments[1].hasSuffix("/")
        let source: URL
        if let from = step.option("from") {
            if let input = PlannedStep.input(in: from) {
                let root = try await context.input(input)
                source = step.arguments[0] == "." ? root : root.appendingPathComponent(step.arguments[0])
            } else {
                guard let other = context.tree(ofStage: from) else {
                    throw StepFailure.recipe("\(step.origin): there's no stage \(from) to copy from")
                }
                guard let found = WrappLayout(app: other).location(step.arguments[0]) else {
                    throw StepFailure.recipe("\(step.origin): \(step.arguments[0]) has no place in \(from)")
                }
                source = found
            }
        } else {
            guard let file = context.file(step.arguments[0]) else {
                throw StepFailure.recipe("\(step.origin): the plan has no file \(step.arguments[0])")
            }
            source = file
        }
        try await Blocking.run { try FileCopy.copy(source, to: destination, intoFolder: destinationIsFolder) }
        context.log.notice("Copied \(step.arguments[0])\(step.option("from").map { " from \($0)" } ?? "") into \(step.arguments[1])")
    }

    // MARK: - ADD

    /// `ADD --checksum=sha256:<hash> [--unpack=zip --member=<file> [--extract]]
    /// <url> <folder>`: the download, fetched through the download cache by
    /// its hash, and its member put in the folder, or with `--extract`,
    /// what's in it (a self-extracting zip).
    static func add(_ step: PlannedStep, in context: LocalStepContext) async throws {
        guard step.arguments.count == 2, let url = URL(string: step.arguments[0]) else {
            throw StepFailure.recipe("\(step.origin): ADD takes a URL and a folder in the app")
        }
        let folder = try context.location(step.arguments[1])
        guard let checksum = step.option("checksum"), checksum.hasPrefix("sha256:") else {
            throw StepFailure.recipe("\(step.origin): ADD needs --checksum=sha256:<hash>")
        }
        let download = try await context.fetch(url: url, sha256: String(checksum.dropFirst("sha256:".count)))
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("add-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let member = try await Archive.member(of: download, named: step.option("member"), unpack: step.option("unpack"),
                                              in: work, called: url.lastPathComponent, origin: step.origin)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if step.has("extract") {
            // A self-extracting zip is a zip with an exe in front, which unzip
            // reads as it is.
            try await Archive.unzip(member, into: folder, origin: step.origin)
            context.log.notice("   → extracted \(member.lastPathComponent) into \(folder.lastPathComponent)")
        } else {
            try await Blocking.run { try FileCopy.copy(member, to: folder, intoFolder: true) }
            context.log.notice("   → copied \(member.lastPathComponent) into \(folder.lastPathComponent)")
        }
    }

    // MARK: - EDIT

    /// `EDIT <file> --ini=<section>.<key>=<value>… [--keys-must-exist]
    /// [--create]`: each setting changed in its section, or added to it;
    /// with `--keys-must-exist`, one that isn't there already fails the
    /// step. The file must exist unless the step says `--create`.
    static func edit(_ step: PlannedStep, in context: LocalStepContext) async throws {
        guard let path = step.arguments.first else { throw StepFailure.recipe("\(step.origin): EDIT names its file") }
        if step.has("plist") {
            try await editPlist(step, path: path, in: context)
            return
        }
        guard step.has("ini") else {
            throw StepFailure.recipe("\(step.origin): this build can't run \(step)")
        }
        let file = try context.location(path)
        let settings = try (step.options["ini"] ?? []).map { setting throws -> IniEdit.Setting in
            guard let parsed = IniEdit.Setting(setting) else {
                throw StepFailure.recipe("\(step.origin): --ini=\(setting) isn't <section>.<key>=<value>")
            }
            return parsed
        }
        let exists = FileManager.default.fileExists(atPath: file.path)
        if !exists {
            guard step.has("create") else { throw StepFailure.failed("\(step.origin): \(path) doesn't exist (EDIT --create makes it)") }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let text = exists ? try String(contentsOf: file, encoding: .utf8) : ""
        let edited = IniEdit.edit(text, settings: settings, keysMustExist: step.has("keys-must-exist"))
        guard edited.missing.isEmpty else {
            throw StepFailure.failed("\(step.origin): \(file.lastPathComponent) has no \(edited.missing.joined(separator: ", ")) to change (--keys-must-exist)")
        }
        try edited.text.write(to: file, atomically: true, encoding: .utf8)
        context.log.notice("✓ Set \(settings.map(\.description).joined(separator: ", ")) in \(file.lastPathComponent)")
    }

    /// `EDIT <file> --plist=<key>=<value>… [--create]`: each key of a
    /// property list set to its text.
    static func editPlist(_ step: PlannedStep, path: String, in context: LocalStepContext) async throws {
        let file = try context.location(path)
        var values: [String: String] = [:]
        for setting in step.options["plist"] ?? [] {
            guard let equals = setting.firstIndex(of: "="), equals != setting.startIndex else {
                throw StepFailure.recipe("\(step.origin): --plist=\(setting) isn't <key>=<value>")
            }
            values[String(setting[..<equals])] = String(setting[setting.index(after: equals)...])
        }
        guard FileManager.default.fileExists(atPath: file.path) || step.has("create") else {
            throw StepFailure.failed("\(step.origin): \(path) doesn't exist (EDIT --create makes it)")
        }
        try Plist.update(file) { plist in plist.merge(values) { $1 } }
    }

    // MARK: - ENGINE and APP

    /// `ENGINE <module>@<version>`, which `USE` plans in a tree that hasn't
    /// the module yet: the tree's engine made that one, from the engine
    /// store. A tree with it already is left; one with another of the
    /// module's is given this one instead.
    static func engine(_ step: PlannedStep, in context: LocalStepContext) async throws {
        guard let named = step.arguments.first, let at = named.firstIndex(of: "@") else {
            throw StepFailure.recipe("\(step.origin): ENGINE names <module>@<version>")
        }
        let module = String(named[..<at]), version = String(named[named.index(after: at)...])
        let contents = context.tree.appendingPathComponent("Contents")
        let engine = try await context.configuration.engine(module, version)
        let had = EngineInstall.installed(in: contents).first { $0.module == module }
        if had?.hash == engine.hash {
            context.log.notice("[Engine] The tree has \(module) \(version) already")
            return
        }
        try await Blocking.run {
            if had != nil { try EngineInstall.remove(module: module, from: contents) }
            try EngineInstall.install(engine, into: contents)
        }
        context.log.notice("[Engine] \(had == nil ? "Installed" : "Replaced the tree's with") \(module) \(version) (\(engine.hash.prefix(12))…)")
    }

    /// `APP [--default-id=…] [--name=…] [--icon=…]`: the tree's `Info.plist`,
    /// made if it has none, with what the step says.
    static func app(_ step: PlannedStep, in context: LocalStepContext) async throws {
        let file = WrappLayout(app: context.tree).infoPlist
        try Plist.update(file) { plist in
            if let id = step.option("default-id") { plist["CFBundleIdentifier"] = id }
            if let name = step.option("name") {
                plist["CFBundleName"] = name
                plist["CFBundleDisplayName"] = name
            }
            if let icon = step.option("icon") { plist["CFBundleIconFile"] = (icon as NSString).lastPathComponent }
        }
    }

    // MARK: - MOVE and REMOVE

    static func move(_ step: PlannedStep, in context: LocalStepContext) async throws {
        guard step.arguments.count == 2 else { throw StepFailure.recipe("\(step.origin): MOVE takes what to move and where") }
        let source = try context.location(step.arguments[0]), destination = try context.location(step.arguments[1])
        try await Blocking.run {
            let files = FileManager.default
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
            try files.moveItem(at: source, to: destination)
        }
    }

    static func remove(_ step: PlannedStep, in context: LocalStepContext) async throws {
        guard let path = step.arguments.first else { throw StepFailure.recipe("\(step.origin): REMOVE names what to remove") }
        let target = try context.location(path)
        try await Blocking.run {
            do {
                try FileManager.default.removeItem(at: target)
            } catch CocoaError.fileNoSuchFile {
            }
        }
    }

    // MARK: - RUN

    /// `RUN [--mount=…] [--env NAME=<value>] <program> <arguments>`: the
    /// program through its path type's module, its mounts in place, its exit
    /// code the step's success.
    static func runProgram(_ step: PlannedStep, in context: LocalStepContext) async throws {
        guard let program = step.arguments.first else { throw StepFailure.recipe("\(step.origin): RUN names its program") }
        var environment: [String: String] = [:]
        for pair in step.options["env"] ?? [] {
            let parts = pair.split(separator: "=", maxSplits: 1)
            environment[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        let code = try await context.runProgram(ProgramRun(program: program, arguments: Array(step.arguments.dropFirst()),
                                                           environment: environment, step: step),
                                                mounts: step.options["mount"] ?? [])
        guard code == 0 else { throw StepFailure.failed("\(step.origin): \(program) exited with \(code)") }
    }
}
