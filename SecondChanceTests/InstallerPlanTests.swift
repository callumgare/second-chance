import Testing
import Foundation
@testable import SecondChance
import GameCatalog

/// What runs for each attempt at an installer, and whether the person sees
/// its wizard: decided by `InstallerPlan` before anything starts.
@Suite("Installer plan")
struct InstallerPlanTests {
    private static let game = GameInfo(id: "test-game", title: "Test Game")
    private static let stubbornGame = GameInfo(id: "stubborn-game", title: "Stubborn Game", doesNotExitInNonInteractiveMode: true)

    private static func plan(_ type: InstallerType, attempt: Int = 0, answerFile: Bool = true,
                             game: GameInfo = game) -> InstallerPlan {
        InstallerPlan(installerPath: "C:\\nancy-drew-installer\\SETUP.EXE", type: type, attempt: attempt,
                      hasAnswerFile: answerFile, game: game)
    }

    @Test("AutoIt drives only a first InstallShield attempt, with an answer file, for a game that won't exit")
    func autoItDecision() {
        #expect(Self.plan(.installShield, game: Self.stubbornGame).usesAutoIt)
        #expect(!Self.plan(.installShield).usesAutoIt)
        #expect(!Self.plan(.installShield, attempt: 1, game: Self.stubbornGame).usesAutoIt)
        #expect(!Self.plan(.installShield, answerFile: false, game: Self.stubbornGame).usesAutoIt)
        #expect(!Self.plan(.innoSetup, game: Self.stubbornGame).usesAutoIt)
    }

    @Test("An AutoIt run is AutoIt's program, the script, the installer and the game's title")
    func autoItCommand() {
        let plan = Self.plan(.installShield, game: Self.stubbornGame)
        #expect(plan.program == "C:\\autoit\\AutoIt3.exe")
        #expect(plan.arguments == ["C:\\installshield-custom-dialog-automate.au3", plan.installerPath, "Stubborn Game"])
        #expect(!plan.usesStart)
        #expect(!plan.runsInteractively)
        #expect(plan.automatedDescription != nil)
    }

    @Test("The person sees the wizard on a retry, or with no way to install by itself")
    func interactive() {
        #expect(!Self.plan(.msi).runsInteractively)
        #expect(Self.plan(.msi, attempt: 1).runsInteractively)
        #expect(!Self.plan(.innoSetup).runsInteractively)
        #expect(Self.plan(.innoSetup, attempt: 1).runsInteractively)
        #expect(!Self.plan(.installShield).runsInteractively)
        #expect(Self.plan(.installShield, answerFile: false).runsInteractively)
        #expect(Self.plan(.unknown).runsInteractively)
    }

    @Test("An MSI runs through msiexec, without wine start; anything else through it")
    func program() {
        let msi = Self.plan(.msi)
        #expect(msi.program == "msiexec")
        #expect(!msi.usesStart)
        #expect(msi.automatedDescription == nil)
        let inno = Self.plan(.innoSetup)
        #expect(inno.program == inno.installerPath)
        #expect(inno.usesStart)
        #expect(inno.description.hasPrefix("wine start /wait "))
    }

    @Test("A silent InstallShield install reads the answer file from the installers folder")
    func answerFileArgument() {
        #expect(Self.plan(.installShield).installerArguments == ["/s", "/sms", "/f1C:\\nancy-drew-installer\\setup.iss"])
        #expect(Self.plan(.installShield, answerFile: false).installerArguments == ["/r"])
    }
}
