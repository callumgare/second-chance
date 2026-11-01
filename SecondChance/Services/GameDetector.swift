//
//  GameDetector.swift
//  SecondChance
//
//  Detects which Nancy Drew game is being installed from various sources

import Foundation
import Logging
import UniformTypeIdentifiers
import SecondChanceKit
import GameCatalog

/// Detects Nancy Drew games from various installation sources
class GameDetector {
    static let shared = GameDetector()

    private nonisolated static let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.GameDetector")
    private nonisolated var logger: Logger { Self.logger }

    /// Detect game from disk path
    func detectGame(fromDisk diskPath: URL) async throws -> String {
        // Note: Progress should already be reported by caller before this method
        let stepLogger = logger
        stepLogger.notice("Analyzing: \(diskPath.lastPathComponent)")

        var fingerprint = ""

        let contents = try FileManager.default.contentsOfDirectory(
            at: diskPath,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        stepLogger.notice("Found \(contents.count) items in disk")

        if let setupExe = contents.first(where: { $0.lastPathComponent.lowercased() == "setup.exe" }) {
            if let productName = await versionStrings(of: setupExe)["ProductName"] {
                stepLogger.notice("Product Name: \(productName)")
                fingerprint += " \(productName)"
            }
        }

        if let msiFile = contents.first(where: { $0.pathExtension.lowercased() == "msi" }) {
            if let subject = await Blocking.run({ MSISummary(contentsOf: msiFile)?.subject }) {
                stepLogger.notice("MSI Subject: \(subject)")
                fingerprint += " \(subject)"
            }
        }

        if let setupIni = contents.first(where: { $0.lastPathComponent.lowercased() == "setup.ini" }) {
            if let iniContent = TextFile.text(of: setupIni) {
                if let appName = getPropertyFromIni(iniContent, property: "AppName") {
                    stepLogger.notice("AppName: \(appName)")
                    fingerprint += " \(appName)"
                }
                if let product = getPropertyFromIni(iniContent, property: "Product") {
                    stepLogger.notice("Product: \(product)")
                    fingerprint += " \(product)"
                }
            }
        }

        if let autorunInf = contents.first(where: { $0.lastPathComponent.lowercased() == "autorun.inf" }) {
            if let autorunContent = TextFile.text(of: autorunInf) {
                if let label = getAutorunLabel(autorunContent) {
                    stepLogger.notice("Autorun label: \(label)")
                    fingerprint += " \(label)"
                }
            }
        }

        fingerprint += " \(diskPath.lastPathComponent)"

        stepLogger.notice("Fingerprint: '\(fingerprint)'")
        let result = getGameSlugFromFingerprint(fingerprint)

        if result == "unknown" {
            stepLogger.critical("Detection failed for '\(diskPath.lastPathComponent)' fingerprint='\(fingerprint)'")
        } else {
            stepLogger.notice("Detected: \(result)")
        }

        return result
    }

    /// Detect the game from a Windows installer bought from Her Interactive.
    ///
    /// The filename alone isn't enough: a download can be renamed, and some
    /// carry only a code. InstallShield launchers report themselves as
    /// "InstallShield" in their version info, but they carry the game's
    /// `setup.ini` (`Product=…`) and its registry key in plain text, the same
    /// signals a disc gives `detectGame(fromDisk:)`.
    func detectGame(fromHerInstaller installerPath: URL) async throws -> String {
        logger.notice("Analyzing: \(installerPath.lastPathComponent)")

        var fingerprint = installerPath.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")

        if let productName = await versionStrings(of: installerPath)["ProductName"] {
            logger.notice("Product Name: \(productName)")
            fingerprint += " \(productName)"
        }

        do {
            // Reads the whole installer, hundreds of MB, so off the main thread.
            for signal in try await Blocking.run({ try Self.embeddedInstallerSignals(in: installerPath) }) {
                logger.notice("Embedded: \(signal)")
                fingerprint += " \(signal)"
            }
        } catch {
            logger.warning("Couldn't read \(installerPath.lastPathComponent) for embedded game names: \(error)")
        }

        return detect(fingerprint: fingerprint, from: installerPath.lastPathComponent)
    }

    /// Detect the game from a Her Interactive Mac download, by the names its
    /// Cider installer gives it.
    func detectGame(fromCiderPackage package: CiderPackage) -> String {
        logger.notice("Analyzing: \(package.volumeName)")
        let fingerprint = [package.volumeName, package.gameName, package.bundleIdentifier]
            .compactMap { $0 }
            .joined(separator: " ")
        return detect(fingerprint: fingerprint, from: package.volumeName)
    }

    private func detect(fingerprint: String, from source: String) -> String {
        logger.notice("Fingerprint: '\(fingerprint)'")
        let result = getGameSlugFromFingerprint(fingerprint)
        if result == "unknown" {
            logger.critical("Detection failed for '\(source)' fingerprint='\(fingerprint)'")
        } else {
            logger.notice("Detected: \(result)")
        }
        return result
    }

    /// The game names an installer carries as plain text: the values of
    /// `Product=` lines (from an embedded `setup.ini`) and the names under
    /// `SOFTWARE\Her Interactive\`. Read in chunks, since a download is
    /// hundreds of megabytes. The end of each chunk is carried into the next,
    /// so a match split between them is read whole the second time; one that
    /// runs off the end of a chunk is left for then.
    nonisolated static func embeddedInstallerSignals(in url: URL, limit: Int = 8) throws -> [String] {
        let markers = ["Product=", "SOFTWARE\\Her Interactive\\"].map { Data($0.utf8) }
        let longestValue = 128
        let overlap = (markers.map(\.count).max() ?? 0) + longestValue
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var signals: [String] = []
        var window = Data()
        while signals.count < limit, let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            window = window.suffix(overlap) + chunk
            for marker in markers {
                var searchStart = window.startIndex
                while let found = window.range(of: marker, in: searchStart..<window.endIndex) {
                    searchStart = found.upperBound
                    let rest = window[found.upperBound...].prefix(longestValue)
                    // The value ends at the first byte that isn't printable
                    // ASCII: a line ending in setup.ini, a NUL in the binary.
                    guard let valueEnd = rest.firstIndex(where: { $0 < 0x20 || $0 > 0x7E }) else { continue }
                    let value = String(decoding: window[found.upperBound..<valueEnd], as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    if value.count >= 4, !signals.contains(value) {
                        signals.append(value)
                    }
                }
            }
        }
        return Array(signals.prefix(limit))
    }

    // MARK: - Installer or Installed Game

    /// What a disc offers to install the game with, from its top level.
    enum InstallerLookup: Equatable {
        /// An installer by its usual name: an `.msi`, `setup.exe` or `install.exe`.
        case recognised(String)
        /// No installer by name, but programs that might be one, sorted.
        case unrecognised([String])
        /// No program at all.
        case none
    }

    /// The installer on a disc, looked for in the order
    /// `GameInstallerRunner` takes them: the first `.msi`, then `setup.exe`,
    /// then `install.exe`. Every Nancy Drew disc has one of these at its top
    /// level; a disc without could be one Second Chance doesn't know (a
    /// special edition, another language), so its other programs are given.
    nonisolated static func installerLookup(in folder: URL) throws -> InstallerLookup {
        let names = try topLevelFileNames(in: folder)
        if let msi = names.first(where: { $0.lowercased().hasSuffix(".msi") }) {
            return .recognised(msi)
        }
        for installer in ["setup.exe", "install.exe"] {
            if let name = names.first(where: { $0.lowercased() == installer }) {
                return .recognised(name)
            }
        }
        let programs = names.filter { $0.lowercased().hasSuffix(".exe") }
        return programs.isEmpty ? .none : .unrecognised(programs)
    }

    /// Whether `folder` is a game that's already installed rather than its
    /// installer: one of the games' own programs (`internalGameExePath`,
    /// `steamExePath`) is at its top level. No disc has one there, though
    /// many carry the game's files in folders — Phantom of Venice's even
    /// holds a whole installed copy. An installer beside it doesn't make it
    /// a disc: the InstallShield games (Haunted Carousel to Blue Moon) leave
    /// a `Setup.exe` and `Setup.ini` in the installed folder, a stub that
    /// fails with "The InstallShield Engine (iKernel.exe) could not be
    /// launched" when run.
    nonisolated static func isInstalledGame(at folder: URL, games: [GameInfo]) throws -> Bool {
        let programs = try topLevelFileNames(in: folder).filter { $0.lowercased().hasSuffix(".exe") }
        let gamePrograms = Set(games.flatMap { game in
            [game.internalGameExePath, game.steamExePath].compactMap { path in
                path?.split(separator: "/").last.map { $0.lowercased() }
            }
        })
        guard let match = programs.first(where: { gamePrograms.contains($0.lowercased()) }) else { return false }
        logger.notice("\(folder.lastPathComponent) is an installed game (\(match)), not an installer")
        return true
    }

    nonisolated private static func topLevelFileNames(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent).sorted()
    }

