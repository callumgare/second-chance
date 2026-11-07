//
//  BasiliskRunning.swift
//  BasiliskExecutor
//
//  The build's work inside the emulated Mac (`BASILISK.RUN`), and on its
//  startup disk from outside (`BASILISK.STARTUP`, with hfsutils).

import Foundation
import Logging
import ProcessKit
import WrappModuleKit

nonisolated extension BasiliskExecutor {
    /// The tree's Mac, booted in Basilisk II with `basilisk_mac.m` inserted,
    /// which drives it by the script, then shuts it down: what it changed on
    /// the startup disk stays there. Fails when the script fails, the helper
    /// can't be loaded, or the Mac hasn't shut down in `limit`.
    func runAutomation(_ step: PlannedStep, in context: any StepContext) async throws {
        guard let option = step.option("automation"), let script = context.file(option) else {
            throw StepFailure.recipe("\(step.origin): BASILISK.RUN needs --automation=<script>")
        }
        guard let helpers, FileManager.default.fileExists(atPath: helpers.path) else {
            throw StepFailure.failed("\(step.origin): the in-process helpers that drive the Mac aren't here")
        }
        let tree = context.tree
        let folder = tree.appendingPathComponent(Self.folder)
        let emulator = tree.appendingPathComponent("Contents/MacOS/BasiliskII")
        guard FileManager.default.fileExists(atPath: emulator.path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("boot.hfv").path) else {
            throw StepFailure.recipe("\(step.origin): BASILISK.RUN needs the basilisk engine and its set-up in this stage")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("basilisk-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let prefs = scratch.appendingPathComponent("basilisk.prefs")
        try Self.prefs(folder: folder, screen: step.option("screen")).write(to: prefs, atomically: true, encoding: .utf8)

        let outcome = Outcome()
        let process = TaggedProcess(logger: context.log)
        process.executableURL = emulator
        process.arguments = ["--config", prefs.path]
        process.currentDirectoryURL = scratch
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        environment["DYLD_INSERT_LIBRARIES"] = helpers.path
        environment["BASILISK_MAC_EXE"] = "BasiliskII"
        environment["BASILISK_MAC_AUTOMATION"] = script.path
        environment["BASILISK_MAC_AUTOMATION_PICTURES"] = Self.picturesFolder.path
        environment["HOME"] = scratch.path   // Basilisk II's own prefs and its .basilisk_ii_xpram
        process.environment = environment
        process.onLine = { line in outcome.observe(line) }
        context.substep(String(localized: "Setting up the game's Mac"))
        try process.run()
        let pid = process.processIdentifier
        context.log.notice("[Basilisk] The Mac is booted for \(script.lastPathComponent), Basilisk II PID \(pid)")

        let deadline = Date().addingTimeInterval(Self.limit(step))
        while kill(pid, 0) == 0 || process.process.isRunning {
            if Date() > deadline {
                context.log.error("[Basilisk] The Mac's automation hasn't finished in its time: shutting the Mac down")
                kill(pid, SIGUSR2)
                try await Task.sleep(for: .seconds(20))
                if process.process.isRunning { kill(pid, SIGKILL) }
                throw StepFailure.failed("\(step.origin): the Mac's automation didn't finish in its time (pictures in \(Self.picturesFolder.path))")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        switch outcome.result {
        case .finished:
            context.log.notice("[Basilisk] The Mac's automation finished and the Mac shut down (exit \(process.process.terminationStatus))")
        case .failed(let message):
            throw StepFailure.failed("\(step.origin): the Mac's automation failed: \(message) (pictures in \(Self.picturesFolder.path))")
        case nil:
            throw StepFailure.failed("\(step.origin): Basilisk II ended (exit \(process.process.terminationStatus)) before its automation said how it went")
        }
    }

    /// How long the automation may take: `--limit=<seconds>`, else 15 minutes.
    static func limit(_ step: PlannedStep) -> TimeInterval {
        step.option("limit").flatMap(TimeInterval.init) ?? 15 * 60
    }

    /// Where a failed automation's picture of the screen is left.
    static var picturesFolder: URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("basilisk-automation", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Basilisk II's prefs for a build's boot: as the wrapp's
    /// (`BasiliskRuntime.prefs`), with the tree's ROM, startup disk and CDs.
    static func prefs(folder: URL, screen: String?) throws -> String {
        let parts = (screen ?? "").split(separator: "x").compactMap { Int($0) }
        let (width, height, depth) = parts.count == 3 ? (parts[0], parts[1], parts[2]) : (640, 480, 8)
        let discs = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("cdrom-") && $0.hasSuffix(".iso") }.sorted()
        var lines = ["rom \(folder.appendingPathComponent("mac.rom").path)",
                     "disk \(folder.appendingPathComponent("boot.hfv").path)"]
        lines += discs.map { "cdrom \(folder.appendingPathComponent($0).path)" }
        lines += ["screen win/\(width)/\(height)", "displaycolordepth \(depth)", "ramsize \(64 << 20)", "modelid 14",
                  "cpu 4", "fpu true", "jit false", "nogui true", "nosound true", "frameskip 0", "ignoresegv true",
                  "idlewait true", "delay 500"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// `BASILISK.STARTUP <basilisk:disk:…:item>`: the item on the Mac's
    /// startup disk (an alias the automation made) moved into the System
    /// Folder's Startup Items, so the Mac opens it at every boot. Done with
    /// hfsutils from the engine's build tools, with the Mac shut down.
    func addStartupItem(_ step: PlannedStep, in context: any StepContext) async throws {
        guard let argument = step.arguments.first, argument.hasPrefix("basilisk:") else {
            throw StepFailure.recipe("\(step.origin): BASILISK.STARTUP names an item on the Mac (basilisk:<disk>:<folder>:<item>)")
        }
        guard let tools = buildTools(context.tree)?.appendingPathComponent("hfsutils") else {
            throw StepFailure.failed("\(step.origin): the basilisk engine's hfsutils aren't here")
        }
        let disk = context.tree.appendingPathComponent(Self.folder).appendingPathComponent("boot.hfv")
        let parts = argument.dropFirst("basilisk:".count).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else {
            throw StepFailure.recipe("\(step.origin): \(argument) isn't an item on a Mac disk (basilisk:<disk>:<folder>:<item>)")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("basilisk-hfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let hfs = HFSUtils(tools: tools, home: scratch, log: context.log)
        let volume = try await hfs.mount(disk)
        do {
            guard volume == parts[0] else {
                throw StepFailure.recipe("\(step.origin): \(argument) is on \(parts[0]), and the Mac's startup disk is \(volume)")
            }
            let item = ":" + parts.dropFirst().joined(separator: ":")
            try await hfs.run("hrename", [item, ":System Folder:Startup Items:"])
            context.log.notice("[Basilisk] \(parts.last ?? item) is in the Mac's Startup Items")
        } catch {
            _ = try? await hfs.run("humount", [])
            throw error
        }
        try await hfs.run("humount", [])
    }
}

/// hfsutils' commands, with a `HOME` of the build's own (they keep the
/// mounted volume in `~/.hcwd`).
nonisolated struct HFSUtils {
    let tools: URL
    let home: URL
    let log: Logger

    /// Mounts `disk`; its volume's name.
    func mount(_ disk: URL) async throws -> String {
        let output = try await run("hmount", [disk.path])
        // "Volume name is "System7_5_3""
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("Volume name is") }),
              let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last else {
            throw StepFailure.failed("hmount said nothing of the volume's name: \(output)")
        }
        return String(line[line.index(after: first)..<last])
    }

    @discardableResult
    func run(_ tool: String, _ arguments: [String]) async throws -> String {
        let result = try await Process.output(of: tools.appendingPathComponent(tool).path, arguments,
                                              environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        let text = result.output + result.errorOutput
        log.debug("[Basilisk] \(tool) \(arguments.joined(separator: " ")): \(text)")
        guard result.status == 0 else {
            throw StepFailure.failed("\(tool) \(arguments.joined(separator: " ")) failed (\(result.status)): \(text)")
        }
        return text
    }
}

/// What the helper said of the automation, from Basilisk II's output.
nonisolated final class Outcome: @unchecked Sendable {
    enum Result: Equatable { case finished, failed(String) }
    private let lock = NSLock()
    private var said: Result?

    var result: Result? { lock.withLock { said } }

    func observe(_ line: String) {
        guard let range = line.range(of: "second-chance-helper[BasiliskMac] ") else { return }
        let message = String(line[range.upperBound...])
        if message.hasPrefix("notice: automation finished") {
            lock.withLock { said = .finished }
        } else if let failed = message.range(of: "automation failed ") {
            let text = String(message[failed.lowerBound...])
            lock.withLock { said = .failed(text) }
        }
    }
}
