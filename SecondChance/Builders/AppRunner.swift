//
//  AppRunner.swift
//  SecondChance
//
//  Second Chance's side of a plan's run: what the runner is given, and
//  what it says turned into the build's events.

import Foundation
import GameCatalog
import SecondChanceKit
import WrappBuilder

/// What the runner is given by Second Chance (docs/wrapp-build.md#the-runner):
/// its events onto the build's bus, its questions through `WrappBuildInput`,
/// downloads from those Second Chance ships, then the download cache, and
/// AutoIt, which the installer module's Swift provides.
enum AppRunner {
    /// A configuration, and the emitter to `finish` once the run is over, so
    /// every event has reached the bus before the build goes on.
    static func configuration(
        bus: EventBus<AppEvent>, input: WrappBuildInput, game: GameInfo, inputs: any InputProvider,
        downloader: Downloader, executors: [String: any ModuleExecutor] = [:],
        moduleStage: @escaping @Sendable (PlannedStage, URL) async throws -> Void = { _, _ in }
    ) -> (RunnerConfiguration, OrderedEmitter) {
        let translator = BuildEventTranslator()
        let emitter = OrderedEmitter { event in
            for translated in translator.translate(event) { await bus.publishWrappBuild(translated) }
        }
        let slug = game.id
        // Looked up once, here, as the service is the main actor's.
        let autoIt = AutoItService.shared.isAvailable ? AutoItService.shared.autoitDir : nil
        let configuration = RunnerConfiguration(
            executors: executors, inputs: inputs, emitter: emitter,
            ask: { question in try await answer(question, input: input, game: slug) },
            fetch: { url, sha256, progress in
                if let shipped = DownloadCache.shipped(sha256: sha256) { return shipped }
                return try await downloader.fetch(DownloadRequest(urls: [url], sha256: sha256), progress: progress).file
            },
            providedFile: { fullForm in fullForm == "module:installer:/autoit" ? autoIt : nil },
            moduleStage: moduleStage)
        return (configuration, emitter)
    }

    /// A step's question, asked as Second Chance asks it.
    static func answer(_ question: StepQuestion, input: WrappBuildInput, game: String) async throws -> StepAnswer {
        switch question {
        case .confirmStepFailure(let name, let message):
            let patch = GamePatchCatalog.shared.allPatches(forGame: game).first { $0.id == name }
                ?? GamePatch.unlisted(id: name, game: game)
            return await input.confirmPatchFailure(patch, error: StepFailure.failed(message)) ? .yes : .no
        case .choose, .confirm:
            throw WrappBuildError.buildRecipeProblem("this build can't ask an added module's questions yet")
        }
    }
}

/// The runner's events as the build's: the plan's shape as it is, and the
/// `EMIT` strings Second Chance reads (`emit-vocabulary.yaml`) as its
/// progress screen's phase, substep and progress. A phase stays until a later
/// one is reached, and never goes back; without one emitted, the phase an
/// instruction reaches is Second Chance's own table's. Used from one task
/// only, the emitter's, so it keeps its state unguarded.
nonisolated final class BuildEventTranslator: @unchecked Sendable {
    /// The phase reached, by its place in `SecondChanceEmits.phases`.
    private var phase: Int?
    /// The substep an `EMIT` gave the next step.
    private var nextSubstep: String?

    /// The phase each instruction reaches when the Wrappfile emits none.
    static let phaseByInstruction: [String: String] = [
        "WINE.KEEP-DISCS": "copying-installer",
        "INSTALLER.RUN": "installing-game", "HER-DOWNLOAD.INSTALL": "installing-game",
        "STEAM.INSTALL": "installing-game", "BIG-FISH.INSTALL": "installing-game",
    ]

    func translate(_ event: BuildEvent) -> [WrappBuildEvent] {
        switch event {
        case .stepStarted(let ref), .stepRestored(let ref):
            var events: [WrappBuildEvent] = [event.isRestored
                ? .stepRestored(name: ref.name, keyword: ref.step.keyword)
                : .stepStarted(name: ref.name, keyword: ref.step.keyword)]
            let reached = Self.phaseByInstruction[ref.step.keyword].flatMap(SecondChanceEmits.phases.firstIndex(of:))
            if let reached, reached > (phase ?? -1) {
                phase = reached
                events.append(.progress(state(substep: nextSubstep)))
            } else if let substep = nextSubstep {
                events.append(.progress(state(substep: substep)))
            }
            nextSubstep = nil
            return events
        case .stepDone(let ref):
            return [.stepDone(name: ref.name)]
        case .stepSkipped(let ref, let message):
            return [.stepSkipped(name: ref.name, message: message)]
        case .emitted(let string):
            return [.emitted(string)] + read(string)
        case .instructions(let text):
            return [.instructions(text)]
        case .stepProgress(let progress):
            return [.stepProgress(progress.map { StepProgress(fraction: $0.fraction, text: $0.text ?? "") })]
        case .substep(let text):
            return phase == nil ? [] : [.progress(state(substep: text))]
        case .module:
            return []
        }
    }

    /// What one of Second Chance's strings says.
    private func read(_ string: String) -> [WrappBuildEvent] {
        let prefix = SecondChanceEmits.prefix
        if string.hasPrefix(prefix + "phase."), let reached = SecondChanceEmits.phases.firstIndex(of: String(string.dropFirst((prefix + "phase.").count))) {
            guard reached > (phase ?? -1) else { return [] }
            phase = reached
            return [.progress(state(substep: nil))]
        }
        if string.hasPrefix(prefix + "substep.") {
            nextSubstep = WineManager.progressText(String(string.dropFirst((prefix + "substep.").count)))
            return []
        }
        if string.hasPrefix(prefix + "progress.") {
            let figures = string.dropFirst((prefix + "progress.").count).split(separator: "/").compactMap { Double($0) }
            guard figures.count == 2, figures[1] > 0 else { return [] }
            return [.stepProgress(StepProgress(fraction: min(1, figures[0] / figures[1]), text: "\(Int(figures[0])) of \(Int(figures[1]))"))]
        }
        return []
    }

    /// The build's state at the phase reached, with `substep`.
    private func state(substep: String?) -> WrappBuildState {
        switch SecondChanceEmits.phases[phase ?? 0] {
        case "copying-installer": .copyingInstaller(substep: substep)
        case "installing-game": .installingGame(substep: substep)
        case "configuring": .configuringWrapp(substep: substep)
        default: .settingUpWrapp(substep: substep)
        }
    }
}

nonisolated extension BuildEvent {
    var isRestored: Bool { if case .stepRestored = self { true } else { false } }
}
