//
//  GameDetector.swift
//  SecondChance
//
//  Detects which Nancy Drew game is being installed from various sources

import Foundation
import Logging
import UniformTypeIdentifiers

/// Detects Nancy Drew games from various installation sources
class GameDetector {
    static let shared = GameDetector()

    private let exiftool: ExiftoolService
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.GameDetector")
    
    init(exiftool: ExiftoolService = .shared) {
        self.exiftool = exiftool
    }
    
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
            if let productName = try? getFileInfo(setupExe, property: "Product Name") {
                stepLogger.notice("Product Name: \(productName)")
                fingerprint += " \(productName)"
            }
        }
        
        if let msiFile = contents.first(where: { $0.pathExtension.lowercased() == "msi" }) {
            if let subject = try? getFileInfo(msiFile, property: "Subject") {
                stepLogger.notice("MSI Subject: \(subject)")
                fingerprint += " \(subject)"
            }
        }
        
        if let setupIni = contents.first(where: { $0.lastPathComponent.lowercased() == "setup.ini" }) {
            if let iniContent = try? String(contentsOf: setupIni, encoding: .utf8) {
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
            if let autorunContent = try? String(contentsOf: autorunInf, encoding: .utf8) {
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

        if let productName = try? getFileInfo(installerPath, property: "Product Name") {
            logger.notice("Product Name: \(productName)")
            fingerprint += " \(productName)"
        }

        do {
            for signal in try Self.embeddedInstallerSignals(in: installerPath) {
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
    
    /// Detect game from Steam installation
    func detectGame(fromSteamExe exePath: URL) async throws -> String {
        logger.notice("🔍 GameDetector: Starting detection from Steam exe: \(exePath.path)")
        
        // Use parent directory name as fingerprint
        let parentDir = exePath.deletingLastPathComponent().lastPathComponent
        let fingerprint = " \(parentDir) "
        
        logger.notice("🔍 GameDetector: Steam fingerprint: '\(fingerprint)'")
        let result = getGameSlugFromFingerprint(fingerprint)
        
        if result == "unknown" {
            logger.critical("❌ GameDetector: DETECTION FAILED")
            logger.critical("   Steam exe path: \(exePath.path)")
            logger.critical("   Parent directory: \(parentDir)")
            logger.critical("   Fingerprint: \(fingerprint)")
            logger.critical("   No matching patterns found")
        } else {
            logger.notice("✅ GameDetector: Detected game from Steam: \(result)")
        }
        
        return result
    }
    
    // MARK: - Private Detection Methods
    
    /// Extract metadata from a file using exiftool
    private func getFileInfo(_ filePath: URL, property: String) throws -> String? {
        return try exiftool.getFileProperty(filePath.path, property: property)
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
        // Add spaces around fingerprint for word boundary matching
        let fp = " \(fingerprint) "
        let lowercaseFp = fp.lowercased()
        
        // Check for remastered first, then original
        if lowercaseFp.contains("secrets can kill remastered") || lowercaseFp.contains("nancy drew sck") {
            return "secrets-can-kill-remastered"
        } else if lowercaseFp.contains("secrets can kill") {
            return "secrets-can-kill"
        } else if lowercaseFp.contains("stay tuned for danger") || fp.contains(" STFD ") {
            return "stay-tuned"
        } else if lowercaseFp.contains("message in a haunted mansion") {
            return "haunted-mansion"
        } else if lowercaseFp.contains("treasure in the royal tower") {
            return "royal-tower"
        } else if lowercaseFp.contains("the final scene") {
            return "final-scene"
        } else if lowercaseFp.contains("secret of the scarlet hand") {
            return "scarlet-hand"
        } else if lowercaseFp.contains("ghost dogs of moon lake") {
            return "ghost-dogs"
        } else if lowercaseFp.contains("the haunted carousel") {
            return "haunted-carousel"
        } else if lowercaseFp.contains("danger on deception island") {
            return "deception-island"
        } else if lowercaseFp.contains("secret of shadow ranch") {
            return "shadow-ranch"
        } else if lowercaseFp.contains("curse of blackmoor manor") {
            return "blackmoor-manor"
        } else if lowercaseFp.contains("secret of the old clock") {
            return "old-clock"
        } else if lowercaseFp.contains("last train to blue moon canyon") {
            return "blue-moon"
        } else if lowercaseFp.contains("danger by design") {
            return "danger-by-design"
        } else if lowercaseFp.contains("the creature of kapu cave") {
            return "kapu-cave"
        } else if lowercaseFp.contains("the white wolf of icicle creek") {
            return "white-wolf"
        } else if lowercaseFp.contains("legend of the crystal skull") {
            return "crystal-skull"
        } else if lowercaseFp.contains("the phantom of venice") {
            return "phantom-of-venice"
        } else if lowercaseFp.contains("the haunting of castle malloy") {
            return "castle-malloy"
        } else if lowercaseFp.contains("ransom of the seven ships") {
            return "seven-ships"
        } else if lowercaseFp.contains("warnings at waverly academy") {
            return "waverly-academy"
        } else if lowercaseFp.contains("trail of the twister") {
            return "trail-of-the-twister"
        } else if lowercaseFp.contains("shadow at the water's edge") || lowercaseFp.contains("shadow waters edge") {
            return "waters-edge"
        } else if lowercaseFp.contains("the captive curse") || fp.contains(" CAP ") {
            return "captive-curse"
        } else if lowercaseFp.contains("alibi in ashes") {
            return "alibi-in-ashes"
        } else if lowercaseFp.contains("tomb of the lost queen") {
            return "lost-queen"
        } else if lowercaseFp.contains("the deadly device") {
            return "deadly-device"
        } else if lowercaseFp.contains("ghost of thornton hall") || fp.contains(" GTH ") {
            return "thornton-hall"
        } else if lowercaseFp.contains("the silent spy") || fp.contains(" SPY ") {
            return "silent-spy"
        } else if lowercaseFp.contains("the shattered medallion") || fp.contains(" MED ") {
            return "shattered-medallion"
        } else if lowercaseFp.contains("labyrinth of lies") || fp.contains(" LIE ") {
            return "labyrinth-of-lies"
        } else if lowercaseFp.contains("sea of darkness") || fp.contains(" SEA ") {
            return "sea-of-darkness"
        }
        
        return "unknown"
    }
}
