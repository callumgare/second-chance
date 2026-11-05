import Foundation
import Testing
@testable import WrappFormat

@Suite("A launch's files= mount")
struct FilesMountTests {
    /// A program's folder holding the program, a default settings file the
    /// build left and a file that isn't the store's, and an empty store.
    private func make() throws -> (FilesMount, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("files-mount-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("app/LaserTank")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: folder.appendingPathComponent("lasertank.exe"))
        try Data("default".utf8).write(to: folder.appendingPathComponent("LaserTank.ini"))
        let mount = FilesMount(folder: folder, store: root.appendingPathComponent("store"),
                               patterns: FilesMount.patterns("LaserTank.ini; *.hs;*.lpb"))
        return (mount, root)
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test("A launch's files= mounts are the app's folders, each with the app's store")
    func fromLaunch() {
        let launch = RecordedLaunch(program: "wine:C:/LaserTank/lasertank.exe", mounts: [
            RecordedLaunch.Mount(store: "app:wine-documents", target: "wine:A:"),
            RecordedLaunch.Mount(store: "app:saves", target: "wine:C:/LaserTank/", options: ["files": "LaserTank.ini;*.hs"]),
        ])
        let app = WrappLayout(app: URL(fileURLWithPath: "/Apps/LaserTank.app"))
        let userFiles = UserFilesLayout(appSupport: URL(fileURLWithPath: "/Support"), bundleID: "com.example.laser-tank")
        let mounts = FilesMount.mounts(of: launch, app: app, userFiles: userFiles)
        #expect(mounts == [FilesMount(folder: app.driveC.appendingPathComponent("LaserTank"),
                                      store: userFiles.store(owner: "app", name: "saves"), patterns: ["LaserTank.ini", "*.hs"])])
    }

    @Test("The build's file starts the store's, and is linked back; the program's own file stays")
    func firstLaunch() throws {
        let (mount, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        try mount.connect()
        let ini = mount.folder.appendingPathComponent("LaserTank.ini")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: ini.path) == mount.store.appendingPathComponent("LaserTank.ini").path)
        #expect(try text(ini) == "default")
        #expect(!FileManager.default.fileExists(atPath: mount.store.appendingPathComponent("lasertank.exe").path))
    }

    @Test("A file the program made is kept in the store when it ends, and linked next time in a rebuilt app")
    func newFileKept() throws {
        let (mount, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        try mount.connect()
        try Data("scores".utf8).write(to: mount.folder.appendingPathComponent("Level1.hs"))
        #expect(try mount.collect() == ["kept Level1.hs"])
        #expect(try text(mount.store.appendingPathComponent("Level1.hs")) == "scores")
        #expect(try mount.collect().isEmpty)

        // A rebuilt app: its default settings again, and no scores.
        try FileManager.default.removeItem(at: mount.folder)
        try FileManager.default.createDirectory(at: mount.folder, withIntermediateDirectories: true)
        try Data("default again".utf8).write(to: mount.folder.appendingPathComponent("LaserTank.ini"))
        try Data("changed".utf8).write(to: mount.store.appendingPathComponent("LaserTank.ini"))
        try mount.connect()
        #expect(try text(mount.folder.appendingPathComponent("LaserTank.ini")) == "changed")
        #expect(try text(mount.folder.appendingPathComponent("Level1.hs")) == "scores")
    }

    @Test("A file the program wrote afresh over its link is the store's newest")
    func rewrittenOverLink() throws {
        let (mount, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        try mount.connect()
        let ini = mount.folder.appendingPathComponent("LaserTank.ini")
        try FileManager.default.removeItem(at: ini)
        try Data("saved".utf8).write(to: ini)
        try mount.collect()
        #expect(try text(mount.store.appendingPathComponent("LaserTank.ini")) == "saved")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: ini.path) == mount.store.appendingPathComponent("LaserTank.ini").path)
    }

    @Test("A file the game wrote afresh before a crash, newer than the store's, isn't lost at the next launch")
    func crashBeforeCollect() throws {
        let (mount, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        try mount.connect()
        let ini = mount.folder.appendingPathComponent("LaserTank.ini")
        try FileManager.default.removeItem(at: ini)
        try Data("saved".utf8).write(to: ini)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: ini.path)
        // No collect: the wrapp ended. The next launch connects.
        try mount.connect()
        #expect(try text(mount.store.appendingPathComponent("LaserTank.ini")) == "saved")
        #expect(try text(ini) == "saved")
        #expect(mount.matches("LASERTANK.INI") && mount.matches("level1.HS"))
    }
}
