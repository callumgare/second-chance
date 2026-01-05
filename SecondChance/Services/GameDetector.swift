//
//  GameDetector.swift
//  SecondChance
//
//  Detects which Nancy Drew game is being installed from various sources

import Foundation
import UniformTypeIdentifiers

/// Detects Nancy Drew games from various installation sources
class GameDetector {
    static let shared = GameDetector()
    
    private let exiftool = ExiftoolService.shared
    
    private init() {}
    
    /// Detect game from disk path
    func detectGame(fromDisk diskPath: URL) async throws -> String {
        print("🔍 GameDetector: Starting detection from disk path: \(diskPath.path)")
        
        var fingerprint = ""
        
        // Look for setup.exe or other installer files
        let contents = try FileManager.default.contentsOfDirectory(
            at: diskPath,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        
        print("🔍 GameDetector: Found \(contents.count) files/directories:")
        for file in contents {
            print("  - \(file.lastPathComponent)")
        }
        
        // Check for setup.exe and extract Product Name
        if let setupExe = contents.first(where: { $0.lastPathComponent.lowercased() == "setup.exe" }) {
            print("🔍 GameDetector: Found setup.exe, extracting metadata...")
            if let productName = try? getFileInfo(setupExe, property: "Product Name") {
                print("🔍 GameDetector: Product Name: \(productName)")
                fingerprint += " \(productName)"
            }
        }
        
        // Check for .msi files and extract Subject
        if let msiFile = contents.first(where: { $0.pathExtension.lowercased() == "msi" }) {
            print("🔍 GameDetector: Found .msi file, extracting metadata...")
            if let subject = try? getFileInfo(msiFile, property: "Subject") {
                print("🔍 GameDetector: Subject: \(subject)")
                fingerprint += " \(subject)"
            }
        }
        
        // Check for setup.ini
        if let setupIni = contents.first(where: { $0.lastPathComponent.lowercased() == "setup.ini" }) {
            print("🔍 GameDetector: Found setup.ini, parsing...")
            if let iniContent = try? String(contentsOf: setupIni, encoding: .utf8) {
                if let appName = getPropertyFromIni(iniContent, property: "AppName") {
                    print("🔍 GameDetector: AppName: \(appName)")
                    fingerprint += " \(appName)"
                }
                if let product = getPropertyFromIni(iniContent, property: "Product") {
                    print("🔍 GameDetector: Product: \(product)")
                    fingerprint += " \(product)"
                }
            }
        }
        
        // Check for autorun.inf
        if let autorunInf = contents.first(where: { $0.lastPathComponent.lowercased() == "autorun.inf" }) {
            print("🔍 GameDetector: Found autorun.inf, parsing...")
            if let autorunContent = try? String(contentsOf: autorunInf, encoding: .utf8) {
                if let label = getAutorunLabel(autorunContent) {
                    print("🔍 GameDetector: Autorun label: \(label)")
                    fingerprint += " \(label)"
                }
            }
        }
        
        // Add volume name to fingerprint
        let volumeName = diskPath.lastPathComponent
        fingerprint += " \(volumeName)"
        
        print("🔍 GameDetector: Complete fingerprint: '\(fingerprint)'")
        let result = getGameSlugFromFingerprint(fingerprint)
        
        if result == "unknown" {
            print("❌ GameDetector: DETECTION FAILED")
            print("   Volume name: '\(diskPath.lastPathComponent)'")
            print("   Fingerprint: '\(fingerprint)'")
            print("   Files checked: \(contents.map { $0.lastPathComponent }.joined(separator: ", "))")
            print("   No matching patterns found")
        } else {
            print("✅ GameDetector: Detected game: \(result)")
        }
        
        return result
    }
    
    /// Detect game from Her Interactive installer
    func detectGame(fromInstaller installerPath: URL) async throws -> String {
        print("🔍 GameDetector: Starting detection from installer: \(installerPath.lastPathComponent)")
        
        // Use filename as fingerprint, replacing underscores with spaces
        let filename = installerPath.deletingPathExtension().lastPathComponent
        let fingerprint = filename.replacingOccurrences(of: "_", with: " ")
        
        print("🔍 GameDetector: Installer fingerprint: '\(fingerprint)'")
        let result = getGameSlugFromFingerprint(fingerprint)
        
        if result == "unknown" {
            print("❌ GameDetector: DETECTION FAILED")
            print("   Installer path: \(installerPath.path)")
            print("   Filename: \(installerPath.lastPathComponent)")
            print("   Fingerprint: \(fingerprint)")
            print("   No matching patterns found")
        } else {
            print("✅ GameDetector: Detected game from installer: \(result)")
        }
        
        return result
    }
    
    /// Detect game from Steam installation
    func detectGame(fromSteamExe exePath: URL) async throws -> String {
        print("🔍 GameDetector: Starting detection from Steam exe: \(exePath.path)")
        
        // Use parent directory name as fingerprint
        let parentDir = exePath.deletingLastPathComponent().lastPathComponent
        let fingerprint = " \(parentDir) "
        
        print("🔍 GameDetector: Steam fingerprint: '\(fingerprint)'")
        let result = getGameSlugFromFingerprint(fingerprint)
        
        if result == "unknown" {
            print("❌ GameDetector: DETECTION FAILED")
            print("   Steam exe path: \(exePath.path)")
            print("   Parent directory: \(parentDir)")
            print("   Fingerprint: \(fingerprint)")
            print("   No matching patterns found")
        } else {
            print("✅ GameDetector: Detected game from Steam: \(result)")
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
