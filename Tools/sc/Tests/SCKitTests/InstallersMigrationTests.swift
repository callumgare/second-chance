import Foundation
import Testing
@testable import SCKit
import WrappBuilder

@Suite("Moving installers to the store's layout")
struct InstallersMigrationTests {
    private static let manifests = InstallersStore.manifests(bundles: repoRoot.appendingPathComponent("Bundles"))

    /// A folder with `files` (paths in it, each holding its own path) and
    /// `links` (path: target).
    private func folder(_ files: [String], links: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sc-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for path in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: file)
        }
        for (path, target) in links {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(path).path, withDestinationPath: target)
        }
        return root
    }

    @Test("Each installer goes to its edition's input, links to an alternative are made again, the rest to extras")
    func plan() throws {
        let root = try folder([
            "old-clock/disk-1.iso", "old-clock/.DS_Store", ".DS_Store",
            "stay-tuned/disk-1-full.iso", "stay-tuned/disk-1-slim.iso",
            "scarlet-hand/her-download-Setup.exe", "scarlet-hand/06_SSH_Guide.pdf",
            "trail-of-the-twister/her-download-mac.dmg", "trail-of-the-twister/disk-2.iso",
            "royal-tower/her-download-mac.dmg",
            "unsorted/Dossier.zip", "install-game.sh",
        ], links: ["stay-tuned/disk-1.iso": "disk-1-slim.iso"])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InstallersStore(root: root)
        let plan = InstallersMigration.plan(store: store, checkout: nil, manifests: Self.manifests)
        let lines = plan.lines(store: store)
        #expect(lines.contains("move old-clock/disk-1.iso → nancy-drew/old-clock/cd/disc-1.iso"))
        #expect(lines.contains("move stay-tuned/disk-1-full.iso → nancy-drew/stay-tuned/cd/disc-1-full.iso"))
        #expect(lines.contains("move stay-tuned/disk-1-slim.iso → nancy-drew/stay-tuned/cd/disc-1-slim.iso"))
        #expect(lines.contains("link nancy-drew/stay-tuned/cd/disc-1.iso → disc-1-slim.iso"))
        #expect(lines.contains("move scarlet-hand/her-download-Setup.exe → nancy-drew/scarlet-hand/her-windows/installer.exe"))
        #expect(lines.contains("move scarlet-hand/06_SSH_Guide.pdf → nancy-drew/scarlet-hand/extras/06_SSH_Guide.pdf"))
        #expect(lines.contains("move trail-of-the-twister/her-download-mac.dmg → nancy-drew/trail-of-the-twister/her-mac/installer.dmg"))
        #expect(lines.contains("move trail-of-the-twister/disk-2.iso → nancy-drew/trail-of-the-twister/cd/disc-2.iso"))
        // Royal Tower has no Mac download edition.
        #expect(lines.contains("move royal-tower/her-download-mac.dmg → nancy-drew/royal-tower/extras/her-download-mac.dmg"))
        #expect(plan.notes.contains { $0.contains("royal-tower") && $0.contains("no Mac") })
        #expect(lines.contains("drop 2 .DS_Store files"))
        #expect(Set(plan.unplaced.map { store.display($0.item) }) == ["unsorted", "install-game.sh"])
    }

    @Test("Carried out, the store reads as its layout says, and a second run has nothing to do")
    func carryOut() throws {
        let root = try folder(["stay-tuned/disk-1-full.iso", "stay-tuned/disk-1-slim.iso", "stay-tuned/.DS_Store", "old-clock/disk-1.iso"],
                              links: ["stay-tuned/disk-1.iso": "disk-1-slim.iso"])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InstallersStore(root: root)
        let plan = InstallersMigration.plan(store: store, checkout: nil, manifests: Self.manifests)
        #expect(try plan.carryOut(store: store) { _ in }.isEmpty)

        let stayTuned = try #require(Self.manifests.first { $0.id == "nancy-drew/stay-tuned" })
        let disc = try #require(store.found(stayTuned, source: .disc).first?.files.first)
        #expect(disc.lastPathComponent == "disc-1.iso")
        #expect(try String(contentsOf: disc, encoding: .utf8) == "stay-tuned/disk-1-slim.iso")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: disc.path) == "disc-1-slim.iso")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("stay-tuned").path))
        #expect(!store.hasLegacyLayout(manifests: Self.manifests))
        #expect(InstallersMigration.plan(store: store, checkout: nil, manifests: Self.manifests).isEmpty)
    }

    @Test("A checkout's installers link to the store is removed, its folder elsewhere moved in, and nothing is planned twice")
    func checkout() throws {
        let store = InstallersStore(root: try folder(["old-clock/disk-1.iso"]))
        let checkout = try folder(["installers/ghost-dogs/disk-1.iso", "installers/old-clock/disk-1.iso"])
        let linked = try folder([])
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("installers"), withDestinationURL: store.root)
        defer { for dir in [store.root, checkout, linked] { try? FileManager.default.removeItem(at: dir) } }

        let viaLink = InstallersMigration.plan(store: store, checkout: linked, manifests: Self.manifests)
        #expect(viaLink.steps.filter { if case .move = $0 { true } else { false } }.count == 1)
        #expect(viaLink.steps.last == .unlink(linked.appendingPathComponent("installers")))

        let own = InstallersMigration.plan(store: store, checkout: checkout, manifests: Self.manifests)
        let lines = own.lines(store: store)
        #expect(lines.contains("move \(checkout.path)/installers/ghost-dogs/disk-1.iso → nancy-drew/ghost-dogs/cd/disc-1.iso"))
        // The store's own Old Clock disc takes the place first.
        #expect(own.unplaced.map(\.item.lastPathComponent) == ["disk-1.iso"])
        #expect(own.unplaced.first?.reason.contains("already taken") == true)
    }
}
