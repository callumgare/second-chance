//
//  BuildLogContextTests.swift
//  SecondChanceTests
//
//  Entries logged for a wrapp build carry its id and its own stage, wherever
//  they were logged from, so builds running side by side can be told apart.
//

import Foundation
import Logging
import Testing
@testable import SecondChance

@Suite("A build's part of the log")
struct BuildLogContextTests {
    private let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.BuildLogContextTests")

    /// The entries logged for `build` so far.
    private func entries(of build: BuildLogContext) -> [Entry] {
        LogStore.shared.flush()
        return LogStore.shared.snapshot().entries.filter { $0.build == build.id }
    }

    @Test("Entries logged in a build carry its id and stage; others carry neither id")
    func entriesCarryTheirBuild() async {
        let build = BuildLogContext()
        let marker = UUID().uuidString
        await LogContext.$build.withValue(build) {
            LogContext.enterStage("Installing the game")
            logger.notice("inside \(marker)")
        }
        logger.notice("outside \(marker)")

        let tagged = entries(of: build).filter { $0.message.contains(marker) }
        #expect(tagged.map(\.message) == ["inside \(marker)"])
        #expect(tagged.first?.stage == "Installing the game")
        LogStore.shared.flush()
        let outside = LogStore.shared.snapshot().entries.first { $0.message == "outside \(marker)" }
        #expect(outside != nil && outside?.build == nil)
    }

    @Test("Two builds keep their own stage")
    func buildsKeepTheirOwnStage() {
        let first = BuildLogContext()
        let second = BuildLogContext()
        LogContext.$build.withValue(first) { LogContext.enterStage("Copying the disc") }
        LogContext.$build.withValue(second) { LogContext.enterStage("Saving the app") }
        #expect(LogContext.$build.withValue(first) { LogContext.stage.name } == "Copying the disc")
        #expect(LogContext.$build.withValue(second) { LogContext.stage.name } == "Saving the app")
    }

    @Test("Blocking.run carries the build to its detached task")
    func blockingRunCarriesTheBuild() async throws {
        let build = BuildLogContext()
        let marker = UUID().uuidString
        let logger = logger
        await LogContext.$build.withValue(build) {
            await Blocking.run { logger.notice("blocking \(marker)") }
        }
        #expect(entries(of: build).contains { $0.message == "blocking \(marker)" })
    }

    @Test("A program's output is logged for the build that started it")
    func pipeOutputCarriesTheBuild() async throws {
        let build = BuildLogContext()
        let marker = UUID().uuidString
        let pipe = Pipe()
        let finished = DispatchSemaphore(value: 0)
        LogContext.$build.withValue(build) {
            ProcessLineLogger.attach(to: pipe, logger: logger, level: .notice, onEOF: { finished.signal() })
        }
        pipe.fileHandleForWriting.write(Data("piped \(marker)\n".utf8))
        try pipe.fileHandleForWriting.close()
        _ = await Blocking.run { finished.wait(timeout: .now() + 5) }
        #expect(entries(of: build).contains { $0.message == "piped \(marker)" })
    }
}
