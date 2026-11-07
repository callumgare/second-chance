import Foundation
import Testing
@testable import WineKit

/// Wine's desktop is one of the prefix's programs, as its cleanup tells them.
struct WineDesktopTests {
    @Test("The desktop starts in the prefix, where the cleanup after a kill finds it")
    func startsInPrefix() throws {
        let wrapp = FileManager.default.temporaryDirectory.appendingPathComponent("WineDesktop-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: wrapp) }
        let wine = Wine(wrapp: wrapp)
        try FileManager.default.createDirectory(at: wine.prefix, withIntermediateDirectories: true)

        let directory = try #require(WineDesktop.command(wine).directory)
        // As the kernel reports a working directory: symlinks resolved.
        #expect(wine.server.isInPrefix(WineServer.realPath(directory)))
        // Inheriting a wrapp's from the Finder, as it did, it went unseen.
        #expect(!wine.server.isInPrefix("/"))
    }
}
