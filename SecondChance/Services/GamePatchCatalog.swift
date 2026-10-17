//
//  GamePatchCatalog.swift
//  SecondChance
//
//  Reads the bundled game-patch manifest and answers which official Her
//  Interactive patches apply to a given game and edition.
//

import Foundation
import Logging

/// One official Her Interactive patch, as described by `game-patches.json`.
///
/// The manifest is the single source of truth: `setup-game-patches.sh` reads it
/// to download and stage the archives at build time, and this type reads the
/// copy staged inside the bundle to decide what to apply. See
/// `docs/game-patches.md`.
struct GamePatch: Codable, Identifiable, Hashable {
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

    /// Which edition of the game a patch is built for. Her Interactive shipped
    /// separate CD and digital-download builds of some patches, and installing
    /// the wrong one does nothing useful.
    enum Edition: String, Codable {
        case any
        case cd
        case digitalDownload = "digital-download"

        /// Whether this edition covers a wrapp built from `source`.
        func matches(_ source: WrappSource) -> Bool {
            switch self {
            case .any:
                return true
            case .cd:
                return source == .disk
            case .digitalDownload:
                // Steam copies are digital builds, not pressed discs.
                return source == .herDownload || source == .steam
            }
        }
    }

    let id: String
    /// Game slug, matching `GameInfo.id`.
    let game: String
    let title: String
    let url: String
    /// Zip filename as staged under `game-patches/<game>/`.
    let archive: String
    /// The single file inside the archive. Named explicitly because the
    /// filenames follow no pattern worth guessing at.
    let payload: String
    let action: Action
    /// For `copyIntoGameDir` and `extractIntoGameDir`, a folder beneath the
    /// game directory to put the files in.
    let destinationSubdirectory: String?
    let edition: Edition
    /// Whether to apply this during a build without being asked.
    ///
    /// `false` marks patches Her Interactive tells players not to install
    /// casually — puzzle solvers, difficulty tweaks, and superseded updaters.
    let automatic: Bool
    let fixes: String
    let sourceUrl: String
    /// For `runInstaller`, the AutoIt script in `patch-automation/` (without
    /// `.au3`) that clicks through the installer's wizard, for patchers with
    /// no silent mode. Nil runs the installer with silent flags.
    let automation: String?
}

/// Loads `game-patches/manifest.json` from the app bundle.
final class GamePatchCatalog {
    static let shared = GamePatchCatalog()

    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.GamePatchCatalog")
    private let patches: [GamePatch]

    /// Loads from the app bundle. A missing or malformed manifest yields an
    /// empty catalog rather than throwing: a wrapp without patches is still a
    /// working wrapp, so this must never fail a build.
    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "manifest", withExtension: "json", subdirectory: "game-patches") else {
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

    /// The patches to apply automatically when building a wrapp for `gameSlug`
    /// from `source`, in manifest order.
    func automaticPatches(forGame gameSlug: String, source: WrappSource) -> [GamePatch] {
        allPatches(forGame: gameSlug).filter { $0.automatic && $0.edition.matches(source) }
    }

    /// Patches listed for a game but deliberately not applied automatically —
    /// puzzle solvers, difficulty tweaks, and edition mismatches.
    func optionalPatches(forGame gameSlug: String, source: WrappSource) -> [GamePatch] {
        allPatches(forGame: gameSlug).filter { !($0.automatic && $0.edition.matches(source)) }
    }

    /// Slugs of every game the manifest knows a patch for.
    var patchedGameSlugs: Set<String> { Set(patches.map(\.game)) }

    var isEmpty: Bool { patches.isEmpty }
}
