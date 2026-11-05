import Foundation
import Testing
@testable import WrappBuilder

struct InstallersStoreTests {
    private static let manifests = InstallersStore.manifests(bundles: bundlesRoot)

    private func manifest(_ id: String) throws -> Manifest {
        try #require(Self.manifests.first { $0.id == id })
    }

    /// A store in a fresh temporary folder, with `files` (paths in it) made
    /// and `links` (path: target) linked.
    private func store(_ files: [String], links: [String: String] = [:]) throws -> InstallersStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("installers-\(UUID().uuidString)")
        for path in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }
        for (path, target) in links {
            let link = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }
        return InstallersStore(root: root)
    }

    @Test func theStoreIsTheMacsUnlessTheEnvironmentNamesAnother() {
        #expect(InstallersStore.current([:]).root.path == "/Users/Shared/second-chance/installers")
        #expect(InstallersStore.current(["SECOND_CHANCE_INSTALLERS": "/tmp/x"]).root.path == "/tmp/x")
    }

    @Test func anEditionIsFoundWhenEveryDiscIsThereInOrder() throws {
        let twister = try manifest("nancy-drew/trail-of-the-twister")
        let one = try store(["nancy-drew/trail-of-the-twister/cd/disc-1.iso"])
        #expect(one.found(twister).isEmpty)
        let both = try store(["nancy-drew/trail-of-the-twister/cd/disc-2.iso", "nancy-drew/trail-of-the-twister/cd/disc-1.iso",
                              "nancy-drew/trail-of-the-twister/extras/guide.pdf"])
        let found = both.found(twister)
        #expect(found.map(\.edition) == ["cd"])
        #expect(found.first?.files.map(\.lastPathComponent) == ["disc-1.iso", "disc-2.iso"])
    }

    @Test func aLinkToAnAlternativeIsTheInputAndTheAlternativesAreNot() throws {
        let stayTuned = try manifest("nancy-drew/stay-tuned")
        let linked = try store(["nancy-drew/stay-tuned/cd/disc-1-full.iso", "nancy-drew/stay-tuned/cd/disc-1-slim.iso"],
                               links: ["nancy-drew/stay-tuned/cd/disc-1.iso": "disc-1-slim.iso"])
        let found = try #require(linked.found(stayTuned).first)
        #expect(found.files.map(\.lastPathComponent) == ["disc-1.iso"])
        let unlinked = try store(["nancy-drew/stay-tuned/cd/disc-1-full.iso"])
        #expect(unlinked.found(stayTuned).isEmpty)
        let dangling = try store([], links: ["nancy-drew/stay-tuned/cd/disc-1.iso": "gone.iso"])
        #expect(dangling.found(stayTuned).isEmpty)
    }

    @Test func herDownloadsAreFoundByTheirEditionsWithTheirFormats() throws {
        let twister = try manifest("nancy-drew/trail-of-the-twister")
        let store = try store(["nancy-drew/trail-of-the-twister/her-mac/installer.dmg",
                               "nancy-drew/trail-of-the-twister/her-windows/installer.exe"])
        let found = store.found(twister, source: .herDownload)
        #expect(found.map(\.edition) == ["her-windows", "her-mac"])
        #expect(found.map(\.format) == ["windows", "mac"])
    }

    @Test func aListingNamesTheEditionsWhoseEveryInputIsInIt() {
        let found = InstallersStore.editions(inListing: [
            "./nancy-drew/trail-of-the-twister/cd/disc-1.iso", "nancy-drew/trail-of-the-twister/her-windows/installer.exe",
            "nancy-drew/old-clock/cd/disc-1.iso", "nancy-drew/old-clock/extras/guide.pdf",
            "nancy-drew/scarlet-hand/extras/installer.exe", "ghost-dogs/disk-1.iso", "unbundled/notes.txt",
        ], manifests: Self.manifests)
        #expect(found == ["nancy-drew/trail-of-the-twister/her-windows", "nancy-drew/old-clock/cd"])
    }

    @Test func aProgramsDiscsHerDownloadsAndDiscFolderComeFromItsManifest() throws {
        let twister = try manifest("nancy-drew/trail-of-the-twister")
        let disc = try #require(twister.editions.first { $0.source == .disc })
        let store = try store(["nancy-drew/trail-of-the-twister/\(disc.id)/disc-1.iso", "nancy-drew/trail-of-the-twister/\(disc.id)/disc-2.iso"])
        #expect(store.discFolder(of: twister) == store.folder(program: twister.id, edition: disc.id))
        let found = try #require(store.discs(of: twister))
        #expect(found.files.map(\.lastPathComponent) == ["disc-1.iso", "disc-2.iso"])
        #expect(store.herDownloads(of: twister).isEmpty)
    }
}

struct SharedFoldersTests {
    @Test func everySharedFolderIsUnderOneRoot() {
        for folder in [SharedFolders.pool, SharedFolders.installers, SharedFolders.engines, SharedFolders.leases] {
            #expect(folder.deletingLastPathComponent().path == SharedFolders.root.path)
        }
        #expect(InstallersStore.defaultRoot == SharedFolders.installers)
        #expect(EngineStore.sharedRoot == SharedFolders.engines)
    }

    @Test func theShellCommandMakesAndSharesTheRootAndTheFolderUnlessTheyreThere() {
        let command = SharedFolders.makeCommand(SharedFolders.installers)
        #expect(command.contains("[ -d '/Users/Shared/second-chance' ] || { mkdir -p '/Users/Shared/second-chance' && chmod +a "))
        #expect(command.contains("[ -d '/Users/Shared/second-chance/installers' ]"))
        #expect(command.contains("file_inherit,directory_inherit"))
    }
}
