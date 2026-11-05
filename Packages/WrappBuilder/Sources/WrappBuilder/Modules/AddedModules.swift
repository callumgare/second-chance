//
//  AddedModules.swift
//  WrappBuilder
//
//  Modules someone adds (decision 7 of the builders plan;
//  docs/module-programs.md): where they're kept, and importing one.

import Foundation
import ProcessKit
import WrappFormat

public nonisolated enum AddedModules {
    /// `~/Library/Application Support/SecondChance/modules/`, or under what
    /// `SECOND_CHANCE_APP_SUPPORT_DIR` names in its place, so a test never
    /// loads the person's.
    public static func folder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        UserFilesLayout.appSupport(environment: environment).appendingPathComponent("SecondChance/modules", isDirectory: true)
    }

    /// The executors of the added modules among `modules` that bring a
    /// program, by id.
    public static func executors(_ modules: [ModuleFolder]) -> [String: any ModuleExecutor] {
        var executors: [String: any ModuleExecutor] = [:]
        for module in modules {
            guard let program = module.manifest.program else { continue }
            executors[module.manifest.id] = ExternalExecutor(module: module.manifest.id, release: module.manifest.release,
                                                             program: module.file(program))
        }
        return executors
    }

    public struct Problem: Error, CustomStringConvertible {
        public let description: String
    }

    /// The module in `source`, checked and copied into `folder` as
    /// `<namespace>/<name>/`, replacing one there of its id: its
    /// `module.yaml` against the shipped modules' schema (`shipped`), its id
    /// namespaced and no shipped module's, and its program, if it has one,
    /// built for both architectures and speaking a protocol this build does.
    public static func `import`(_ source: URL, shipped: URL, into folder: URL = folder()) async throws -> ModuleFolder {
        let document = try YAML12.load(String(contentsOf: source.appendingPathComponent("module.yaml"), encoding: .utf8))
        guard let id = (document as? [String: Any])?["id"] as? String else {
            throw Problem(description: "\(source.path) has no module.yaml with an id")
        }
        guard id.contains("/") else {
            throw Problem(description: "\(id): an added module's id is namespaced, <namespace>/<name>")
        }
        if FileManager.default.fileExists(atPath: shipped.appendingPathComponent(id).path) {
            throw Problem(description: "\(id) is a shipped module's id")
        }
        if let program = (document as? [String: Any])?["program"] as? String {
            try await check(program: source.appendingPathComponent(program), module: id)
        }
        let destination = folder.appendingPathComponent(id, isDirectory: true)
        let staging = folder.appendingPathComponent(".importing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileCopy.clone(source, to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = folder.appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: destination, to: previous) }
        try FileManager.default.moveItem(at: staging, to: destination)
        switch try ModuleLoader(root: shipped, added: folder).load(destination) {
        case .success(let module):
            try? FileManager.default.removeItem(at: previous)
            return module
        case .failure(let problems):
            try? FileManager.default.removeItem(at: destination)
            if FileManager.default.fileExists(atPath: previous.path) { try? FileManager.default.moveItem(at: previous, to: destination) }
            throw Problem(description: problems.all.map(\.description).joined(separator: "\n"))
        }
    }

    /// Its program runs on either kind of Mac, and speaks a protocol this
    /// build does.
    static func check(program: URL, module: String) async throws {
        guard FileManager.default.isExecutableFile(atPath: program.path) else {
            throw Problem(description: "\(module): its program, \(program.lastPathComponent), isn't an executable in its folder")
        }
        let lipo = try await Process.output(of: "/usr/bin/lipo", ["-archs", program.path])
        let archs = Set(lipo.output.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        let missing = ["arm64", "x86_64"].filter { !archs.contains($0) }
        guard missing.isEmpty else {
            throw Problem(description: "\(module): its program is built without \(missing.joined(separator: " and ")); "
                + "a build runs on either kind of Mac, so it needs arm64 and x86_64 (swift build --arch arm64 --arch x86_64)")
        }
        // It answers hello, at a protocol this build speaks.
        let executor = ExternalExecutor(module: module, release: 0, program: program)
        try await executor.greet()
        await executor.finish()
    }
}
