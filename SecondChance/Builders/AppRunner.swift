//
//  AppRunner.swift
//  SecondChance
//
//  Second Chance's side of a plan's run: what the runner is given, and
//  what it says turned into the build's events.

import Foundation
import GameCatalog
import SecondChanceKit
import SecondChanceReporting
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
        downloader: Downloader, helper: WrappBuildHelper, executors more: [String: any ModuleExecutor] = [:]
    ) -> (RunnerConfiguration, OrderedEmitter) {
        let translator = BuildEventTranslator(game: game)
        let emitter = OrderedEmitter { event in
            for translated in translator.translate(event) { await bus.publishWrappBuild(translated) }
        }
        let slug = game.id
        // Looked up once, here, as the service is the main actor's.
        let autoIt = AutoItService.shared.isAvailable ? AutoItService.shared.autoitDir : nil
        // The wine module's in-process helpers, as the template carries them.
        let helpers = Bundle.main.url(forResource: "WrappTemplate", withExtension: "app")?
            .appendingPathComponent("Contents/Frameworks/in_process_helpers.dylib")
        let executors = ModuleSteps.executors(helpers: helpers).merging(more) { $1 }
        var configuration = RunnerConfiguration(
            executors: executors, inputs: inputs, emitter: emitter,
            ask: { question in try await answer(question, input: input, game: slug) },
            fetch: { url, sha256, progress in
                if let shipped = DownloadCache.shipped(sha256: sha256) { return shipped }
                return try await downloader.fetch(DownloadRequest(urls: [url], sha256: sha256), progress: progress).file
            },
            providedFile: { fullForm in fullForm == "module:installer:/autoit" ? autoIt : nil },
            engine: { module, version in try await helper.engine(module, version: version) },
            moduleFolders: ModuleSteps.moduleFolders())
        // Layers (docs/wrapp-build.md#the-layer-cache): the store builds
        // share, with the policy `SECOND_CHANCE_LAYER_CACHE` sets, a module's
        // suggestion where its `build:` says an instruction is expensive.
        let declarations = ModuleSteps.moduleDeclarations()
        configuration.layers = WineManager.shared.layers
        configuration.layerPolicy = LayerCachePolicy.current().runnerPolicy
        configuration.layerEveryStep = ProcessInfo.processInfo.environment["SECOND_CHANCE_LAYER_EVERY_STEP"] == "1"
        configuration.suggestsLayer = { step in step.module.flatMap { declarations[$0]?.instruction(step.instruction)?.layer } ?? false }
        configuration.readsData = { step in
            guard let module = step.module else { return [] }
            return (declarations[module]?.instruction(step.instruction)?.readsData ?? []).flatMap { table in
                ["\(table).yaml", "\(table).json"]
            }
        }
        let revisions = executors.mapValues { type(of: $0).revision }
        configuration.revision = { step in step.module.flatMap { revisions[$0] } ?? CoreInstructions.revision }
        return (configuration, emitter)
    }

    /// A step's question, asked as Second Chance asks it.
    static func answer(_ question: StepQuestion, input: WrappBuildInput, game: String) async throws -> StepAnswer {
        switch question {
        case .confirmStepFailure(let name, let message):
            let patch = GamePatchCatalog.shared.allPatches(forGame: game).first { $0.id == name }
                ?? GamePatch.unlisted(id: name, game: game)
            // Not carrying on is the person's choice, not the step's failure.
            guard await input.confirmPatchFailure(patch, error: StepFailure.failed(message)) else { throw WrappBuildError.userCancelled }
            return .yes
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
    /// The game being built, for a failed patch's report.
    let game: GameInfo?

    init(game: GameInfo? = nil) {
        self.game = game
    }

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
            // A step's `--progress`, until the Wrappfiles EMIT it instead.
            if let key = ref.step.option("progress"), let text = WineManager.progressText(key) { nextSubstep = text }
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
            // A patch's steps say so as the builders always have.
            return [.stepDone(name: ref.name)] + (Self.isPatch(ref) ? [.patchApplied(id: ref.name)] : [])
        case .stepSkipped(let ref, let message):
            guard Self.isPatch(ref) else { return [.stepSkipped(name: ref.name, message: message)] }
            if let game {
                _ = FailureReporter.sendWithoutAsking(FailureReport(
                    what: "Applying a game patch", kind: "step-failed", game: game.id, source: nil,
                    engine: game.composition.engineTag, tags: ["patch": ref.name]))
            }
            return [.stepSkipped(name: ref.name, message: message), .patchFailed(id: ref.name, message: message)]
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
        case .replayed(let inner):
            // A step restored from a layer moves the sidebar as one that ran.
            if case .stepStarted(let ref) = inner { return translate(.stepRestored(ref)) }
            return translate(inner)
        }
    }

    /// Whether `ref` is one of Her Interactive's patches: a step of the
    /// nancy-drew module's `patch` function, named after the patch.
    static func isPatch(_ ref: StepRef) -> Bool {
        ref.step.name != nil && ref.step.origin.hasPrefix("nancy-drew/functions/patch")
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
