//
//  RecordingEventSubscriber.swift
//  SecondChanceTests
//
//  A subscriber that captures installation events from the bus for test
//  assertions. Subscribes to a bus, filters for `.installation` events, and
//  records the structured values that tests assert on.
//
//  This is the test-side counterpart to the event publishing added in Phase 2.
//  Instead of scraping log text, tests assert on
//  the typed events — guaranteed ordered, exact, and lossless.

import Foundation
@testable import SecondChance

/// Records `WrappBuildEvent`s published to a bus. Thread-safe via a lock;
/// tests read the recorded values after the build completes.
final class RecordingEventSubscriber: @unchecked Sendable {
    // Raw event log (for sequence assertions)
    private(set) var events: [WrappBuildEvent] = []
    private let lock = NSLock()

    // Derived convenience values (the things tests most commonly assert on)
    private(set) var detectedGame: GameInfo?
    private(set) var detectedExePath: String?
    private(set) var routedEngine: GameInfo.GameEngine?
    private(set) var resolvedInstaller: (exePath: String, type: InstallerType)?
    private(set) var configuredWrapp: (exePath: String, installerDir: String)?
    private(set) var mountedISOs: [URL] = []
    private(set) var disksResolved: (disk1: URL, disk2: URL?)?
    private(set) var signedWrapp: URL?
    private(set) var completedWrapp: URL?
    private(set) var failedError: WrappBuildError?
    private(set) var progressStates: [WrappBuildState] = []

    private var subscriptionToken: EventBus<AppEvent>.Token?

    /// Subscribe to a bus. Captures all subsequent `.installation` events.
    func subscribe(to bus: EventBus<AppEvent>) async {
        let token = await bus.subscribe { [weak self] event in
            await self?.handle(event)
        }
        subscriptionToken = token
    }

    /// Unsubscribe from the bus. Call in test cleanup to avoid leaks.
    func unsubscribe(from bus: EventBus<AppEvent>) async {
        if let token = subscriptionToken {
            await bus.unsubscribe(token)
            subscriptionToken = nil
        }
    }

    // MARK: - Internal handling

    private func handle(_ appEvent: AppEvent) async {
        guard case .wrappBuild(let event) = appEvent else { return }
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
        switch event {
        case .progress(let state):
            progressStates.append(state)
        case .disksResolved(let disk1, let disk2):
            disksResolved = (disk1, disk2)
        case .gameDetected(let info):
            detectedGame = info
        case .isoMounted(let url):
            mountedISOs.append(url)
        case .engineRouted(let engine, _):
            routedEngine = engine
        case .installerResolved(let exePath, let type):
            resolvedInstaller = (exePath, type)
        case .gameExeDetected(let path, _):
            detectedExePath = path
        case .wrappConfigured(let exePath, let installerDir, _):
            configuredWrapp = (exePath, installerDir)
        case .signed(let url):
            signedWrapp = url
        case .completed(let url):
            completedWrapp = url
        case .failed(let error):
            failedError = error
        case .started:
            break
        }
    }

    /// Block until a .completed or .failed event is received, or the timeout elapses.
    func waitForCompletion(timeout: TimeInterval = 300) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let done = lock.withLock { completedWrapp != nil || failedError != nil }
            if done { return lock.withLock { completedWrapp != nil } }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}
