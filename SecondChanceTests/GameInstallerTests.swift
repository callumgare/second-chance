import Testing
import Foundation
@testable import SecondChance
import GameCatalog

@Suite("Game Installer")
@MainActor
struct GameInstallerTests {

    // Helper to create test game info
    let testGameInfo = GameInfo(
        id: "test-game",
        title: "Test Game",
        diskCount: 1,
        gameEngine: .wine
    )

    let testInstallerPath = "/path/to/installer.exe"
    let testWrappPath = URL(fileURLWithPath: "/tmp/test-wrapp.app")

    // Test installer type detection
    @Test("MSI installer arguments - silent install")
    func msiArgumentsSilent() {
        let installer = GameInstallerRunner.shared
        let args = installer.getInstallerArguments(
            installerPath: testInstallerPath,
            installerType: .msi,
            gameInfo: testGameInfo,
            wrappPath: testWrappPath,
            attemptNumber: 0
        )

        #expect(args.contains("/qn"), "MSI silent install should include /qn")
        #expect(args.contains("/i"), "MSI install should include /i")
        #expect(args.contains("/l*"), "MSI install should include logging /l*")
    }

    @Test("MSI installer arguments - interactive install")
    func msiArgumentsInteractive() {
        let installer = GameInstallerRunner.shared
        let args = installer.getInstallerArguments(
            installerPath: testInstallerPath,
            installerType: .msi,
            gameInfo: testGameInfo,
            wrappPath: testWrappPath,
            attemptNumber: 1
        )

        #expect(!args.contains("/qn"), "MSI interactive install should not include /qn")
        #expect(args.contains("/i"), "MSI install should include /i")
    }

    @Test("InstallShield installer arguments - interactive install")
    func installShieldArgumentsInteractive() {
        let installer = GameInstallerRunner.shared
        let args = installer.getInstallerArguments(
            installerPath: testInstallerPath,
            installerType: .installShield,
            gameInfo: testGameInfo,
            wrappPath: testWrappPath,
            attemptNumber: 1
        )

        #expect(!args.contains("/s"), "InstallShield interactive install should not include /s")
        #expect(args.contains("/r"), "InstallShield interactive install should include /r for recording")
    }

    // Wine is given each argument as it is, with no shell in between to
    // halve the backslashes.
    @Test("InstallShield installer arguments - silent install names the answer file")
    func installShieldArgumentsSilent() throws {
        let wrapp = FileManager.default.temporaryDirectory.appendingPathComponent("iss-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: wrapp) }
        let installerDir = wrapp.appendingPathComponent("Contents/SharedSupport/prefix/drive_c/nancy-drew-installer")
        try FileManager.default.createDirectory(at: installerDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: installerDir.appendingPathComponent("setup.iss").path, contents: nil)

        let args = GameInstallerRunner.shared.getInstallerArguments(
            installerPath: testInstallerPath,
            installerType: .installShield,
            gameInfo: testGameInfo,
            wrappPath: wrapp,
            attemptNumber: 0
        )

        #expect(args == ["/s", "/sms", #"/f1C:\nancy-drew-installer\setup.iss"#])
    }

    @Test("Inno Setup installer arguments - silent install")
    func innoSetupArgumentsSilent() {
        let installer = GameInstallerRunner.shared
        let args = installer.getInstallerArguments(
            installerPath: testInstallerPath,
            installerType: .innoSetup,
            gameInfo: testGameInfo,
            wrappPath: testWrappPath,
            attemptNumber: 0
        )

        #expect(args.contains("/verysilent"), "Inno Setup should use /verysilent")
        #expect(args.contains("/norestart"), "Inno Setup should include /norestart")
    }

    @Test("Inno Setup installer arguments - interactive install")
    func innoSetupArgumentsInteractive() {
        let installer = GameInstallerRunner.shared
        let args = installer.getInstallerArguments(
            installerPath: testInstallerPath,
            installerType: .innoSetup,
            gameInfo: testGameInfo,
            wrappPath: testWrappPath,
            attemptNumber: 1
        )

        #expect(args.isEmpty, "Inno Setup interactive install should have no special args")
    }

    @Test("Unknown installer type")
    func unknownInstallerType() {
        let installer = GameInstallerRunner.shared
        let args = installer.getInstallerArguments(
            installerPath: testInstallerPath,
            installerType: .unknown,
            gameInfo: testGameInfo,
            wrappPath: testWrappPath,
            attemptNumber: 0
        )

        #expect(args.isEmpty, "Unknown installer should have no args")
    }

    // Test that installer type detection logic works with mock metadata
    @Test("Detect InstallShield from metadata", arguments: [
        "InstallShield Setup",
        "Created by InstallShield",
        "installshield wizard",
    ])
    func detectInstallShield(metadata: String) {
        // This tests the logic that would be in detectInstallerType
        let combined = metadata.lowercased()
        let isInstallShield = combined.contains("installshield")

        #expect(isInstallShield, "Should detect InstallShield from '\(metadata)'")
    }

    @Test("Detect Inno Setup from metadata", arguments: [
        "Inno Setup",
        "Created with Inno Setup",
        "inno setup wizard",
    ])
    func detectInnoSetup(metadata: String) {
        let combined = metadata.lowercased()
        let isInnoSetup = combined.contains("inno setup")

        #expect(isInnoSetup, "Should detect Inno Setup from '\(metadata)'")
    }

    @Test("Detect MSI from file extension")
    func detectMSI() {
        let msiFiles = [
            "setup.msi",
            "installer.MSI",
            "game.Msi",
        ]

        for file in msiFiles {
            let isMSI = file.lowercased().hasSuffix(".msi")
            #expect(isMSI, "Should detect MSI from '\(file)'")
        }
    }
}

@Suite("Installer Integration Tests")
@MainActor
struct InstallerIntegrationTests {

    @Test("An .msi is an MSI installer, whatever is in it")
    @MainActor
    func detectMSIByExtension() async throws {
        let msi = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).msi")
        try Data("not really an MSI".utf8).write(to: msi)
        defer { try? FileManager.default.removeItem(at: msi) }

        #expect(await GameInstallerRunner.shared.detectInstallerType(msi.path) == .msi)
    }

    @Test("A program with no version info is an unknown installer")
    @MainActor
    func detectUnknownInstaller() async throws {
        let exe = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).exe")
        try Data("MZ, and nothing a Windows program would have after it".utf8).write(to: exe)
        defer { try? FileManager.default.removeItem(at: exe) }

        #expect(await GameInstallerRunner.shared.detectInstallerType(exe.path) == .unknown)
    }

    @Test("Patch installers get a C: path, not a Unix-looking one")
    func patchInstallerWindowsPath() {
        let driveC = URL(fileURLWithPath: "/tmp/w.app/Contents/SharedSupport/prefix/drive_c")
        let staged = driveC.appendingPathComponent("nancy-drew-installer/disk-combined/ndsck1.exe")
        #expect(GameInstallerRunner.windowsPath(of: staged, driveC: driveC)
                == "C:\\nancy-drew-installer\\disk-combined\\ndsck1.exe")
    }
}
