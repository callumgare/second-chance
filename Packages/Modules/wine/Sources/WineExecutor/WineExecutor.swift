//
//  WineExecutor.swift
//  WineExecutor
//
//  The wine module's executor: its instructions, carried out in a tree's
//  prefix, and the Windows programs a build runs.

import CryptoKit
import Foundation
import Logging
import ProcessKit
import WineKit
import WrappFormat
import WrappModuleKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.WineExecutor")

/// Carries out `WINE.DRIVES`, `REGISTRY`, `WINETRICKS`, `MOUNT` and `PATCH`,
/// and its
/// setup steps `HELPERS` and `PREFIX`, in the step's tree, and runs a
/// `wine:` program for `RUN` (docs/modules.md#executors). Portable: it needs
/// nothing of Second Chance's.
public nonisolated struct WineExecutor: ModuleExecutor {
    public static let handles = ["DRIVES", "REGISTRY", "WINETRICKS", "MOUNT", "KEEP-DISCS", "HELPERS", "PREFIX", "PATCH"]

    /// 2: drives are replaced in place and every letter's device link
    /// (`x::`) is blocked too (`WineDrives.showOnly`), so a prefix layer the
    /// first revision made, which may hold a device link Wine wrote for a
    /// disc the Mac had mounted, is made again rather than restored.
    public static var revision: Int { 2 }

    /// The winetricks it runs; nil for the module's own.
    let winetricks: URL?
    /// The in-process helpers `HELPERS` lays in, when the caller has them.
    let helpers: URL?
    /// The longest a `RUN` of a Windows program may take.
    let programTimeout: TimeInterval
    /// The prepared engine's `build-tools` for the tree, which winetricks
    /// finds cabextract in.
    let buildTools: @Sendable (URL) -> URL?

    /// `WATCH --wine.busy`, for a step in `context`'s tree.
    public func watch(_ name: String, value: String?, in context: any StepContext) -> (any WatchProbe)? {
        name == "busy" ? WineBusyWatch(tree: context.tree) : nil
    }

    public init(winetricks: URL? = nil, helpers: URL? = nil, programTimeout: TimeInterval = 1800,
                buildTools: @escaping @Sendable (URL) -> URL? = { _ in nil }) {
        self.buildTools = buildTools
        self.winetricks = winetricks
        self.helpers = helpers
        self.programTimeout = programTimeout
    }

    /// What a step makes that its text doesn't say: `HELPERS` lays in this
    /// build's helpers, `WINETRICKS` runs this winetricks, and `PATCH` makes
    /// this revision of each patch it names, so a layer
    /// kept by another Second Chance with other ones isn't restored.
    public func keyInputs(for step: PlannedStep, in context: any StepContext) async throws -> KeyInputs {
        switch step.instruction {
        case "HELPERS":
            guard let helpers else { return KeyInputs() }
            return KeyInputs([KeyInput("helpers", try await Blocking.run { try Self.hash(helpers) })])
        case "WINETRICKS":
            guard let script = await Winetricks(wine: Wine(wrapp: context.tree), script: winetricks).resolvedScript() else { return KeyInputs() }
            return KeyInputs([KeyInput("winetricks", try await Blocking.run { try Self.hash(script) })])
        case "PATCH":
            let patches = try WinePatch.named(step.arguments, origin: step.origin)
            return KeyInputs(patches.map { KeyInput("patch-\($0.name)", String($0.revision)) })
        default:
            return KeyInputs()
        }
    }

    /// A file's sha256.
    nonisolated static func hash(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    public func run(_ step: PlannedStep, in context: any StepContext) async throws {
        do {
            try await carryOut(step, in: context)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // What else was at work in the tree as it failed: Wine's programs
            // starting there during a disc's copy was what broke it once, and
            // the failure itself didn't say so.
            let running = await Blocking.run { Wine(wrapp: context.tree).server.programs() }
            let names = running.map { "\($0.name) (pid \($0.pid))" }.joined(separator: ", ")
            logger.error("\(step.keyword) failed with \(running.isEmpty ? "no Wine program running in its prefix" : "Wine running in its prefix: \(names)")")
            throw error
        }
    }

    func carryOut(_ step: PlannedStep, in context: any StepContext) async throws {
        let wine = Wine(wrapp: context.tree)
        switch step.instruction {
        case "DRIVES":
            // C: at drive_c, relative so the prefix still works copied into a
            // wrapp, and every other drive blocked: Z: shows the whole Mac.
            guard step.option("only") == "C:" else {
                throw StepFailure.recipe("\(step.origin): this build keeps only C: (WINE.DRIVES --only=C:)")
            }
            // Wine's server, its mount manager with it, may still be running
            // from wineboot, giving the Mac's discs any letter that has
            // nothing at either of its names: showOnly replaces each entry in
            // place, leaving none empty for a moment, and blocks every
            // letter's device link too (WineDrives, "How Wine adds the Mac's
            // disks").
            try wine.drives.showOnly("../drive_c", as: "c")
        case "REGISTRY":
            guard let target = step.arguments.first, let colon = target.lastIndex(of: ":") else {
                throw StepFailure.recipe("\(step.origin): WINE.REGISTRY names <key>:<name>")
            }
            let key = Self.registryKey(String(target[..<colon]))
            let name = String(target[target.index(after: colon)...])
            if step.has("remove") {
                try await wine.registry.deleteValue(name, in: key)
            } else {
                guard step.arguments.count == 2 else { throw StepFailure.recipe("\(step.origin): WINE.REGISTRY --set needs the value") }
                try await wine.registry.set(.string(step.arguments[1]), for: name, in: key)
            }
        case "WINETRICKS":
            guard let verb = step.arguments.first else { return }
            try await Winetricks(wine: wine, script: winetricks, tools: buildTools(context.tree)).install(verb)
        case "MOUNT":
            // A folder of the tree's given a drive, kept for later steps and at launch.
            guard step.arguments.count == 2, let folder = context.location(of: step.arguments[0]),
                  let letter = step.arguments[1].lowercased().first, step.arguments[1].count <= 2 else {
                throw StepFailure.recipe("\(step.origin): WINE.MOUNT takes a folder in the prefix and a drive letter")
            }
            try wine.drives.mount(folder, as: letter)
            if step.has("cdrom") { try await wine.drives.setKind(.cdrom, of: letter) }
        case "KEEP-DISCS":
            try await keepDiscs(step, in: context)
        case "HELPERS":
            try layInHelpers(in: context.tree, step: step)
        case "PATCH":
            // The tree's own Wine, cloned from the engine store, patched in place.
            let tree = context.tree
            for patch in try WinePatch.named(step.arguments, origin: step.origin) {
                let already: Bool
                do {
                    already = try await Blocking.run { try patch.apply(tree) }
                } catch let error as StepFailure {
                    throw error
                } catch {
                    throw StepFailure.failed("\(step.origin): couldn't make the patch \(patch.name): \(error)")
                }
                logger.notice("\(patch.does) (\(patch.name), \(already ? "already patched" : "patched"))")
            }
        case "PREFIX":
            // wineboot's prefix, Wine's server let finish so it's all written.
            try await wine.run(.wine(["wineboot", "-u"]))
            try await Self.endLeftovers(of: wine, after: "wineboot", limit: Self.leftoverLimit())
        default:
            throw StepFailure.recipe("\(step.origin): the wine module has no instruction \(step.instruction)")
        }
        logger.notice("✓ \(step)")
    }

    /// A `wine:` program, its arguments in Windows's style, run in the
    /// tree's Wine with its environment, on a desktop of its own (at the
    /// step's `--wine.colors` and `--wine.display-mode`), its exit
    /// code returned once every program it started has finished too. A
    /// program that found no display is run once more in a fresh session:
    /// on a loaded Mac a desktop reported ready has failed a program, and the
    /// session stays that way.
    public func runProgram(_ program: ProgramRun, in context: any StepContext) async throws -> Int32 {
        do {
            return try await runOnce(program, in: context)
        } catch WineError.noDisplay {
            logger.warning("\(program.program) found no display to open its windows on — restarting the Wine session and trying once more")
            await Wine(wrapp: context.tree).server.stop()
            return try await runOnce(program, in: context)
        }
    }

    func runOnce(_ program: ProgramRun, in context: any StepContext) async throws -> Int32 {
        let path = program.program.hasPrefix("wine:") ? String(program.program.dropFirst("wine:".count)) : program.program
        let arguments = program.arguments.map(Self.windowsStyle)
        let options = program.step.options.compactMapValues(\.first)
        var wine = Wine(wrapp: context.tree)
        // --wine.colors: every program of the session, explorer.exe among
        // them, sees a screen of that depth (docs/wine-in-process-helpers.md#screen-depth).
        if let depth = RecordedLaunch.screenDepth(options) {
            wine.sessionVariables = Wine.screenDepthVariables(depth)
        }
        let timeout = program.timeout.map { TimeInterval($0.components.seconds) } ?? programTimeout
        let desktop = await WineDesktop.start(wine, logger: logger, outputLogger: logger)
        defer { desktop?.release() }
        // --wine.display-mode: the session in that mode before the program
        // looks at the screen, as a launch's is. It needs the desktop, which
        // registers Wine's displays.
        if let mode = RecordedLaunch.displayMode(options) {
            await WineDisplayMode.set(mode, in: wine, logger: logger)
        }
        let code: Int32
        do {
            try await wine.run(.program(Self.windowsStyle(path), arguments), environment: program.environment, timeout: timeout)
            code = 0
        } catch WineError.executionFailed(let exit) {
            code = exit
        }
        // A program failing still waits for what it started, for as long as
        // the step's --timeout gives the program, or the leftovers' limit.
        desktop?.release()
        try await Self.endLeftovers(of: wine, after: path,
                                    limit: program.timeout.map { TimeInterval($0.components.seconds) } ?? Self.leftoverLimit())
        return code
    }

    // MARK: - Discs

    /// `WINE.KEEP-DISCS <disc>… --into=<folder> [--combined=<folder>]`: each
    /// disc copied into `<into>/disk-<n>`, writable, with how much is done
    /// as the step's progress; for more than one, merged into `--combined`
    /// as links, the first disc's files winning. Each gets a CD-ROM drive
    /// from D: in order, kept for the game, which may check for its disc.
    func keepDiscs(_ step: PlannedStep, in context: any StepContext) async throws {
        guard let intoPath = step.option("into"), let into = context.location(of: intoPath) else {
            throw StepFailure.recipe("\(step.origin): WINE.KEEP-DISCS keeps the discs in a folder of the prefix (--into)")
        }
        let wine = Wine(wrapp: context.tree)
        let names = step.arguments.compactMap(PlannedStep.input(in:))
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        // The drives are marked as CD drives once the discs have copied, not
        // while they do. Wine starting in a prefix restored from a layer
        // while a disc copied into it made the copy fail, its folders refused
        // with "Operation not permitted" (Thornton Hall's, White Wolf's): the
        // copy is the step's, so nothing else of Wine's runs in the tree
        // meanwhile. It costs a run of Wine after the copy, 8 to 18 s.
        let letters = names.indices.map(Self.driveLetter(forDisc:))
        var kept: [URL] = []
        for (index, name) in names.enumerated() {
            guard let disc = try await context.inputIfGiven(name) else { continue }
            if index > 0 { context.substep(String(localized: "Copying disc \(index + 1)")) }
            let destination = into.appendingPathComponent("disk-\(index + 1)")
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try await copy(disc, to: destination, emitter: context.emitter)
            kept.append(destination)
        }
        context.substep(String(localized: "Getting the discs ready"))
        try await wine.drives.setKind(.cdrom, of: letters)
        if kept.count > 1, let combinedPath = step.option("combined"), let combined = context.location(of: combinedPath) {
            try Self.combine(kept, into: combined)
        }
        // The copies stay, still mounted, for the game as well as its
        // installer: some games check their disc is in the drive.
        for (index, disc) in kept.enumerated() {
            let relative = "../drive_c/" + disc.path.dropFirst(WrappLayout(app: context.tree).driveC.path.count + 1)
            try wine.drives.mount(relative, as: Self.driveLetter(forDisc: index))
            logger.notice("Mounted disk-\(index + 1) as \(Self.driveLetter(forDisc: index)): (cdrom)")
        }
    }

    /// The drive letter disc `index` (from 0) is at: D: on.
    public static func driveLetter(forDisc index: Int) -> Character {
        Character(UnicodeScalar(UInt8(100 + index)))
    }

    /// Links in `combined` to each disc's files, the first disc's winning.
    static func combine(_ discs: [URL], into combined: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: combined, withIntermediateDirectories: true)
        for disc in discs {
            for item in try files.contentsOfDirectory(at: disc, includingPropertiesForKeys: nil) where item.lastPathComponent != ".DS_Store" {
                // .DS_Store left out: codesign fails on a link to one.
                let link = combined.appendingPathComponent(item.lastPathComponent)
                if !files.fileExists(atPath: link.path) {
                    try files.createSymbolicLink(atPath: link.path, withDestinationPath: "../\(disc.lastPathComponent)/\(item.lastPathComponent)")
                }
            }
        }
    }

    /// A disc copied with its size as the step's progress.
    func copy(_ disc: URL, to destination: URL, emitter: any EventEmitter) async throws {
        let total = Self.size(of: disc)
        logger.notice("Copying \(disc.path) (\(total.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "size unknown"))")
        @Sendable func text(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        try await DiscCopy.copy(from: disc, to: destination, total: total) { progress in
            let fraction = progress.total.map { min(1, Double(progress.copied) / Double(max($0, 1))) }
            emitter.emit(.stepProgress(.init(fraction: fraction,
                                             text: progress.total.map { "\(text(progress.copied)) of \(text($0))" } ?? "\(text(progress.copied)) copied")))
        }
        if let total { emitter.emit(.stepProgress(.init(fraction: 1, text: "\(text(total)) of \(text(total))"))) }
    }

    /// How full a disc is, or a folder's files' size; nil when it can't be told.
    static func size(of folder: URL) -> Int64? {
        if let values = try? folder.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .isVolumeKey]),
           values.isVolume == true, let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity {
            return Int64(total - available)
        }
        return DirectorySize.measure(folder).bytes
    }

    /// Wine's session ended, so wineserver has written the registry to its
    /// files and nothing is running in the tree; nothing to wait for when
    /// no wineserver is running for it.
    public func checkpoint(_ context: any StepContext) async throws {
        let server = Wine(wrapp: context.tree).server
        guard await server.isRunning else { return }
        try await Self.endLeftovers(of: Wine(wrapp: context.tree), after: "the stage's last step", limit: Self.leftoverLimit())
        await server.stop()
    }

    // MARK: - Leftovers

    /// How long the programs a step leaves running may go on once its own
    /// program has finished, unless the step gives a --timeout:
    /// `SECOND_CHANCE_WINE_LEFTOVER_SECONDS`, else 5 minutes. Builds' logs
    /// show this wait at about 3 s (Wine's server lingering after its last
    /// program), 7 s at most on a fully loaded Mac, and 73–97 s for the two
    /// InstallShield installers whose setup.exe hands the install to a
    /// child and exits; a window left open (an installer's folder, a
    /// dialog nobody answers) waited for ever, or until a test timed out.
    public static func leftoverLimit(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
        environment["SECOND_CHANCE_WINE_LEFTOVER_SECONDS"].flatMap(TimeInterval.init).flatMap { $0 > 0 ? $0 : nil } ?? 300
    }

    /// Wait for what a step left running in `wine`'s session to finish, for
    /// at most `limit` (stretched while the Mac is heavily loaded); past
    /// it, log what's still running and end the session, Wine's own way
    /// first (`stop`, then `kill`). The step carries on: its program has
    /// finished, and what it was to make is judged by its own checks (its
    /// exit code, `--creates`, its signals), as a leftover that was still
    /// working leaves something those miss.
    static func endLeftovers(of wine: Wine, after what: String, limit: TimeInterval) async throws {
        let server = wine.server
        if try await server.waitUntilProgramsExit(allowance: WaitAllowance(limit: limit)) { return }
        let left = await Blocking.run { server.programs() }
        let names = left.map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")
        logger.warning("""
            [Wine] Wine programs still running \(Int(limit)) s after \(what) finished, so its session is being ended: \
            \(names.isEmpty ? "none found, only Wine's server" : names) \
            (SECOND_CHANCE_WINE_LEFTOVER_SECONDS gives them longer)
            """)
        await server.stop()
        if await !server.waitUntilStopped(timeout: 15) { await server.kill() }
    }

    /// The helpers the Mac driver loads, laid in the tree's `Frameworks/`.
    func layInHelpers(in tree: URL, step: PlannedStep) throws {
        guard let helpers else {
            throw StepFailure.recipe("\(step.origin): this build has no in-process helpers to lay in")
        }
        let target = WrappLayout(app: tree).frameworks.appendingPathComponent(helpers.lastPathComponent)
        let files = FileManager.default
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
        try files.copyItem(at: helpers, to: target)
    }

    /// A registry key the wine module's steps name: in full
    /// (`HKEY_CURRENT_USER\Software\Wine\…`), or by a short name.
    public static func registryKey(_ name: String) -> WineRegistry.Key {
        if name.hasPrefix("HKEY_") { return WineRegistry.Key(rawValue: name) }
        return switch name {
        case "mac-driver": #"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#
        case "direct3d": #"HKEY_CURRENT_USER\Software\Wine\Direct3D"#
        default: .x11Driver
        }
    }

    /// `C:/a/b` as `C:\a\b`; anything else as it is.
    public static func windowsStyle(_ argument: String) -> String {
        let letters = argument.prefix(3)
        guard letters.count == 3, letters.first?.isLetter == true, letters.dropFirst().first == ":",
              letters.last == "/" else { return argument }
        return argument.replacingOccurrences(of: "/", with: "\\")
    }
}
