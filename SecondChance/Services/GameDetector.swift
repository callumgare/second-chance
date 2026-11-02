//
//  GameDetector.swift
//  SecondChance
//
//  Detects which Nancy Drew game is being installed from various sources

import Foundation
import Logging
import UniformTypeIdentifiers
import SecondChanceKit
import SecondChanceReporting
import GameCatalog
import WrappBuilder

/// Detects which game a disc or download is, by the shipped bundles'
/// matchers (`DetectionIndex`, docs/program-bundles.md).
class GameDetector {
    static let shared = GameDetector()

    private nonisolated static let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.GameDetector")
    private nonisolated var logger: Logger { Self.logger }

    /// The matchers it was given, for tests; nil uses the shipped bundles'.
    private let suppliedIndex: DetectionIndex?

    /// The matchers of every bundle Second Chance ships, compiled once. The
    /// first use loads them, which checks every bundle (a fraction of a
    /// second), so it is reached off the main thread (`detect`).
    private nonisolated var index: DetectionIndex { suppliedIndex ?? Self.shippedIndex }

    /// What `index` comes from when nothing is given: the shipped bundles,
    /// loaded on first use (a fraction of a second), or, should they fail
    /// to load, which the unit tests rule out, the default matchers of
    /// GameCatalog's table, which is generated from them.
    nonisolated static let shippedIndex: DetectionIndex = {
        do {
            guard let root = Bundle.main.resourceURL?.appendingPathComponent("Bundles") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try DetectionIndex.load(bundlesAt: root)
        } catch {
            logger.error("Couldn't load the shipped bundles' matchers, so recognising games by GameCatalog's titles alone: \(error)")
            return catalogueIndex(GameInfoProvider.shared.allGames())
        }
    }()

    /// The default matchers of `games`: their titles, aliases and codes.
    nonisolated static func catalogueIndex(_ games: [GameInfo]) -> DetectionIndex {
        let games = games.filter { $0.id != GameInfo.unknownGame.id }
        let rules = games.flatMap { game -> [DetectionIndex.Rule] in
            let id = "nancy-drew/\(game.id)"
            let title = game.title.lowercased()
            let names = [title.hasPrefix("the ") ? String(title.dropFirst(4)) : title] + game.detectionAliases.map { $0.lowercased() }
            return names.map { DetectionIndex.Rule(bundleID: id, matcher: .text($0)) }
                + game.detectionCodes.map { DetectionIndex.Rule(bundleID: id, matcher: .word($0)) }
        }
        return DetectionIndex(rules: rules, programs: games.map {
            .init(bundleID: "nancy-drew/\($0.id)", title: $0.title, series: "Nancy Drew")
        })
    }

    init(index: DetectionIndex? = nil) {
        suppliedIndex = index
    }

    /// Detect game from disk path
    func detectGame(fromDisk diskPath: URL) async throws -> String {
        // Note: Progress should already be reported by caller before this method
        let source = try await discSource(diskPath)
        return await detect(source, from: diskPath.lastPathComponent, sourceKind: .disk)
    }

