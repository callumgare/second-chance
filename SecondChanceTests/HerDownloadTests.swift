import Testing
import Foundation
@testable import SecondChance

/// Her Interactive downloads: telling the game from the file, and taking the
/// game out of a Mac (Cider) download. docs/her-download.md has the formats.
@Suite("Her Interactive downloads")
struct HerDownloadTests {
    private let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("HerDownloadTests-\(UUID().uuidString)")

    private func makeBase() throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // MARK: - Windows installers

    /// A stand-in for an InstallShield launcher: binary noise around the
    /// embedded setup.ini and registry key a real one carries.
    private func fakeInstaller(named name: String, paddingBefore: Int = 1000) throws -> URL {
        try makeBase()
        var data = Data((0..<paddingBefore).map { UInt8(truncatingIfNeeded: $0 * 7) | 0x80 })
        data.append(Data("\0[Startup]\r\nProduct=Nancy Drew: Secret of the Scarlet Hand\r\nCompanyName=Her Interactive\r\n\0".utf8))
        data.append(Data((0..<500).map { _ in 0x00 }))
        data.append(Data("SOFTWARE\\Her Interactive\\Nancy Drew: Secret of the Scarlet Hand\0".utf8))
        let url = base.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test("Reads the game's name from the setup.ini and registry key embedded in an installer")
    func embeddedSignals() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let installer = try fakeInstaller(named: "Setup.exe")
        let signals = try GameDetector.embeddedInstallerSignals(in: installer)
        #expect(signals.contains("Nancy Drew: Secret of the Scarlet Hand"))
    }

