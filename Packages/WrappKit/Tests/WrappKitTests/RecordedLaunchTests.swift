import Foundation
import Testing
@testable import WrappFormat

struct RecordedLaunchTests {
    @Test("A launch recorded before stores reads its volumes as the app's own stores' mounts, its Wine drive first")
    func volumesBecomeMounts() throws {
        let json = #"""
        {"program": "wine:C:/Game/Game.exe", "arguments": [], "environment": {}, "options": {"wine.graphics": "direct-draw"},
         "volumes": [{"name": "wine-documents", "location": "wine:C:/users/crossover/Documents", "options": {"wine.drive": "A:"}},
                     {"name": "dosbox-saves", "location": "dosbox:C:/", "options": {"dosbox.overlay": ""}}]}
        """#
        let launch = try JSONDecoder().decode(RecordedLaunch.self, from: Data(json.utf8))
        #expect(launch.mounts == [
            RecordedLaunch.Mount(store: "app:wine-documents", target: "wine:A:"),
            RecordedLaunch.Mount(store: "app:wine-documents", target: "wine:C:/users/crossover/Documents"),
            RecordedLaunch.Mount(store: "app:dosbox-saves", target: "dosbox:C:/", options: ["dosbox.overlay": ""]),
        ])
        #expect(launch.savesVolume == "wine-documents")
        // And as it's recorded now, the same again.
        let again = try JSONDecoder().decode(RecordedLaunch.self, from: try JSONEncoder().encode(launch))
        #expect(again == launch)
    }
}

struct VolumesIntoStoresTests {
    @Test("volumes/ becomes stores/app/, and a link an earlier launch made into it still reaches the saves")
    func linksStillLead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("volumes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = UserFilesLayout(appSupport: root, bundleID: "au.gare.callum.second-chance.program.example.game")
        let saves = layout.folder.appendingPathComponent("volumes/wine-documents")
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        try Data("save".utf8).write(to: saves.appendingPathComponent("game.sav"))
        let former = root.appendingPathComponent("au.example.old-id")
        try FileManager.default.createSymbolicLink(at: former, withDestinationURL: saves)

        #expect(try layout.moveVolumesIntoStores())
        #expect(try String(contentsOf: layout.store(owner: "app", name: "wine-documents").appendingPathComponent("game.sav"), encoding: .utf8) == "save")
        #expect(try String(contentsOf: former.appendingPathComponent("game.sav"), encoding: .utf8) == "save")
        #expect(try !layout.moveVolumesIntoStores())
    }
    @Test("--wine.clear reads as paths from C:'s root, and anything not a file or folder on C: as nil")
    func clearedPaths() {
        #expect(RecordedLaunch.clearedPaths(nil) == [])
        #expect(RecordedLaunch.clearedPaths("C:/users/crossover/AppData/Local/Temp/wmLaunch.tmp")
                == ["/users/crossover/AppData/Local/Temp/wmLaunch.tmp"])
        #expect(RecordedLaunch.clearedPaths(#"c:\Temp\a.tmp; C:/Temp/b/"#) == ["/Temp/a.tmp", "/Temp/b"])
        #expect(RecordedLaunch.clearedPaths("D:/x") == nil)
        #expect(RecordedLaunch.clearedPaths("C:/") == nil)
        #expect(RecordedLaunch.clearedPaths("C:/Temp/../windows") == nil)
        #expect(RecordedLaunch.clearedPaths("") == nil)
    }
}
