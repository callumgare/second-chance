import Foundation
import Testing
@testable import SecondChance
import WrappBuilder

/// What an install's and a patch's steps do with what they say: the
/// expected program linked to the one an installer made, and patch steps
/// told by their shape.
@Suite("Install and patch steps")
@MainActor
struct InstallStepTests {
    private func driveC() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("install-steps-\(UUID().uuidString)/drive_c")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func make(_ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: file)
    }

    @Test("An install that went where the step expects needs no link")
    func asExpected() throws {
        let driveC = try driveC()
        defer { try? FileManager.default.removeItem(at: driveC.deletingLastPathComponent()) }
        let exe = driveC.appendingPathComponent("Nancy Drew/Game/Game.exe")
        try make(exe)
        #expect(try GameInstallerRunner().linkExpected("/Nancy Drew/Game/Game.exe", toFound: exe, driveC: driveC)
                == "/Nancy Drew/Game/Game.exe")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: exe.deletingLastPathComponent().path)) == nil)
    }

    @Test("A game installed elsewhere, under another name, is linked to where the step expects it")
    func elsewhere() throws {
        let driveC = try driveC()
        defer { try? FileManager.default.removeItem(at: driveC.deletingLastPathComponent()) }
        let found = driveC.appendingPathComponent("Program Files/Her Interactive/Game/Game2.exe")
        try make(found)
        let path = try GameInstallerRunner().linkExpected("/Nancy Drew/Game/Game.exe", toFound: found, driveC: driveC)
        #expect(path == "/Nancy Drew/Game/Game.exe")
        let folder = driveC.appendingPathComponent("Nancy Drew/Game")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder.path) == "../Program Files/Her Interactive/Game")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("Game.exe").path) == "Game2.exe")
        #expect(FileManager.default.fileExists(atPath: driveC.appendingPathComponent("Nancy Drew/Game/Game.exe").path))
    }

    @Test("A patch step is told by its shape")
    func patchSteps() {
        func step(_ module: String?, _ instruction: String, _ options: [String: [String]] = [:]) -> PlannedStep {
            PlannedStep(instruction: instruction, module: module, options: options, arguments: [], name: nil, origin: "test")
        }
        #expect(GameInstallerRunner.isPatchStep(step(nil, "ADD")))
        #expect(GameInstallerRunner.isPatchStep(step(nil, "RUN")))
        #expect(GameInstallerRunner.isPatchStep(step("installer", "RUN", ["patch": [""]])))
        #expect(!GameInstallerRunner.isPatchStep(step("installer", "RUN")))
        #expect(!GameInstallerRunner.isPatchStep(step(nil, "EDIT")))
    }

    @Test("A drive path in a program's arguments is written as Windows writes it")
    func windowsStyle() {
        #expect(GameInstallerRunner.windowsStyle("C:/patch.au3") == "C:\\patch.au3")
        #expect(GameInstallerRunner.windowsStyle("/ErrorStdOut") == "/ErrorStdOut")
    }
}
