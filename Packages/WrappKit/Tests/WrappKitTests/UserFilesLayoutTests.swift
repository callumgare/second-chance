import Foundation
import Testing
import WrappModules
@testable import WrappFormat

/// How a wrapp lays out the folder it keeps the person's files in, as its
/// lock says, and where it reads its own settings (the save warning's skip
/// file among them) from.
struct UserFilesLayoutTests {
    static let id = "au.gare.callum.second-chance.program.freeware.iji"

    private func lock(volumes: [VolumeRule]?, savesVolume: String?) -> WrappLock {
        WrappLock(bundle: .init(id: "freeware/iji", version: 1), edition: "download", source: "download",
                  composition: Composition(launcher: .wine), modules: [], builtBy: "1.0.0",
                  volumes: volumes, savesVolume: savesVolume)
    }

    @Test("A wrapp whose stores are all files mounts keeps its settings in wrapp-settings, not loose")
    func filesMountsOnly() {
        // Iji: one store, mounted beside the program, so no module keeps saves in it.
        let iji = lock(volumes: [VolumeRule(name: "saves", patterns: nil)], savesVolume: nil)
        #expect(UserFilesLayout.arrangement(of: iji) == .defaultStore)
    }

    @Test("Each lock's arrangement", arguments: [
        (VolumeRule?.none, String?.none, UserFilesLayout.Arrangement.defaultStore),      // SkiFree: no stores
        (VolumeRule(name: "wine-documents", patterns: nil), "wine-documents", .savesStore("wine-documents")),
    ])
    func arrangements(volume: VolumeRule?, saves: String?, expected: UserFilesLayout.Arrangement) {
        #expect(UserFilesLayout.arrangement(of: lock(volumes: volume.map { [$0] }, savesVolume: saves)) == expected)
    }

    @Test("A wrapp built before locks keeps everything loose")
    func noLock() {
        #expect(UserFilesLayout.arrangement(of: nil) == .loose)
    }

    @Test("A skip file left loose moves into wrapp-settings, and one already there is kept")
    func moveLooseSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UserFilesLayout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = UserFilesLayout(appSupport: root, bundleID: Self.id)
        let loose = layout.folder.appendingPathComponent("dont-show-save-warning")
        let kept = layout.settings.appendingPathComponent("dont-show-save-warning")
        try FileManager.default.createDirectory(at: layout.folder, withIntermediateDirectories: true)
        try "true".write(to: loose, atomically: true, encoding: .utf8)

        #expect(try layout.moveLooseSettings() == ["dont-show-save-warning"])
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: loose.path))

        // Nothing loose: nothing to do. One loose beside one kept: both stay.
        #expect(try layout.moveLooseSettings().isEmpty)
        try "true".write(to: loose, atomically: true, encoding: .utf8)
        #expect(try layout.moveLooseSettings().isEmpty)
        #expect(FileManager.default.fileExists(atPath: loose.path))
    }
}
