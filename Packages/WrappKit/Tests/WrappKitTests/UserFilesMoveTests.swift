import Foundation
import Testing
@testable import WrappFormat

/// Moving a wrapp's files from the folder an earlier bundle id kept them in,
/// in a folder of the test's own standing in for Application Support.
struct UserFilesMoveTests {
    static let oldID = "au.gare.callum.SecondChance.nancy-drew.ghost-dogs"
    static let newID = "au.gare.callum.second-chance.program.nancy-drew.ghost-dogs"

    struct Scene {
        let root: URL
        var old: URL { root.appendingPathComponent(UserFilesMoveTests.oldID) }
        var layout: UserFilesLayout { UserFilesLayout(appSupport: root, bundleID: UserFilesMoveTests.newID) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("UserFilesMove-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func write(_ relative: String, in folder: URL? = nil, _ text: String = "x") throws {
            let file = (folder ?? old).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }

        func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

        func move(volumes: [VolumeRule], link: String, running: Set<String> = []) -> UserFilesMove.Outcome {
            UserFilesMove(layout: layout, formerBundleIDs: [UserFilesMoveTests.oldID], volumes: volumes, linkVolume: link)
                .run(isRunning: { running.contains($0) }, now: Date(timeIntervalSince1970: 1_773_446_400))  // 2026-03-14
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("A folder whose files all belong to one volume is renamed whole, and left as a link to it")
    func wholeFolder() throws {
        let scene = try Scene()
        defer { scene.remove() }
        try scene.write("Nancy Drew/Wolf/SAVE1.SAV")
        try scene.write("dont-show-save-warning")
        let outcome = scene.move(volumes: [VolumeRule(name: "wine-documents", patterns: nil)], link: "wine-documents")

        let volume = scene.layout.volume("wine-documents")
        #expect(scene.read(volume.appendingPathComponent("Nancy Drew/Wolf/SAVE1.SAV")) == "x")
        #expect(FileManager.default.fileExists(atPath: scene.layout.settings.appendingPathComponent("dont-show-save-warning").path))
        #expect(!FileManager.default.fileExists(atPath: volume.appendingPathComponent("dont-show-save-warning").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: scene.old.path) == volume.path)
        // An old wrapp following the link still finds its saves.
        #expect(scene.read(scene.old.appendingPathComponent("Nancy Drew/Wolf/SAVE1.SAV")) == "x")
        #expect(outcome.log.contains { $0.contains("whole") })
    }

    @Test("A folder split between volumes moves file by file, and the link goes to the volume it was")
    func splitFolder() throws {
        let scene = try Scene()
        defer { scene.remove() }
        try scene.write("Ghost Dogs/game.Hi1Save")        // a Wine save, from before ScummVM
        try scene.write("ghostdogs.000")                   // a ScummVM save
        _ = scene.move(volumes: [VolumeRule(name: "scummvm-saves", patterns: nil),
                                 VolumeRule(name: "wine-documents", patterns: ["*/*.Hi*Save", "*/*.SAV"])],
                       link: "scummvm-saves")
        #expect(scene.read(scene.layout.volume("wine-documents").appendingPathComponent("Ghost Dogs/game.Hi1Save")) == "x")
        #expect(scene.read(scene.layout.volume("scummvm-saves").appendingPathComponent("ghostdogs.000")) == "x")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: scene.old.path) == scene.layout.volume("scummvm-saves").path)
    }

    @Test("Nothing is overwritten: a file whose name is taken is kept beside it, dated")
    func neverOverwrites() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let volume = scene.layout.volume("wine-documents")
        try scene.write("Nancy Drew/HICONTINUE.SAV", in: volume, "newer")
        try scene.write("Nancy Drew/HICONTINUE.SAV", "restored")
        let outcome = scene.move(volumes: [VolumeRule(name: "wine-documents", patterns: nil)], link: "wine-documents")
        #expect(scene.read(volume.appendingPathComponent("Nancy Drew/HICONTINUE.SAV")) == "newer")
        #expect(scene.read(volume.appendingPathComponent("Nancy Drew/HICONTINUE (from 2026-03-14).SAV")) == "restored")
        #expect(outcome.keptBeside == ["HICONTINUE (from 2026-03-14).SAV"])
        #expect(UserFilesMove.kind(of: scene.old) == .link)
    }

    @Test("Nothing moves while a game with the old or new id is running")
    func waitsForTheGame() throws {
        let scene = try Scene()
        defer { scene.remove() }
        try scene.write("Nancy Drew/SAVE1.SAV")
        for running in [Self.oldID, Self.newID] {
            let outcome = scene.move(volumes: [VolumeRule(name: "wine-documents", patterns: nil)], link: "wine-documents",
                                     running: [running])
            #expect(UserFilesMove.kind(of: scene.old) == .folder)
            #expect(outcome.log.contains { $0.contains("running") })
        }
    }

    @Test("A run cut short after the rename only makes the link")
    func finishesARunCutShort() throws {
        let scene = try Scene()
        defer { scene.remove() }
        // As a run leaves things when stopped between the rename and the link.
        try scene.write("Nancy Drew/SAVE1.SAV", in: scene.layout.volume("wine-documents"))
        try scene.write("moved-from-\(Self.oldID)", in: scene.layout.settings, "")
        _ = scene.move(volumes: [VolumeRule(name: "wine-documents", patterns: nil)], link: "wine-documents")
        #expect(scene.read(scene.old.appendingPathComponent("Nancy Drew/SAVE1.SAV")) == "x")
    }

    @Test("With nothing to move, nothing changes, and no link is made")
    func nothingToMove() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let outcome = scene.move(volumes: [VolumeRule(name: "wine-documents", patterns: nil)], link: "wine-documents")
        #expect(outcome.log.isEmpty)
        #expect(UserFilesMove.kind(of: scene.old) == .missing)
        // And a second run once moved finds the link and leaves it.
        try scene.write("Nancy Drew/SAVE1.SAV")
        _ = scene.move(volumes: [VolumeRule(name: "wine-documents", patterns: nil)], link: "wine-documents")
        #expect(scene.move(volumes: [VolumeRule(name: "wine-documents", patterns: nil)], link: "wine-documents").log.isEmpty)
    }

    @Test("Patterns match without regard to case, as the Mac's disks do")
    func patternsIgnoreCase() {
        #expect(UserFilesMove.matches("Ghost Dogs/GAME.hi1save", ["*/*.Hi*Save"]))
        #expect(!UserFilesMove.matches("ghostdogs.000", ["*/*.Hi*Save"]))
    }
}
