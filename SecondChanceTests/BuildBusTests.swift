//
//  BuildBusTests.swift
//  SecondChanceTests
//
//  Each build reports on the bus its view model was given, so builds running
//  side by side (the integration tests) don't hear each other's events.
//

import Foundation
import Testing
@testable import SecondChance

@MainActor
@Suite("A build's own bus")
struct BuildBusTests {

    @Test("A view model follows its own bus and no other")
    func viewModelsFollowTheirOwnBus() async throws {
        let firstBus = EventBus<AppEvent>()
        let secondBus = EventBus<AppEvent>()
        let first = WrappBuildViewModel(bus: firstBus)
        let second = WrappBuildViewModel(bus: secondBus)
        // The subscriptions are made in a task started by init.
        try await waitUntil {
            let firstReady = await firstBus.hasSubscribers
            let secondReady = await secondBus.hasSubscribers
            return firstReady && secondReady
        }

        await firstBus.publishWrappBuild(.failed(.internalError("boom")))

        guard case .error = first.currentState else {
            Issue.record("The first view model didn't take its own bus's failure: \(first.currentState)")
            return
        }
        #expect(second.currentState == .idle)
    }

    /// Everything a build publishes reaches whoever started it through the
    /// bus the builders were given. A build-path file publishing to
    /// `EventBus.app` itself would reach the app's window instead, and mix
    /// into every other build's events.
    @Test("Nothing on the build path publishes to the app's bus directly")
    func buildPathTakesItsBus() throws {
        // CLIBuilder starts the headless build, so it is where `.app` is chosen.
        let allowed: Set<String> = ["CLIBuilder.swift", "AutomationBridge.swift"]
        let root = TestPaths.repoRoot.appendingPathComponent("SecondChance")
        var offenders: [String] = []
        for directory in ["Builders", "Services", "ViewModels"] {
            let dir = root.appendingPathComponent(directory)
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "swift" && !allowed.contains(file.lastPathComponent) {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() where line.contains("EventBus.app") {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    offenders.append("\(directory)/\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "Publish to the bus the build was given, not EventBus.app: \(offenders.joined(separator: ", "))")
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while await !condition() {
            guard Date() < deadline else { throw CancellationError() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
