//
//  AppEvent.swift
//  SecondChance
//
//  App-wide typed event taxonomy. One bus (`EventBus.app`) carries `AppEvent`s
//  for every subsystem. Each subsystem's events live in their own enum nested
//  under a single case, keeping subsystems decoupled while sharing one delivery
//  mechanism.
//
//  Add new subsystems (e.g. LibraryEvent, SettingsEvent) by adding a case to
//  AppEvent and a corresponding enum. Do not populate them speculatively —
//  define events when a consumer needs them.

import Foundation

/// Top-level event type for the entire Second Chance app.
enum AppEvent {
    /// Wrapp-build subsystem events. See `WrappBuildEvent`.
    case wrappBuild(WrappBuildEvent)

    /// App lifecycle events. See `LifecycleEvent`.
    case lifecycle(LifecycleEvent)

    // Future subsystems (stubs — populate when built):
    // case library(LibraryEvent)
    // case settings(SettingsEvent)
}

// MARK: - Wrapp build events

/// Events emitted while a wrapp is being built. These are the authoritative
/// record of what the build flow did — tests assert on them and the UI reflects
/// them. They are emitted at decision points where the value is already
/// computed; emitting is strictly additive to the existing flow.
enum WrappBuildEvent {
    // Lifecycle
    case started(source: WrappSource)
    case completed(wrappPath: URL)
    case failed(WrappBuildError)

    // Step progress — carries the existing `WrappBuildState` enum used by the UI.
    case progress(WrappBuildState)
    /// Something the person has to do for the build to go on (sign in to
    /// Steam, click through an installer), shown prominently and at once on
    /// the progress screen until the next `.instructions(nil)`. Progress
    /// substeps, by contrast, wait 5 s and are small.
    case instructions(String?)
    /// How far the current step has got, where the build can tell: a
    /// download's bytes. Shown under the step until the next step, or until
    /// `.stepProgress(nil)`. Publish it after the step's `.progress`, which
    /// clears it.
    case stepProgress(StepProgress?)

    // Intermediate results — the things tests assert on and the UI/logs can show.
    /// The temporary wrapp the build works in, as it starts making it: what
    /// the integration tests measure to learn how much disk a build takes.
    case wrappStarted(path: URL)
    case disksResolved(disk1: URL, disk2: URL?)
    case gameDetected(GameInfo)
    case isoMounted(URL)
    case engineRouted(engine: GameInfo.GameEngine, gameInfo: GameInfo)
    case installerResolved(exePath: String, type: InstallerType)
    case gameExeDetected(path: String, gameInfo: GameInfo)
    case wrappConfigured(exePath: String, installerDir: String, gameInfo: GameInfo)
    case signed(wrappPath: URL)
    /// The Nancy Drew games the signed-in Steam account owns, once a Steam
    /// build has checked. The integration tests use it to skip the games the
    /// account doesn't own without signing in to Steam for each.
    case steamGamesOwned([GameInfo])

    // Official game patches. A failed patch doesn't fail the build (headless
    // runs continue past it), so this is the only record of it beyond the log.
    case patchApplied(id: String)
    case patchFailed(id: String, message: String)
}

/// How far a step has got, measured rather than guessed.
nonisolated struct StepProgress: Equatable, Sendable {
    /// From 0 to 1; nil when there's a figure to show but no total to
    /// measure it against.
    var fraction: Double?
    /// The figures, for the person: "1.2 GB of 2.4 GB".
    var text: String
}

// MARK: - Lifecycle events

enum LifecycleEvent {
    case launched
    case terminating
}

// MARK: - Shared bus + wrapp-build convenience

extension EventBus where Event == AppEvent {
    /// The app-wide shared bus. Subscribe for UI updates, log rendering, and
    /// test recording. Construct your own `EventBus<AppEvent>()` for isolated
    /// tests.
    static let app = EventBus<AppEvent>()

    /// Publish a wrapp-build-scoped event without the `.wrappBuild(...)`
    /// wrapper at every call site.
    func publishWrappBuild(_ event: WrappBuildEvent) async {
        await publish(.wrappBuild(event))
    }

    /// Publish a lifecycle event.
    func publishLifecycle(_ event: LifecycleEvent) async {
        await publish(.lifecycle(event))
    }
}
