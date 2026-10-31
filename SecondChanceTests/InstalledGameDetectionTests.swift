import Testing
import Foundation
@testable import SecondChance

/// Telling a disc from a game that's already installed, and finding the
/// installer on a disc. The disc layouts are the top levels of the real
/// discs (a name ending in `/` is a folder); the installed ones are a
/// download of Castle Malloy, and games as a build installs them.
@Suite("Installed game detection")
struct InstalledGameDetectionTests {
    static let discs: [(slug: String, contents: [String], installer: String)] = [
        ("alibi-in-ashes", ["Alibi.ico", "Setup-1a.bin", "Setup-1b.bin", "Setup.exe", "autorun.inf"], "Setup.exe"),
        ("blackmoor-manor", ["CDSound/", "CDVideo/", "CURAuto.exe", "DataFiles/", "Game/", "Nancy.cid", "Redist/",
                             "Setup.exe", "Setup.ini", "autorun.inf", "data1.cab", "data1.hdr", "data2.cab"], "Setup.exe"),
        ("castle-malloy", ["Hau1.cab", "Haunting of Castle Malloy.exe", "Haunting of Castle Malloy.msi", "Ndc.cab",
                           "PreReq.cab", "autorun.exe", "autorun.inf"], "Haunting of Castle Malloy.msi"),
        ("crystal-skull", ["CRYAutoDisk1.exe", "ISSetup.dll", "_setup.dll", "autorun.inf", "data1.cab", "setup.exe",
                           "setup.ini"], "setup.exe"),
        ("haunted-carousel", ["autorun.inf", "CARAuto.exe", "data1.cab", "Nancy.cid", "Setup.exe", "Setup.ini"], "Setup.exe"),
        ("labyrinth-of-lies", [".background/", "Files/", "Nancy Drew - Labyrinth of Lies Installer.app/", "Prereqs/",
                               "Setup.exe", "Setup.msi", "autorun.inf", "installer/"], "Setup.msi"),
        // A whole installed copy of the game sits beside its installer.
        ("phantom-of-venice", ["ISSetup.dll", "Nancy Drew Central/", "The Phantom of Venice/", "VENAutoDisk1.exe",
                               "autorun.inf", "ciftree/", "sound/", "video2/", "setup.exe", "setup.ini"], "setup.exe"),
        ("secrets-can-kill", ["CDSound/", "CDVideo/", "GAME.ICO", "Game/", "Nancy.cid", "SETUP.EXE", "SETUP.INI",
                              "_ISDEL.EXE", "data1.cab"], "SETUP.EXE"),
        ("secrets-can-kill-remastered", ["autorun.inf", "icon.ico", "setup.exe"], "setup.exe"),
        ("seven-ships", ["Ndc.cab", "PreReq.cab", "RAN1.cab", "Setup.exe", "Setup.msi", "autorun.exe", "autorun.inf"], "Setup.msi"),
    ]

    static let installedGames: [(name: String, contents: [String])] = [
        ("Castle Malloy download", ["CastleMalloy.INI", "CastleMalloy.exe", "CastleMalloy.gdf", "Ciftree/", "Ndtl.cif",
                                    "Ndui.dll", "Sound/", "Video/", "binkw32.dll", "lua5.1.dll"]),
        // InstallShield leaves a stub Setup.exe in the installed folder.
        ("Haunted Carousel installed", ["CDSound/", "CDVideo/", "Game.exe", "Nancy.cid", "Setup.exe", "Setup.ini",
                                        "ciftree.dat", "readme.txt"]),
        ("White Wolf installed", ["Ciftree/", "DirectX/", "Game.exe", "Game.ini", "Nancy.cid", "Ndui.dll", "Sound/",
                                  "Video/", "binkw32.dll", "d3dx9_30.dll"]),
    ]

    @Test("A disc isn't an installed game, even with the game's files on it", arguments: discs.map(\.slug))
    func discIsNotInstalledGame(slug: String) throws {
        let disc = try #require(Self.discs.first { $0.slug == slug })
        let folder = try Self.makeFolder(disc.contents)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try !GameDetector.isInstalledGame(at: folder, games: GameInfoProvider.shared.allGames()))
    }

    @Test("Every disc's installer is found by name", arguments: discs.map(\.slug))
    func discInstallerIsRecognised(slug: String) throws {
        let disc = try #require(Self.discs.first { $0.slug == slug })
        let folder = try Self.makeFolder(disc.contents)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try GameDetector.installerLookup(in: folder) == .recognised(disc.installer))
    }

    @Test("An installed game is told from its installer", arguments: installedGames.map(\.name))
    func installedGameIsDetected(name: String) throws {
        let game = try #require(Self.installedGames.first { $0.name == name })
        let folder = try Self.makeFolder(game.contents)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try GameDetector.isInstalledGame(at: folder, games: GameInfoProvider.shared.allGames()))
    }

    @Test("A folder of programs that aren't the games' own isn't an installed game")
    func unknownProgramsAreNotInstalledGame() throws {
        let folder = try Self.makeFolder(["b.exe", "a.exe", "readme.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try !GameDetector.isInstalledGame(at: folder, games: GameInfoProvider.shared.allGames()))
        #expect(try GameDetector.installerLookup(in: folder) == .unrecognised(["a.exe", "b.exe"]))
    }

    @Test("An empty folder has no installer and no installed game")
    func emptyFolder() throws {
        let folder = try Self.makeFolder([])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try GameDetector.installerLookup(in: folder) == .none)
        #expect(try !GameDetector.isInstalledGame(at: folder, games: GameInfoProvider.shared.allGames()))
    }

    @Test("A headless run tries the disc's first program without asking")
    @MainActor
    func headlessTriesFirstProgram() throws {
        let input = WrappBuildInput(environment: ["DISK_1_PATH": "/nonexistent"], viewModel: nil)
        #expect(try input.askAboutUnidentifiedInstaller(programs: ["a.exe", "b.exe"]) == .tryProgram("a.exe"))
    }

    /// A temporary folder holding empty files, and folders for names ending in `/`.
    static func makeFolder(_ contents: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("installed-game-detection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in contents {
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(
                    at: folder.appendingPathComponent(String(name.dropLast())),
                    withIntermediateDirectories: true
                )
            } else {
                try Data().write(to: folder.appendingPathComponent(name))
            }
        }
        return folder
    }
}