    /// What a disc shows of itself: the names it gives itself, in the
    /// order today's fingerprint has always had them, its files and its
    /// volume's name.
    func discSource(_ diskPath: URL) async throws -> DetectionSource {
        let stepLogger = logger
        stepLogger.notice("Analyzing: \(diskPath.lastPathComponent)")

        var signals: [DetectionSource.Signal] = []

        let contents = try FileManager.default.contentsOfDirectory(
            at: diskPath,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        stepLogger.notice("Found \(contents.count) items in disk")

        if let setupExe = contents.first(where: { $0.lastPathComponent.lowercased() == "setup.exe" }) {
            if let productName = await versionStrings(of: setupExe)["ProductName"] {
                stepLogger.notice("Product Name: \(productName)")
                signals.append(.init(.exeVersion, productName))
            }
        }

        if let msiFile = contents.first(where: { $0.pathExtension.lowercased() == "msi" }) {
            if let subject = await Blocking.run({ MSISummary(contentsOf: msiFile)?.subject }) {
                stepLogger.notice("MSI Subject: \(subject)")
                signals.append(.init(.msi, subject))
            }
        }

        if let setupIni = contents.first(where: { $0.lastPathComponent.lowercased() == "setup.ini" }) {
            if let iniContent = TextFile.text(of: setupIni) {
                if let appName = getPropertyFromIni(iniContent, property: "AppName") {
                    stepLogger.notice("AppName: \(appName)")
                    signals.append(.init(.setupIni, appName))
                }
                if let product = getPropertyFromIni(iniContent, property: "Product") {
                    stepLogger.notice("Product: \(product)")
                    signals.append(.init(.setupIni, product))
                }
            }
        }

        if let autorunInf = contents.first(where: { $0.lastPathComponent.lowercased() == "autorun.inf" }) {
            if let autorunContent = TextFile.text(of: autorunInf) {
                if let label = getAutorunLabel(autorunContent) {
                    stepLogger.notice("Autorun label: \(label)")
                    signals.append(.init(.autorun, label))
                }
            }
        }

        signals.append(.init(.folderName, diskPath.lastPathComponent))

        let volume = try? diskPath.resourceValues(forKeys: [.isVolumeKey, .volumeNameKey])
        return DetectionSource(signals: signals, location: .folder(diskPath),
                               volumeName: volume?.isVolume == true ? volume?.volumeName : nil)
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

        var signals: [DetectionSource.Signal] = [
            .init(.fileName, installerPath.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")),
        ]

        if let productName = await versionStrings(of: installerPath)["ProductName"] {
            logger.notice("Product Name: \(productName)")
            signals.append(.init(.exeVersion, productName))
        }

        do {
            // Reads the whole installer, hundreds of MB, so off the main thread.
            for signal in try await Blocking.run({ try Self.embeddedInstallerSignals(in: installerPath) }) {
                logger.notice("Embedded: \(signal)")
                signals.append(.init(.embedded, signal))
            }
        } catch {
            logger.warning("Couldn't read \(installerPath.lastPathComponent) for embedded game names: \(error)")
        }

        let source = DetectionSource(signals: signals, location: .file(installerPath))
        return await detect(source, from: installerPath.lastPathComponent, sourceKind: .herDownload)
    }

    /// Detect the game from a Her Interactive Mac download, by the names its
    /// Cider installer gives it.
    func detectGame(fromCiderPackage package: CiderPackage) -> String {
        logger.notice("Analyzing: \(package.volumeName)")
        let source = DetectionSource(signals: [package.volumeName, package.gameName, package.bundleIdentifier]
            .compactMap { $0 }
            .map { .init(.cider, $0) })
        // No files to read, so quick enough to do here.
        return conclude(index.detect(source), source: source, from: package.volumeName, sourceKind: .herDownload)
    }

    /// The game `source` is, reading any files the matchers name off the
    /// main thread.
    private func detect(_ source: DetectionSource, from name: String, sourceKind: WrappSource) async -> String {
        let result = await Blocking.run { self.index.detect(source) }
        return conclude(result, source: source, from: name, sourceKind: sourceKind)
    }

    /// The game's slug, or `unknownGame`'s: for a tie too, which the person
    /// is asked about as they are about a game nothing recognised. A near
    /// miss or a tie is reported, as the reporting setting allows.
    private func conclude(_ result: DetectionIndex.Result, source: DetectionSource, from name: String,
                          sourceKind: WrappSource) -> String {
        logger.notice("Fingerprint: '\(source.fingerprint)'")
        switch result {
        case .recognised(let match):
            let slug = Self.slug(of: match.bundleID)
            logger.notice("Detected: \(slug) (\(match.rule.matcher.description))")
            return slug
        case .ambiguous(let tied):
            logger.critical("Detection failed for '\(name)': it matches \(tied.map { "\($0.bundleID) (\($0.rule.matcher.description))" }.joined(separator: " and ")) equally")
            Self.report(.ambiguous(tied), source: source, sourceKind: sourceKind)
            return GameInfo.unknownGame.id
        case .unrecognised(let nearMiss):
            logger.critical("Detection failed for '\(name)' fingerprint='\(source.fingerprint)'")
            if let nearMiss {
                logger.notice("Nearly \(nearMiss.bundleID ?? nearMiss.series ?? "?"), by \(nearMiss.reason.rawValue)")
                Self.report(result, source: source, sourceKind: sourceKind)
            }
            return GameInfo.unknownGame.id
        }
    }

    /// Today's slug for a bundle: the part of its id after the namespace.
    nonisolated static func slug(of bundleID: String) -> String {
        bundleID.split(separator: "/").last.map(String.init) ?? bundleID
    }

    /// Report a near miss or a tie, so editions not recognised yet show up
    /// (docs/failure-reports.md). A basic report says which bundle nearly
    /// matched, how, and the kinds of name the source had, never the names;
    /// for a hash, the file's name on the disc, its size and its md5. A
    /// detailed one has the names too, redacted.
    nonisolated static func report(_ result: DetectionIndex.Result, source: DetectionSource, sourceKind: WrappSource) {
        var tags = ["signals": source.signalKinds.map(\.rawValue).joined(separator: ",")]
        let kind: String
        switch result {
        case .recognised:
            return
        case .ambiguous(let tied):
            kind = "ambiguous"
            tags["tied"] = tied.map(\.bundleID).joined(separator: ",")
        case .unrecognised(let nearMiss):
            guard let nearMiss else { return }
            kind = "near-miss"
            tags["near_miss"] = nearMiss.reason.rawValue
            if let bundle = nearMiss.bundleID { tags["near_bundle"] = bundle }
            if let series = nearMiss.series { tags["near_series"] = series }
            if let file = nearMiss.file {
                tags["file"] = file.name
                tags["file_size"] = String(file.size)
                tags["file_md5"] = file.md5
            }
        }
        let summary = source.signals.map { "\($0.kind.rawValue): \($0.text)" }.joined(separator: "\n")
        _ = FailureReporter.sendWithoutAsking(FailureReport(
            what: "Recognising the game", kind: kind, source: sourceKind.rawValue, tags: tags, summary: summary
        ))
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
    nonisolated enum InstallerLookup: Equatable, Sendable {
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

    /// The game a fingerprint alone names, by the shipped bundles' text
    /// and word matchers.
    func getGameSlugFromFingerprint(_ fingerprint: String) -> String {
        let source = DetectionSource(signals: [.init(.exeVersion, fingerprint)])
        if case .recognised(let match) = index.detect(source) {
            return Self.slug(of: match.bundleID)
        }
        return GameInfo.unknownGame.id
    }
}
