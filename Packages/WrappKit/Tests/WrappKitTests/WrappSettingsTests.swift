import Foundation
import GameCatalog
import Testing
import WrappFormat
import WrappModules

struct WrappSettingsTests {
    @Test("Settings with no engine (a program the core starts) leave the key out and read the core from the launch")
    func noEngine() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let layout = WrappLayout(app: app)
        let settings = WrappSettings(gameExePath: "", engine: nil, gameSlug: "tool", source: .download, installerDir: "",
                                     recordedLaunch: RecordedLaunch(program: "/MacOS/tool", format: RecordedLaunch.currentFormat))
        try settings.write(to: layout)
        let plist = try #require(NSDictionary(contentsOf: layout.settingsFile))
        #expect(plist["GameEngine"] == nil)
        let read = try WrappSettings(of: layout)
        #expect(read == settings)
        #expect(read.composition == Composition(launcher: nil))
    }

    @Test("Older settings, with an engine and no launch, read as they always did")
    func olderSettings() {
        let settings = WrappSettings(gameExePath: "/Game/Game.exe", engine: .wine, gameSlug: "x", source: .disk, installerDir: "")
        #expect(settings.launch.program == "wine:C:/Game/Game.exe")
        #expect(settings.composition == Composition(launcher: .wine))
    }

    @Test("A classic Mac's startup disk store is where its program saves")
    func basiliskDiskIsTheSaves() {
        let launch = RecordedLaunch(program: "basilisk:Ingenious CD:Ingenious",
                                    mounts: [.init(store: "app:basilisk-disk", target: "basilisk:disk/")])
        #expect(launch.savesVolume == "basilisk-disk")
    }
}
