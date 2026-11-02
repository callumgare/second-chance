import Testing
import Foundation
@testable import SecondChance

/// What happens when a game patch fails: the build's input decides whether
/// to carry on without it. The GUI's alert isn't tested here; the answers a
/// headless run gives without one are.
@Suite("Patch failures")
@MainActor
struct PatchFailureTests {
    private static var manifest: URL {
        TestPaths.repoRoot.appendingPathComponent("WrappTemplate/game-patches.json")
    }

    private static func anyPatch() throws -> GamePatch {
        let catalog = GamePatchCatalog(manifestURL: manifest)
        return try #require(catalog.allPatches(forGame: "stay-tuned").first)
    }

    private struct Failed: Error {}

    @Test("PATCH_FAILURE_POLICY decides, and a headless run carries on", arguments: [
        (["PATCH_FAILURE_POLICY": "continue"], true),
        (["PATCH_FAILURE_POLICY": "cancel"], false),
        (["PATCH_FAILURE_POLICY": "CANCEL", "NON_INTERACTIVE": "true"], false),
        (["NON_INTERACTIVE": "true"], true),
        (["DISK_1_PATH": "/nonexistent"], true),
    ])
    @MainActor
    func policy(environment: [String: String], carriesOn: Bool) async throws {
        let input = WrappBuildInput(environment: environment, viewModel: nil)
        #expect(await input.confirmPatchFailure(try Self.anyPatch(), error: Failed()) == carriesOn)
    }

    @Test("Every patch in the manifest is pinned to a SHA-256")
    func everyPatchHasAHash() throws {
        struct Entry: Decodable { let id: String; let sha256: String? }
        struct Manifest: Decodable { let patches: [Entry] }
        let patches = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.manifest)).patches
        #expect(!patches.isEmpty)
        for patch in patches {
            let hash = patch.sha256 ?? ""
            #expect(hash.count == 64 && hash.allSatisfy(\.isHexDigit), "\(patch.id) has no valid sha256")
        }
    }
}
