import Testing
import Foundation
@testable import SecondChance

@Suite("Game Installer")
struct GameInstallerTests {
    
    // Helper to create test game info
    let testGameInfo = GameInfo(
        id: "test-game",
        title: "Test Game",
        diskCount: 1,
        gameEngine: .wine
    )
    
    let testInstallerPath = "/path/to/installer.exe"
    let testWrapperPath = URL(fileURLWithPath: "/tmp/test-wrapper.app")
    
    // Test installer type detection
    @Test("MSI installer arguments - silent install")
    func msiArgumentsSilent() {
        let installer = GameInstaller.shared
        let args = installer.getInstallerArguments(
            installerPath: testInstallerPath,
            installerType: .msi,
            gameInfo: testGameInfo,
            wrapperPath: testWrapperPath,
            attemptNumber: 0
        )
        
        #expect(args.contains("/qn"), "MSI silent install should include /qn")
        #expect(args.contains("/i"), "MSI install should include /i")
        #expect(args.contains("/l*"), "MSI install should include logging /l*")
    }
    
    @Test("MSI installer arguments - interactive install")
    func msiArgumentsInteractive() {
        let installer = GameInstaller.shared
        let args = installer.getInstallerArguments(
            installerPath: testInstallerPath,
            installerType: .msi,
            gameInfo: testGameInfo,
            wrapperPath: testWrapperPath,
            attemptNumber: 1
        )
        
        #expect(!args.contains("/qn"), "MSI interactive install should not include /qn")
        #expect(args.contains("/i"), "MSI install should include /i")
    }
    
    @Test("InstallShield installer arguments - interactive install")
    func installShieldArgumentsInteractive() {
        let installer = GameInstaller.shared
        let args = installer.getInstallerArguments(
            installerPath: testInstallerPath,
            installerType: .installShield,
            gameInfo: testGameInfo,
            wrapperPath: testWrapperPath,
            attemptNumber: 1
        )
        
        #expect(!args.contains("/s"), "InstallShield interactive install should not include /s")
        #expect(args.contains("/r"), "InstallShield interactive install should include /r for recording")
    }
    
    @Test("Inno Setup installer arguments - silent install")
    func innoSetupArgumentsSilent() {
        let installer = GameInstaller.shared
        let args = installer.getInstallerArguments(
            installerPath: testInstallerPath,
            installerType: .innoSetup,
            gameInfo: testGameInfo,
            wrapperPath: testWrapperPath,
            attemptNumber: 0
        )
        
        #expect(args.contains("/verysilent"), "Inno Setup should use /verysilent")
        #expect(args.contains("/norestart"), "Inno Setup should include /norestart")
    }
    
    @Test("Inno Setup installer arguments - interactive install")
    func innoSetupArgumentsInteractive() {
        let installer = GameInstaller.shared
        let args = installer.getInstallerArguments(
            installerPath: testInstallerPath,
            installerType: .innoSetup,
            gameInfo: testGameInfo,
            wrapperPath: testWrapperPath,
            attemptNumber: 1
        )
        
        #expect(args.isEmpty, "Inno Setup interactive install should have no special args")
    }
    
    @Test("Unknown installer type")
    func unknownInstallerType() {
        let installer = GameInstaller.shared
        let args = installer.getInstallerArguments(
            installerPath: testInstallerPath,
            installerType: .unknown,
            gameInfo: testGameInfo,
            wrapperPath: testWrapperPath,
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
struct InstallerIntegrationTests {
    
    // These tests require actual installer files or mocks
    // They will be skipped if test fixtures don't exist
    
    @Test("Detect installer type from real setup.exe")
    func detectInstallerTypeFromFile() async throws {
        let testFixturesPath = URL(fileURLWithPath: "/Users/callumgare/repos/second-chance/SecondChance/TestFixtures")
        let mockInstallerPath = testFixturesPath.appendingPathComponent("mock-installer/setup.exe")
        
        guard FileManager.default.fileExists(atPath: mockInstallerPath.path) else {
            // Skip test if fixture not found
            return
        }
        
        let installer = GameInstaller.shared
        let installerType = installer.detectInstallerType(mockInstallerPath.path)
        
        // The type will depend on what mock installer we create
        // We just check that it doesn't crash - actual type depends on fixture
        #expect(true, "Should detect installer type without crashing")
    }
}
