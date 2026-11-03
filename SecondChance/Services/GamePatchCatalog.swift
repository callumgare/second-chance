//
//  GamePatchCatalog.swift
//  SecondChance
//
//  Reads the bundled game-patch manifest: what each official Her
//  Interactive patch is. Which apply is a Wrappfile's DO nancy-drew.patch.
//

import Foundation
import Logging
import GameCatalog
import SecondChanceKit

/// One official Her Interactive patch, as described by the nancy-drew
/// module's `patches.json`.
///
/// The manifest is the single source of truth: `setup-game-patches.sh` reads it
/// to download and stage the archives at build time, and this type reads the
/// copy staged inside the bundle to decide what to apply. See
/// `docs/game-patches.md`.
nonisolated struct GamePatch: Codable, Identifiable, Hashable, Sendable {
    /// How the patch payload gets into the installed game.
    enum Action: String, Codable {
        /// A Windows installer to run under Wine.
        case runInstaller = "run-installer"
        /// A plain data file to drop into the game directory.
        case copyIntoGameDir = "copy-into-game-dir"
        /// A self-extracting zip, unzipped into the game directory (optionally
        /// under `destinationSubdirectory`) rather than run: its dialog only
        /// asks where to put the files.
        case extractIntoGameDir = "extract-into-game-dir"
    }

    let id: String
    /// Game slug, matching `GameInfo.id`.
    let game: String
    let title: String
    let url: String
    /// The archive's file name, as downloaded.
    let archive: String
    /// The archive's sha256: how it is found in the download cache.
    let sha256: String
    /// The single file inside the archive. Named explicitly because the
    /// filenames follow no pattern worth guessing at.
    let payload: String
    let action: Action
    /// For `copyIntoGameDir` and `extractIntoGameDir`, a folder beneath the
    /// game directory to put the files in.
    let destinationSubdirectory: String?
    let fixes: String
    let sourceUrl: String
    /// For `runInstaller`, the AutoIt script in the module's `assets/` (without
    /// `.au3`) that clicks through the installer's wizard, for patchers with
    /// no silent mode. Nil runs the installer with silent flags.
    let automation: String?
}

/// Loads the nancy-drew module's `patches.json` from the app bundle.
final class GamePatchCatalog {
    static let shared = GamePatchCatalog()

    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.GamePatchCatalog")
    private let patches: [GamePatch]

    /// Loads from the app bundle. A missing or malformed manifest yields an
    /// empty catalog rather than throwing: a wrapp without patches is still a
    /// working wrapp, so this must never fail a build.
    init(bundle: Bundle = .main) {
        guard let url = NancyDrewModule.patchesManifest(in: bundle), FileManager.default.fileExists(atPath: url.path) else {
            Logger(label: "au.gare.callum.second-chance.SecondChance.GamePatchCatalog")
                .notice("ℹ️  No game-patch manifest in bundle — patches are unavailable")
            self.patches = []
            return
        }
        self.patches = Self.decode(at: url)
    }

    /// Loads from an explicit manifest URL (tests).
    init(manifestURL: URL) {
        self.patches = Self.decode(at: manifestURL)
    }

    private static func decode(at url: URL) -> [GamePatch] {
        let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.GamePatchCatalog")
        struct Manifest: Codable { let patches: [GamePatch] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Manifest.self, from: data).patches
        } catch {
            logger.warning("⚠️  Could not read game-patch manifest at \(url.path): \(error)")
            return []
        }
    }

    /// Every patch listed for a game, in manifest order.
    ///
    /// Order matters: where a game has several updaters, the manifest lists
    /// them newest-first so an older one can never overwrite a newer one.
    func allPatches(forGame gameSlug: String) -> [GamePatch] {
        patches.filter { $0.game == gameSlug }
    }

    /// Slugs of every game the manifest knows a patch for.
    var patchedGameSlugs: Set<String> { Set(patches.map(\.game)) }

    var isEmpty: Bool { patches.isEmpty }
}
