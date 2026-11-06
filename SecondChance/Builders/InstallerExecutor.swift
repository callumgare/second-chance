//
//  InstallerExecutor.swift
//  SecondChance
//
//  The installer module's executor, until its kit moves into its package:
//  INSTALLER.RUN, carried out by GameInstallerRunner.

import Foundation
import Synchronization
import GameCatalog
import SecondChanceKit
import WrappBuilder

/// Carries out `INSTALLER.RUN` in the step's tree (docs/modules.md#executors):
/// an install from an input, silently with its answer file or under AutoIt,
/// or with `--patch` a patcher put in place by the step's mounts. Not
/// portable yet: `GameInstallerRunner` is the app's, and publishes the
/// installer's events on the build's bus itself.
nonisolated final class InstallerExecutor: ModuleExecutor, @unchecked Sendable {
    static let handles = ["RUN"]

    let runner: GameInstallerRunner
    let gameInfo: GameInfo
    let source: WrappSource
    /// The program to install with when the input's isn't an installer by name.
    let installerName: String?
    let input: WrappBuildInput
    /// Whether an install ran, rather than being restored from a layer:
    /// only one that ran said where the game's program is.
    var installed: Bool { ran.withLock { $0 } }
    private let ran = Mutex(false)

    init(runner: GameInstallerRunner, gameInfo: GameInfo, source: WrappSource, installerName: String?, input: WrappBuildInput) {
        self.runner = runner
        self.gameInfo = gameInfo
        self.source = source
        self.installerName = installerName
        self.input = input
    }

    func run(_ step: PlannedStep, in context: any StepContext) async throws {
        let tree = context.tree
        if step.has("patch") {
            try await runner.runPlacedPatcher(step, wrappPath: tree)
            return
        }
        guard PlannedStep.input(in: step.option("from")) != nil else {
            throw StepFailure.recipe("\(step.origin): INSTALLER.RUN installs from an input (--from=${input.<name>})")
        }
        if let answerFile = step.option("answer-file") {
            guard let file = context.file(answerFile) else { throw StepFailure.recipe("\(step.origin): the plan has no file \(answerFile)") }
            try Self.installAnswerFile(file, into: WrappLayout(app: tree).installers)
        }
        let automation = step.option("automation").flatMap(context.file)
        let creates = try GameInstallerRunner.expectedProgram(of: step)
        let input = input, gameInfo = gameInfo, source = source, installerName = installerName, runner = runner
        _ = try await runner.installGameWithWine(
            wrappPath: tree, gameInfo: gameInfo, source: source, installerName: installerName,
            unattended: await input.isUnattended, chooseGameProgram: { try await input.chooseGameProgram(among: $0) },
            automation: automation, creates: creates, stepContext: context)
        ran.withLock { $0 = true }
    }

    /// Put the plan's answer file (`bundle:assets/disc.iss`) where the
    /// installer runner looks for one: `setup.iss` among the installer's discs.
    static func installAnswerFile(_ source: URL, into installers: URL) throws {
        let files = FileManager.default
        let destination = installers.appendingPathComponent("setup.iss")
        try files.createDirectory(at: installers, withIntermediateDirectories: true)
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.copyItem(at: source, to: destination)
    }
}

/// The disc source's inputs (decision 20 of the builders plan): disc 1,
/// mounted already, and disc 2, asked for when a step first needs it, and
/// mounted if it's an image. `disksResolved` is published once both are
/// known.
nonisolated final class DiscInputs: InputProvider, @unchecked Sendable {
    let disc1: URL
    /// Disc 1's image file when it was given as one (`disc-1.image`), for an
    /// emulator whose CD has to be an image (`BASILISK.CDROM`).
    let disc1Image: URL?
    let diskCount: Int
    let resolveDisc2: @Sendable () async throws -> URL?
    private let lock = NSLock()
    private var disc2: Task<URL?, Error>?
    private var disc2Resolved: URL?

    init(disc1: URL, disc1Image: URL? = nil, diskCount: Int, resolveDisc2: @escaping @Sendable () async throws -> URL?) {
        self.disc1 = disc1
        self.disc1Image = disc1Image
        self.diskCount = diskCount
        self.resolveDisc2 = resolveDisc2
    }

    func input(_ name: String) async throws -> URL {
        guard let url = try await inputIfGiven(name) else { throw StepFailure.recipe("this build has no \(name)") }
        return url
    }

    func inputIfGiven(_ name: String) async throws -> URL? {
        switch name {
        case "disc-1":
            // A one-disc game's discs are all known now.
            if diskCount <= 1 { _ = try await secondDisc() }
            return disc1
        case "disc-2":
            return try await secondDisc()
        case "disc-1.image":
            return disc1Image
        default:
            return nil
        }
    }

    /// Disc 1 always; disc 2 only once a step has asked for it, as working
    /// it out ejects disc 1 and asks for disc 2.
    func inputIfReady(_ name: String) async throws -> URL? {
        switch name {
        case "disc-1": return disc1
        case "disc-2": return lock.withLock { disc2Resolved }
        default: return nil
        }
    }

    /// Disc 2, resolved once, whoever asks first.
    private func secondDisc() async throws -> URL? {
        let task = lock.withLock { () -> Task<URL?, Error> in
            if let disc2 { return disc2 }
            let made = Task { [self] in
                let url = try await resolveDisc2()
                lock.withLock { disc2Resolved = url }
                return url
            }
            disc2 = made
            return made
        }
        return try await task.value
    }
}
