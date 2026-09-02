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

    // Intermediate results — the things tests assert on and the UI/logs can show.
    case disksResolved(disk1: URL, disk2: URL?)
    case gameDetected(GameInfo)
    case isoMounted(URL)
    case engineRouted(engine: GameInfo.GameEngine, gameInfo: GameInfo)
    case installerResolved(exePath: String, type: InstallerType)
    case gameExeDetected(path: String, gameInfo: GameInfo)
    case wrappConfigured(exePath: String, installerDir: String, gameInfo: GameInfo)
    case signed(wrappPath: URL)
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
