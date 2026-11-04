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
        let emitter = OrderedEmitter { event in await publish(event, on: bus) }
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

    /// The runner's event as the build's, where Second Chance shows it.
    static func publish(_ event: BuildEvent, on bus: EventBus<AppEvent>) async {
        switch event {
        case .stepProgress(let progress):
            await bus.publishWrappBuild(.stepProgress(progress.map { StepProgress(fraction: $0.fraction, text: $0.text ?? "") }))
        case .instructions(let text):
            await bus.publishWrappBuild(.instructions(text))
        default:
            break
        }
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
