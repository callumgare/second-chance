//
//  NancyDrewExecutor.swift
//  NancyDrewExecutor
//
//  The nancy-drew module's executor: every Nancy Drew game's .ini settings.

import Foundation
import Logging
import WindowsFormats
import WrappFormat
import WrappModuleKit
import Yams

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.NancyDrewExecutor")

/// Carries out `NANCY-DREW.CONFIGURE-INI <folder>`: what every .ini file in
/// a Nancy Drew game's folder has changed once it's installed, as the
/// module's `ini.yaml` says (LCD mode, saves in Documents). Each file is
/// written back in the encoding it came in, as the game reads it. Portable:
/// it needs nothing of Second Chance's.
public nonisolated struct NancyDrewExecutor: ModuleExecutor {
    public static let handles = ["CONFIGURE-INI"]

    public init() {}

    /// The module's `ini.yaml`.
    struct Settings: Decodable {
        let replace: [Replacement]?
        let set: [Setting]?

        struct Replacement: Decodable {
            let from: String
            let to: String
            /// What says the file has it already, for the log.
            let already: String?
        }

        struct Setting: Decodable {
            let key: String
            let value: String
        }
    }

    public func run(_ step: PlannedStep, in context: any StepContext) async throws {
        guard step.instruction == "CONFIGURE-INI" else {
            throw StepFailure.recipe("\(step.origin): the nancy-drew module has no instruction \(step.instruction)")
        }
        guard let path = step.arguments.first, let folder = WrappLayout(app: context.tree).location(path) else {
            throw StepFailure.recipe("\(step.origin): NANCY-DREW.CONFIGURE-INI names the game's folder in the app")
        }
        guard let table = context.moduleFile("nancy-drew", "ini.yaml") else {
            throw StepFailure.recipe("\(step.origin): the nancy-drew module's ini.yaml isn't there")
        }
        let settings = try YAMLDecoder().decode(Settings.self, from: String(contentsOf: table, encoding: .utf8))
        try Self.configure(folder.resolvingSymlinksInPath(), with: settings)
    }

    /// Each .ini file in `folder` with `settings` made.
    static func configure(_ folder: URL, with settings: Settings) throws {
        let files = FileManager.default
        var isFolder: ObjCBool = false
        guard files.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            logger.warning("⚠️ The game's folder isn't at \(folder.path)")
            return
        }
        let ini = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "ini" }
        guard !ini.isEmpty else {
            // Normal for some installers: nothing to configure.
            logger.notice("No INI files to configure in the game's folder")
            return
        }
        for file in ini {
            logger.notice("  Processing: \(file.lastPathComponent)")
            guard let (original, encoding) = TextFile.read(file) else {
                logger.warning("    ⚠️ Failed to read it")
                continue
            }
            let content = try Self.configure(original, with: settings)
            guard content != original else {
                logger.notice("    ℹ️ No changes needed")
                continue
            }
            try content.write(to: file, atomically: true, encoding: encoding)
            logger.notice("    ✅ Saved changes to \(file.lastPathComponent)")
        }
    }

    /// `text`, an .ini file's, with `settings` made.
    static func configure(_ text: String, with settings: Settings) throws -> String {
        var content = text
        for replacement in settings.replace ?? [] {
            if content.contains(replacement.from) {
                content = content.replacingOccurrences(of: replacement.from, with: replacement.to)
                logger.notice("    ✅ Set \(replacement.to)")
            } else if let already = replacement.already, content.contains(already) {
                logger.notice("    ℹ️ \(already) already")
            } else {
                logger.notice("    ℹ️ No \(replacement.from) setting found")
            }
        }
        for setting in settings.set ?? [] {
            let line = "\(setting.key)=\(setting.value)"
            let pattern = try Regex("\(setting.key)=.*")
            if content.firstMatch(of: pattern) != nil {
                content = content.replacing(pattern) { _ in line }
                logger.notice("    ✅ Updated \(setting.key)")
            } else {
                logger.notice("    ℹ️ No \(setting.key) setting found")
            }
        }
        return content
    }
}