    @Test("Finds a name that straddles the boundary between two reads")
    func embeddedSignalAcrossChunks() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        // Reads are 4 MB; put "Product=" a few bytes before the first ends.
        let installer = try fakeInstaller(named: "Setup.exe", paddingBefore: (4 << 20) - 12)
        let signals = try GameDetector.embeddedInstallerSignals(in: installer)
        #expect(signals.contains("Nancy Drew: Secret of the Scarlet Hand"))
    }

    @Test("Detects the game from a renamed installer by what is inside it")
    func detectsRenamedInstaller() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let installer = try fakeInstaller(named: "NancySSHDigital.exe")
        let slug = try await GameDetector.shared.detectGame(fromHerInstaller: installer)
        #expect(slug == "scarlet-hand")
    }

    // MARK: - Mac (Cider) downloads

    /// A mounted Cider image: its installer app's tgInstall.plist and a
    /// payload holding a Cider app with a game, Cider's own DLLs and a
    /// manifest of it all.
    private func fakeCiderVolume() throws -> URL {
        try makeBase()
        let fileManager = FileManager.default
        let volume = base.appendingPathComponent("Nancy Drew - Trail of the Twister")
        let installer = volume.appendingPathComponent("installer")
        let resources = volume.appendingPathComponent("Nancy Drew - Trail of the Twister Installer.app/Contents/Resources")
        try fileManager.createDirectory(at: installer, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try (["InstallGame": "Nancy Drew - Trail of the Twister",
              "ForbiddenGameID": "com.transgaming.nancydrewtrailofthetwister"] as NSDictionary)
            .write(to: resources.appendingPathComponent("tgInstall.plist"))

        let payloadRoot = base.appendingPathComponent("payload")
        let app = payloadRoot.appendingPathComponent("output.app/Contents")
        let cDrive = app.appendingPathComponent("Resources/transgaming/c_drive")
        let game = cDrive.appendingPathComponent("Program Files/Nancy Drew/Trail of the Twister")
        let system32 = cDrive.appendingPathComponent("windows/system32")
        try fileManager.createDirectory(at: game, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: system32, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: game.appendingPathComponent("Twister.exe"))
        try Data("[Nancy Data]".utf8).write(to: game.appendingPathComponent("Twister.INI"))
        try Data("MZ".utf8).write(to: system32.appendingPathComponent("ddraw.dll"))
        try Data("MZ".utf8).write(to: system32.appendingPathComponent("mfc80.dll"))
        try (["CedegaGameDir": "C:\\Program Files\\Nancy Drew\\Trail of the Twister",
              "CedegaGameName": "C:\\Program Files\\Nancy Drew\\Trail of the Twister\\Twister.exe"] as NSDictionary)
            .write(to: app.appendingPathComponent("Info.plist"))

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", installer.appendingPathComponent("INSTALLDATA.tgz").path, "-C", payloadRoot.path, "output.app"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)

        let list = Process()
        let listing = Pipe()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        list.arguments = ["-tzf", installer.appendingPathComponent("INSTALLDATA.tgz").path]
        list.standardOutput = listing
        try list.run()
        let manifest = listing.fileHandleForReading.readDataToEndOfFile()
        list.waitUntilExit()
        try manifest.write(to: installer.appendingPathComponent("INSTALLDATA.tgz.manifest"))
        return volume
    }

    @Test("Recognises a Cider installer and detects its game")
    func recognisesCider() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let package = try CiderPackage(volume: try fakeCiderVolume())
        #expect(package.gameName == "Nancy Drew - Trail of the Twister")
        #expect(GameDetector.shared.detectGame(fromCiderPackage: package) == "trail-of-the-twister")
    }

    @Test("A disk image that isn't a Cider installer is refused")
    func refusesOtherImages() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try makeBase()
        let volume = base.appendingPathComponent("Some Native Game")
        try FileManager.default.createDirectory(at: volume.appendingPathComponent("Some Native Game.app"), withIntermediateDirectories: true)
        #expect(throws: CiderPackage.NotCider.self) {
            try CiderPackage(volume: volume)
        }
    }

    @Test("Takes only the game out of a Cider app, into Program Files (x86)")
    func extractsGame() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let package = try CiderPackage(volume: try fakeCiderVolume())
        let driveC = base.appendingPathComponent("drive_c")
        let staging = base.appendingPathComponent("staging")
        let percents = Percents()
        // Wine has its own ddraw.dll, and no mfc80.dll.
        let wineDLLs = base.appendingPathComponent("wine-dlls")
        try FileManager.default.createDirectory(at: wineDLLs, withIntermediateDirectories: true)
        try Data().write(to: wineDLLs.appendingPathComponent("ddraw.dll"))

        let exe = try await package.extractGame(into: driveC, staging: staging, wineDLLs: wineDLLs) { await percents.add($0) }

        #expect(exe.path.hasSuffix("drive_c/Program Files (x86)/Nancy Drew/Trail of the Twister/Twister.exe"))
        #expect(FileManager.default.fileExists(atPath: exe.path))
        #expect(FileManager.default.fileExists(atPath: exe.deletingLastPathComponent().appendingPathComponent("Twister.INI").path))
        // Cider's runtimes Wine lacks go beside the game; its other DLLs
        // would override cnc-ddraw and Wine's builtins.
        let gameDir = exe.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: gameDir.appendingPathComponent("mfc80.dll").path))
        #expect(!FileManager.default.fileExists(atPath: gameDir.appendingPathComponent("ddraw.dll").path))
        #expect(!FileManager.default.fileExists(atPath: driveC.appendingPathComponent("windows").path))
    }

    @Test("Maps Cider's Windows paths into a wrapp's drive_c", arguments: [
        ("C:\\Program Files\\Nancy Drew\\Trail of the Twister", "Program Files (x86)/Nancy Drew/Trail of the Twister"),
        ("C:\\Program Files\\Nancy Drew\\Game\\Game.exe", "Program Files (x86)/Nancy Drew/Game/Game.exe"),
        ("C:\\Nancy Drew\\Game", "Nancy Drew/Game"),
    ])
    func mapsPaths(windowsPath: String, expected: String) {
        #expect(CiderPackage.wrappRelativePath(ofWindowsPath: windowsPath) == expected)
    }

    @Test("Counts the manifest entries that extraction keeps")
    func countsManifestEntries() {
        let manifest = """
        output.app/
        output.app/Contents/
        output.app/Contents/Info.plist
        output.app/Contents/Frameworks/tgUpdate.framework/Versions/A/Resources/Info.plist
        output.app/Contents/Resources/transgaming/c_drive/Program Files/
        output.app/Contents/Resources/transgaming/c_drive/Program Files/Nancy Drew/
        output.app/Contents/Resources/transgaming/c_drive/Program Files/Nancy Drew/Game/Game.exe
        output.app/Contents/Resources/transgaming/c_drive/windows/system32/ddraw.dll
        output.app/Contents/Resources/transgaming/c_drive/windows/system32/drivers/etc/hosts
        output.app/Contents/Resources/transgaming/c_drive/windows/regapi.exe
        """
        #expect(CiderPackage.entryCount(inManifest: manifest) == 4)
    }

    // MARK: - Input

    @Test("HER_INSTALLER_PATH takes a .exe or a .dmg", arguments: ["exe", "dmg"])
    @MainActor
    func acceptsDownloads(fileExtension: String) async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try makeBase()
        let download = base.appendingPathComponent("game.\(fileExtension)")
        try Data().write(to: download)
        let input = WrappBuildInput(environment: ["HER_INSTALLER_PATH": download.path], viewModel: nil)
        #expect(try await input.getHerInstallerPath() == download)
    }

    @Test("HER_INSTALLER_PATH refuses anything else")
    @MainActor
    func refusesOtherFiles() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try makeBase()
        let download = base.appendingPathComponent("game.zip")
        try Data().write(to: download)
        let input = WrappBuildInput(environment: ["HER_INSTALLER_PATH": download.path], viewModel: nil)
        await #expect(throws: WrappBuildError.self) {
            try await input.getHerInstallerPath()
        }
    }
}

private actor Percents {
    private(set) var all: [Int] = []
    func add(_ percent: Int) { all.append(percent) }
}
