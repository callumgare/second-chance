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
    /// Installation subsystem events. See `InstallationEvent`.
    case installation(InstallationEvent)

    /// App lifecycle events. See `LifecycleEvent`.
    case lifecycle(LifecycleEvent)

    /// A narrow escape hatch for genuinely unstructured output that still wants
    /// to ride the bus. Prefer a typed case in the relevant sub-enum. Do not use
    /// this as a dumping ground — if a value matters, give it its own case.
    case log(LogLevel, String)

    // Future subsystems (stubs — populate when built):
    // case library(LibraryEvent)
    // case settings(SettingsEvent)
}

// MARK: - Installation events

/// Events emitted during game wrapper creation / installation. These are the
/// authoritative record of what the install flow did — tests assert on them and
/// the UI reflects them. They are emitted at decision points where the value is
/// already computed; emitting is strictly additive to the existing flow.
enum InstallationEvent {
    // Lifecycle
    case started(source: InstallationType)
    case completed(wrapperPath: URL)
    case failed(InstallationError)

    // Step progress — carries the existing `InstallationState` enum used by the UI.
    case progress(InstallationState)

    // Intermediate results — the things tests assert on and the UI/logs can show.
    case disksResolved(disk1: URL, disk2: URL?)
    case gameDetected(GameInfo)
    case isoMounted(URL)
    case engineRouted(engine: GameInfo.GameEngine, gameInfo: GameInfo)
    case installerResolved(exePath: String, type: InstallerType)
    case gameExeDetected(path: String, gameInfo: GameInfo)
    case wrapperConfigured(exePath: String, installerDir: String, gameInfo: GameInfo)
    case signed(wrapperPath: URL)
}

// MARK: - Lifecycle events

enum LifecycleEvent {
    case launched
    case terminating
}

// MARK: - Log level

enum LogLevel {
    case info
    case warning
    case error
}

// MARK: - Shared bus + installation convenience

extension EventBus where Event == AppEvent {
    /// The app-wide shared bus. Subscribe for UI updates, log rendering, and
    /// test recording. Construct your own `EventBus<AppEvent>()` for isolated
    /// tests.
    static let app = EventBus<AppEvent>()

    /// Publish an installation-scoped event without the `.installation(...)`
    /// wrapper at every call site.
    func publishInstallation(_ event: InstallationEvent) async {
        await publish(.installation(event))
    }

    /// Publish a lifecycle event.
    func publishLifecycle(_ event: LifecycleEvent) async {
        await publish(.lifecycle(event))
    }
}
