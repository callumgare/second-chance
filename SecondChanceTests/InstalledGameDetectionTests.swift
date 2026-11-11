import Testing
import Foundation
@testable import SecondChance
import GameCatalog
import WrappBuilder

/// Telling a disc from a program that's already installed, by the bundles'
/// `installed` signs, and finding the installer on a disc. The layouts are
/// the bundles' own (`tests.layouts`): the top levels of real discs, and of
/// programs as a download or a build installed them, a name ending in `/` a
/// folder.
@Suite("Installed game detection")
@MainActor
struct InstalledGameDetectionTests {
    /// Every shipped bundle's manifest, loaded once: checking them runs
    /// ajv, too slow to do for each case.
    nonisolated static let manifests: [Manifest] = {
        let root = TestPaths.repoRoot.appendingPathComponent("Bundles")
        guard let all = try? ProgramBundleLoader(root: root, modules: nil).loadAll().get() else { return [] }
        return all.map(\.manifest)
    }()

    static let detector = GameDetector(index: DetectionIndex(manifests: manifests))

    /// Each layout, named `<bundle> <layout>`.
    nonisolated static func layouts(where include: (Manifest.Layout) -> Bool) -> [String: (Manifest, Manifest.Layout)] {
        var layouts: [String: (Manifest, Manifest.Layout)] = [:]
        for manifest in manifests {
            for layout in manifest.tests?.layouts ?? [] where include(layout) {
                layouts["\(manifest.id) \(layout.name)"] = (manifest, layout)
            }
        }
        return layouts
    }

    nonisolated static let discs = layouts { $0.disc != nil }
    nonisolated static let installedCopies = layouts { $0.installed != nil }

    @Test("The bundles load, with discs and installed copies laid out")
    func bundlesLoad() {
        #expect(Self.manifests.count > 30)
        #expect(Self.discs.count >= 10)
        #expect(Self.installedCopies.count >= 3)
    }

    @Test("A disc isn't an installed game, even with the game's files on it", arguments: discs.keys.sorted())
    func discIsNotInstalledGame(name: String) async throws {
        let (_, layout) = try #require(Self.discs[name])
        let folder = try Self.makeFolder(layout.files)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await Self.detector.installedCopy(at: folder).isEmpty)
    }

    @Test("Every disc's installer is found by name", arguments: discs.keys.sorted())
    func discInstallerIsRecognised(name: String) throws {
        let (_, layout) = try #require(Self.discs[name])
        let installer = try #require(layout.installer, "\(name) says no installer")
        let folder = try Self.makeFolder(layout.files)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try GameDetector.installerLookup(in: folder) == .recognised(installer))
    }

    @Test("An installed game is told from its installer, by its own bundle's signs", arguments: installedCopies.keys.sorted())
    func installedGameIsDetected(name: String) async throws {
        let (manifest, layout) = try #require(Self.installedCopies[name])
        let folder = try Self.makeFolder(layout.files)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Another bundle's tying signs may match too (Game.exe).
        #expect(await Self.detector.installedCopy(at: folder).contains { $0.bundleID == manifest.id })
    }

    @Test("Programs beyond Nancy Drew are told by their own signs", arguments: [
        ("freeware/skifree", ["ski32.exe"]),
        ("tivola/bioscopia", ["Bioscopia.exe", "Bioscopia_Deinstall.exe", "Dirapi.dll", "Game/", "Xtras/"]),
    ])
    func otherProgramsInstalled(bundle: String, files: [String]) async throws {
        let folder = try Self.makeFolder(files)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await Self.detector.installedCopy(at: folder).map(\.bundleID) == [bundle])
    }

    @Test("A program a folder down isn't at the top")
    func programInAFolderIsNotInstalled() async throws {
        let folder = try Self.makeFolder(["Transfer/", "Transfer/Bioscopia.exe", "setup.exe"])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await Self.detector.installedCopy(at: folder).isEmpty)
    }

    @Test("A folder of programs that aren't the games' own isn't an installed game")
    func unknownProgramsAreNotInstalledGame() async throws {
        let folder = try Self.makeFolder(["b.exe", "a.exe", "readme.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await Self.detector.installedCopy(at: folder).isEmpty)
        #expect(try GameDetector.installerLookup(in: folder) == .unrecognised(["a.exe", "b.exe"]))
    }

    @Test("An empty folder has no installer and no installed game")
    func emptyFolder() async throws {
        let folder = try Self.makeFolder([])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try GameDetector.installerLookup(in: folder) == .none)
        #expect(await Self.detector.installedCopy(at: folder).isEmpty)
    }

    @Test("A headless run tries the disc's first program without asking")
    func headlessTriesFirstProgram() async throws {
        let input = WrappBuildInput(environment: ["DISK_1_PATH": "/nonexistent"], viewModel: nil)
        #expect(try await input.askAboutUnidentifiedInstaller(programs: ["a.exe", "b.exe"]) == .tryProgram("a.exe"))
    }

    /// A temporary folder holding empty files, and folders for names ending
    /// in `/`; a name with a `/` inside is in the folder it names.
    nonisolated static func makeFolder(_ contents: [String]) throws -> URL {
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
                let file = folder.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: file)
            }
        }
        return folder
    }
}
