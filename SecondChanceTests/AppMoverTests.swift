import Testing
import Foundation
@testable import SecondChance

@Suite("Moving the app to Applications")
struct AppMoverTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("app-mover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stand-in app bundle, quarantined as a download is.
    private func makeDownloadedApp(at url: URL) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("Second Chance")
        try Data("binary".utf8).write(to: executable)
        for path in [url.path, executable.path] {
            let value = "0081;00000000;Safari;"
            #expect(setxattr(path, "com.apple.quarantine", value, value.utf8.count, 0, 0) == 0)
        }
    }

    private func isQuarantined(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    @Test("A renamed download goes in under the app's own name")
    func destinationName() {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        #expect(AppMover.destination(in: applications, bundleName: "Second Chance").path == "/Applications/Second Chance.app")
    }

    @Test("Moving replaces an older copy and takes the quarantine off everything")
    func moves() throws {
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let downloads = work.appendingPathComponent("Downloads", isDirectory: true)
        let applications = work.appendingPathComponent("Applications", isDirectory: true)
        let original = downloads.appendingPathComponent("Second Chance 2.app", isDirectory: true)
        try makeDownloadedApp(at: original)
        let older = applications.appendingPathComponent("Second Chance.app", isDirectory: true)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: older.appendingPathComponent("marker"))

        let moved = try AppMover.move(original, to: applications, bundleName: "Second Chance")

        #expect(moved.path == older.path)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("marker").path))
        let executable = moved.appendingPathComponent("Contents/MacOS/Second Chance").path
        #expect(FileManager.default.fileExists(atPath: executable))
        #expect(!isQuarantined(moved.path))
        #expect(!isQuarantined(executable))
    }

    @Test("An app already in place only loses its quarantine")
    func alreadyInPlace() throws {
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let applications = work.appendingPathComponent("Applications", isDirectory: true)
        let app = applications.appendingPathComponent("Second Chance.app", isDirectory: true)
        try makeDownloadedApp(at: app)

        let moved = try AppMover.move(app, to: applications, bundleName: "Second Chance")

        #expect(moved.path == app.path)
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/Second Chance").path))
        #expect(!isQuarantined(app.path))
    }

    @Test("This build isn't translocated")
    func notTranslocated() {
        #expect(!AppTranslocation.isTranslocated())
        #expect(AppTranslocation.isTranslocated(URL(fileURLWithPath: "/nonexistent")) == false)
    }
}
