import Foundation
import GameCatalog
@testable import SecondChanceKit
import Testing

@Suite("Big Fish Game Manager")
struct BigFishGameManagerTests {
    /// White Wolf's bfgstate.xml as the Game Manager wrote it (paths as Wine sees them).
    static let whiteWolfState = """
    \u{FEFF}<?xml version="1.0" encoding="utf-8" ?><state>
    \t<installerVersion>1.3.0.8</installerVersion>
    \t<name>Nancy Drew: The White Wolf of Icicle Creek</name>
    \t<executablePath>C:\\Program Files (x86)\\Nancy Drew - The White Wolf of Icicle Creek\\wqxgxgg.exe</executablePath>
    \t<productID>F2435T1L1</productID>
    \t<trialLength>3600</trialLength>
    \t<trialLengthDays/>
    \t<state>5</state>
    </state>
    """

    @Test(arguments: [
        (5, BigFishGameStatus.Phase.ready),
        (0, .waiting), (3, .waiting), (10, .waiting),
        (7, .downloadFailed), (13, .downloadFailed),
        (9, .installFailed),
        (8, .activationFailed), (20, .activationFailed),
        (17, .failed), (21, .failed),
    ])
    func readsTheGameManagersStates(state: Int, phase: BigFishGameStatus.Phase) {
        #expect(BigFishGameStatus(state: state).phase == phase)
    }

    @Test func downloadAndInstallProgress() {
        #expect(BigFishGameStatus(state: 1, downloadProgress: 25, downloadSize: 100).phase == .downloading(0.25))
        #expect(BigFishGameStatus(state: 16, downloadProgress: 5, downloadSize: 0).phase == .downloading(nil))
        #expect(BigFishGameStatus(state: 4, installProgress: 50).phase == .installing(0.5))
        #expect(BigFishGameStatus(state: 6).phase == .installing(nil))
    }

    @Test func decodesWhatThePageReturnsForAStatus() throws {
        let json = #"{"state":1,"errorCode":0,"downloadProgress":1048576,"downloadSize":4194304,"installProgress":0}"#
        let status = try JSONDecoder().decode(BigFishGameStatus.self, from: Data(json.utf8))
        #expect(status.phase == .downloading(0.25))
    }

    @Test func readsBfgstate() throws {
        let folder = URL(fileURLWithPath: "/prefix/drive_c/Program Files (x86)/Nancy Drew - The White Wolf of Icicle Creek")
        let game = try #require(BigFishInstalledGame(folder: folder, stateXML: Self.whiteWolfState))
        #expect(game.sku == "F2435T1L1")
        #expect(game.launcher == "wqxgxgg.exe")
        #expect(game.launchFile.lastPathComponent == "LaunchGame.bfg")
    }

    @Test func refusesAStateWithoutItsGame() {
        let folder = URL(fileURLWithPath: "/x")
        #expect(BigFishInstalledGame(folder: folder, stateXML: "<state><productID>F1T1L1</productID></state>") == nil)
        #expect(BigFishInstalledGame(folder: folder, stateXML: "<state><executablePath>C:\\a.exe</executablePath></state>") == nil)
    }

    @Test func findsTheGamesFolderByItsSKU() throws {
        let programFiles = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: programFiles) }
        let wolf = programFiles.appendingPathComponent("Nancy Drew - The White Wolf of Icicle Creek")
        try FileManager.default.createDirectory(at: wolf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: programFiles.appendingPathComponent("bfgclient"), withIntermediateDirectories: true)
        try Self.whiteWolfState.write(to: wolf.appendingPathComponent("bfgstate.xml"), atomically: true, encoding: .utf8)

        let found = BigFishInstalledGame.find(sku: try #require(BigFishSKU("F2435T1L1")), in: programFiles)
        #expect(found?.folder.lastPathComponent == wolf.lastPathComponent)
        #expect(BigFishInstalledGame.find(sku: try #require(BigFishSKU("F7041T1L1")), in: programFiles) == nil)
    }

    @Test func picksTheGamesProgram() throws {
        let game = try #require(BigFishInstalledGame(folder: URL(fileURLWithPath: "/x"), stateXML: Self.whiteWolfState))
        let files = ["Game.exe", "wqxgxgg.exe", "Uninstall.exe", "Ndui.dll", "dxwebsetup.exe", "game.ini"]
        #expect(game.gameExecutable(among: files, knownNames: ["Game.exe"]) == "Game.exe")
        #expect(game.gameExecutable(among: files, knownNames: ["game.exe"]) == "Game.exe")
        // Not named in the catalog: the only program that isn't Big Fish's.
        #expect(game.gameExecutable(among: files, knownNames: ["Shadow.exe"]) == "Game.exe")
        // Two candidates and no known name: can't tell.
        #expect(game.gameExecutable(among: files + ["Setup.exe"], knownNames: []) == nil)
    }

    @Test func readsAnEvaluationsValue() throws {
        let reply: [String: Any] = ["id": 3, "result": ["result": ["type": "boolean", "value": true]]]
        #expect(try DevToolsPage.value(of: reply) == Data("true".utf8))
        let nothing: [String: Any] = ["id": 4, "result": ["result": ["type": "undefined"]]]
        #expect(try DevToolsPage.value(of: nothing) == Data("null".utf8))
    }

    @Test func reportsAScriptThatThrew() {
        let reply: [String: Any] = ["id": 5, "result": [
            "result": ["type": "object"],
            "exceptionDetails": ["text": "Uncaught", "exception": ["description": "TypeError: GM is not defined"]],
        ]]
        #expect(throws: DevToolsPage.DevToolsError.scriptFailed("TypeError: GM is not defined")) {
            try DevToolsPage.value(of: reply)
        }
    }

    @Test func quotesWhatGoesIntoAScript() {
        #expect(BigFishGameManager.Script.quoted("F2435T1L1") == #""F2435T1L1""#)
        #expect(BigFishGameManager.Script.quoted(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(BigFishGameManager.Script.download(sku: "F2435T1L1", fullVersion: false)
            .contains(#"{wrappingID: "F2435T1L1", downloadFullVersion: false}"#))
    }

    @Test func fillsTheSignInFormWithQuotedValues() {
        let script = BigFishGameManager.Script.fillSignIn(email: "a@example.com", password: #"p"w\d"#)
        #expect(script.contains(#"set('#o_login_email', "a@example.com")"#))
        #expect(script.contains(#"set('#o_login_password', "p\"w\\d")"#))
        #expect(script.contains("#o_login_submit a.btn_login"))
    }

    @Test func findsAFreePort() throws {
        let port = try #require(DevToolsPage.freePort())
        #expect((1024...65535).contains(port))
    }
}
