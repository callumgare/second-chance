import Foundation
import Testing
@testable import SecondChance

/// The log excerpts are from real installs on a test Mac: one left to finish,
/// and one whose installer was killed partway (and still exited 0).
@Suite("Install completion")
struct InstallCompletionTests {

    @Test("An Inno Setup log finishes with its success line")
    func inno() {
        let finished = """
        2026-10-16 20:25:22.986   Filename: C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\Nancy Drew SCK\\Uninstall.lnk
        2026-10-16 20:25:22.993   Installation process succeeded.
        2026-10-16 20:25:22.993   Need to restart Windows? No
        2026-10-16 20:25:23.007   Log closed.
        """
        let killed = """
        2026-10-16 20:27:36.645   Dest filename: C:\\Program Files (x86)\\Nancy Drew SCK\\Video\\CWH51_CNV.bik
        2026-10-16 20:27:36.663   Successfully installed the file.
        """
        #expect(InstallCompletion.innoProblem(log: finished) == nil)
        let problem = InstallCompletion.innoProblem(log: killed)
        #expect(problem?.contains("Successfully installed the file.") == true)
        #expect(InstallCompletion.innoProblem(log: "")?.contains("empty") == true)
    }

    @Test("An MSI log finishes with the INSTALL action returning 1")
    func msi() {
        let wine = """
        Property(S): OutOfNoRbDiskSpace = 0
        Action ended 8:29:01: INSTALL. Return value 1.
        """
        let windows = "MSI (s) (1C:20) [12:01:02:003]: Windows Installer installed the product. Installation success or error status: 0."
        let killed = """
        Action ended 8:28:55: CostFinalize. Return value 1.
        1: {A5D73F1B-C475-4158-BD83-35A8B94F1018} 2: {AF77939C-15FE-5A65-B2DF-66CF53CD844C} 3: C:\\Sound\\NJB05_sfx.HIS
        """
        let failed = "Action ended 8:29:01: INSTALL. Return value 3."
        #expect(InstallCompletion.msiProblem(log: wine) == nil)
        #expect(InstallCompletion.msiProblem(log: windows) == nil)
        #expect(InstallCompletion.msiProblem(log: killed) != nil)
        #expect(InstallCompletion.msiProblem(log: failed) != nil)
    }

    @Test("An InstallShield install is finished once setup.ilg is in its folder or one above")
    func installShield() throws {
        let driveC = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallCompletionTests-\(UUID().uuidString)/drive_c")
        defer { try? FileManager.default.removeItem(at: driveC.deletingLastPathComponent()) }
        let installDir = driveC.appendingPathComponent("Program Files (x86)/Nancy Drew/Danger by Design")
        let exeDir = installDir.appendingPathComponent("Bin")
        try FileManager.default.createDirectory(at: exeDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: installDir.appendingPathComponent("Setup.exe").path, contents: Data())

        #expect(InstallCompletion.installShieldProblem(gameDir: installDir, driveC: driveC) != nil)

        FileManager.default.createFile(atPath: installDir.appendingPathComponent("setup.ilg").path, contents: Data())
        #expect(InstallCompletion.installShieldProblem(gameDir: installDir, driveC: driveC) == nil)
        #expect(InstallCompletion.installShieldProblem(gameDir: exeDir, driveC: driveC) == nil)
    }

    @Test("InstallShield 7 and later keep the uninstall log under Installation Information")
    func installShieldInstallationInformation() throws {
        let driveC = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallCompletionTests-\(UUID().uuidString)/drive_c")
        defer { try? FileManager.default.removeItem(at: driveC.deletingLastPathComponent()) }
        let gameDir = driveC.appendingPathComponent("Program Files (x86)/Nancy Drew/The White Wolf of Icicle Creek")
        let info = driveC.appendingPathComponent(
            "Program Files (x86)/InstallShield Installation Information/{60D8CA34-642C-476F-AB4E-94DECCAEED69}")
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: info.appendingPathComponent("setup.exe").path, contents: Data())

        #expect(InstallCompletion.installShieldProblem(gameDir: gameDir, driveC: driveC) != nil)
        FileManager.default.createFile(atPath: info.appendingPathComponent("setup.ilg").path, contents: Data())
        #expect(InstallCompletion.installShieldProblem(gameDir: gameDir, driveC: driveC) == nil)
    }

    @Test("InstallShield's uninstall log is recognised by name", arguments: [
        ("setup.ilg", true), ("SETUP.ILG", true), ("DeIsL1.isu", true), ("setup.log", false), ("setup.inx", false),
    ])
    func uninstallLogNames(name: String, isLog: Bool) {
        #expect(InstallCompletion.isInstallShieldUninstallLog(name) == isLog)
    }

    @Test("A setup.ilg on drive C itself is not the game's")
    func notAboveDriveC() throws {
        let driveC = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallCompletionTests-\(UUID().uuidString)/drive_c")
        defer { try? FileManager.default.removeItem(at: driveC.deletingLastPathComponent()) }
        let gameDir = driveC.appendingPathComponent("Nancy Drew/Game")
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: driveC.appendingPathComponent("setup.ilg").path, contents: Data())
        #expect(InstallCompletion.installShieldProblem(gameDir: gameDir, driveC: driveC) != nil)
    }
}
