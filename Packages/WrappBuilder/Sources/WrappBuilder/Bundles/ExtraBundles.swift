//
//  ExtraBundles.swift
//  WrappBuilder
//
//  Program bundles from beyond the shipped Bundles/, for trying one before
//  it ships (docs/program-bundles.md#extra-bundles).

import Foundation
import GameCatalog
import Logging
import WrappModules

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.ExtraBundles")

/// Program bundles from folders `SECOND_CHANCE_EXTRA_BUNDLES` names, which
/// `sc --bundle` sets: each a bundle's own folder (the one holding its
/// `manifest.yaml`), wherever it is, its id read from the manifest. They
/// are checked against the shipped `Bundles/manifest.schema.json`, and one
/// with the id of a shipped bundle is used in its place.
public nonisolated enum ExtraBundles {
    public static let environmentVariable = "SECOND_CHANCE_EXTRA_BUNDLES"

    /// The folders named, as absolute paths separated by `:`.
    public static func folders(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        guard let value = environment[environmentVariable] else { return [] }
        return value.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true).standardizedFileURL }
    }

    /// The id a bundle folder's manifest gives, unchecked.
    public static func id(of folder: URL) -> String? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("manifest.yaml"), encoding: .utf8),
              let document = try? YAML12.load(text) as? [String: Any] else { return nil }
        return document["id"] as? String
    }

    /// The folder of bundle `id`: an extra one's, else the shipped one's
    /// under `shippedRoot`.
    public static func folder(of id: String, shippedRoot: URL,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        folders(environment: environment).first { Self.id(of: $0) == id } ?? shippedRoot.appendingPathComponent(id)
    }

    /// The extra bundles that load, checked against `shippedRoot`'s schema
    /// and, unless nil, `modules`. One that doesn't is logged and left out,
    /// as an added module is, rather than stopping everything else.
    public static func load(shippedRoot: URL, modules: [ModuleFolder]?,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> [ProgramBundle] {
        let folders = folders(environment: environment)
        guard !folders.isEmpty else { return [] }
        let loader: ProgramBundleLoader
        do {
            loader = try ProgramBundleLoader(root: shippedRoot, modules: modules)
        } catch {
            logger.error("Couldn't check the extra bundles, so leaving them out: \(error)")
            return []
        }
        return folders.compactMap { folder in
            switch loader.load(folder, anyFolder: true) {
            case .success(let bundle):
                logger.notice("Using the extra bundle \(bundle.manifest.id) from \(folder.path)")
                return bundle
            case .failure(let problems):
                logger.error("Leaving out the extra bundle in \(folder.path): \(problems)")
                return nil
            }
        }
    }

    /// Adds the extra bundles' games to `GameInfoProvider`, as
    /// `sc generate` would have made them, so everything that asks the
    /// catalogue for a game finds them. Call once, at start-up.
    public static func addGames(shippedRoot: URL, modules: [ModuleFolder], places: PathPlaces,
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                to provider: GameInfoProvider = .shared) {
        let bundles = load(shippedRoot: shippedRoot, modules: modules, environment: environment)
        guard !bundles.isEmpty else { return }
        do {
            provider.add(try GameCatalogSource.games(from: bundles, modules: modules, places: places))
        } catch {
            logger.error("Couldn't add the extra bundles' games: \(error)")
        }
    }
}