    // MARK: - Private Detection Methods

    /// A Windows program's version strings: empty when it has none, or isn't
    /// one. Mapped, so off the main thread.
    private func versionStrings(of file: URL) async -> [String: String] {
        await Blocking.run { WindowsExecutable(contentsOf: file)?.versionStrings ?? [:] }
    }

    /// Parse property from INI file
    private func getPropertyFromIni(_ content: String, property: String) -> String? {
        // Match pattern: property=value (with optional \r at end)
        let pattern = "^\(NSRegularExpression.escapedPattern(for: property))=([^\r\n]*)"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return nil
        }

        let nsString = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsString.length))

        if let match = matches.first, match.numberOfRanges > 1 {
            let range = match.range(at: 1)
            return nsString.substring(with: range).trimmingCharacters(in: .whitespaces)
        }

        return nil
    }

    /// Extract label from autorun.inf content
    private func getAutorunLabel(_ content: String) -> String? {
        // Match pattern: label=value (with optional \r at end)
        let pattern = "^label=([^\r\n]*)"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive]) else {
            return nil
        }

        let nsString = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsString.length))

        if let match = matches.first, match.numberOfRanges > 1 {
            let range = match.range(at: 1)
            return nsString.substring(with: range).trimmingCharacters(in: .whitespaces)
        }

        return nil
    }

    /// Match fingerprint to game slug using full game titles
    func getGameSlugFromFingerprint(_ fingerprint: String) -> String {
        Self.slug(forFingerprint: fingerprint, among: GameInfoProvider.shared.allGames())
    }

    /// The game a fingerprint names, from the catalogue: its title (without
    /// a leading "The", which discs leave off), or one of its aliases,
    /// anywhere in the fingerprint whatever the case; or one of its codes, as
    /// a whole word in capitals. Of several, the first in the catalogue's
    /// order, unless another's title contains its title: "Secrets Can Kill
    /// Remastered" is what a fingerprint naming both is. A game added to the
    /// catalogue is recognised by its title with nothing added here.
    nonisolated static func slug(forFingerprint fingerprint: String, among games: [GameInfo]) -> String {
        let padded = " \(fingerprint) "
        let lowercased = padded.lowercased()
        let matched = games.filter { game in
            guard game.id != GameInfo.unknownGame.id else { return false }
            let title = game.title.lowercased()
            let names = [title.hasPrefix("the ") ? String(title.dropFirst(4)) : title] + game.detectionAliases.map { $0.lowercased() }
            return names.contains { lowercased.contains($0) } || game.detectionCodes.contains { padded.contains(" \($0) ") }
        }
        let mostSpecific = matched.first { game in
            !matched.contains { $0.id != game.id && $0.title.lowercased().contains(game.title.lowercased()) }
        }
        return mostSpecific?.id ?? GameInfo.unknownGame.id
    }
}
