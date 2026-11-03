//
//  WineSteps.swift
//  SecondChance
//
//  The wine module's instructions, and EDIT --ini, carried out as a plan's
//  steps say: the prefix stage's, and a stage's own (cnc-ddraw's).

import Foundation
import Logging
import SecondChanceKit
import WrappBuilder

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.WineSteps")

/// Carries out `WINE.DRIVES`, `WINE.REGISTRY`, `WINE.WINETRICKS` and
/// `EDIT --ini` in a wrapp's prefix: what the wine module's `prefix` stage and
/// its `cnc-ddraw` function expand to. Each step's `--progress` names the
/// text the build shows meanwhile.
struct WineSteps {
    let bus: EventBus<AppEvent>

    /// Whether this carries `step` out.
    nonisolated static func handles(_ step: PlannedStep) -> Bool {
        switch (step.module, step.instruction) {
        case ("wine", "DRIVES"), ("wine", "REGISTRY"), ("wine", "WINETRICKS"): true
        case (nil, "EDIT"): step.has("ini")
        default: false
        }
    }

    func run(_ step: PlannedStep, wrappPath: URL) async throws {
        let wine = Wine(wrapp: wrappPath)
        if let progress = step.option("progress").flatMap(WineManager.progressText) {
            await bus.publishWrappBuild(.progress(.settingUpWrapp(substep: progress)))
        }
        logger.notice("Step: \(step) (\(step.origin))")
        switch (step.module, step.instruction) {
        case ("wine", "DRIVES"):
            // C: at drive_c, relative so the prefix still works copied into a
            // wrapp, and every other drive blocked: Z: shows the whole Mac.
            guard step.option("only") == "C:" else {
                throw WrappBuildError.buildRecipeProblem("\(step.origin): this build keeps only C: (WINE.DRIVES --only=C:)")
            }
            wine.drives.removeAll()
            try wine.drives.mount("../drive_c", as: "c")
            wine.drives.block("abdefghijklmnopqrstuvwxyz")
        case ("wine", "REGISTRY"):
            guard let target = step.arguments.first, let colon = target.lastIndex(of: ":") else {
                throw WrappBuildError.buildRecipeProblem("\(step.origin): WINE.REGISTRY names <key>:<name>")
            }
            let key = WineManager.registryKey(String(target[..<colon]))
            let name = String(target[target.index(after: colon)...])
            if step.has("remove") {
                try await wine.registry.deleteValue(name, in: key)
            } else {
                guard step.arguments.count == 2 else {
                    throw WrappBuildError.buildRecipeProblem("\(step.origin): WINE.REGISTRY --set needs the value")
                }
                try await wine.registry.set(.string(step.arguments[1]), for: name, in: key)
            }
        case ("wine", "WINETRICKS"):
            guard let verb = step.arguments.first else { return }
            try await Winetricks(wine: wine).install(verb)
        default:
            try editINI(step, wrappPath: wrappPath)
        }
    }

    /// `EDIT <file> --ini=<section>.<key>=<value>…`: each setting changed in
    /// its section, or added to it; with `--must-exist`, one that isn't
    /// there already fails the step, naming each such.
    func editINI(_ step: PlannedStep, wrappPath: URL) throws {
        guard let path = step.arguments.first, let file = WrappLayout(app: wrappPath).location(path) else {
            throw WrappBuildError.buildRecipeProblem("\(step.origin): EDIT's file isn't in the app")
        }
        let settings = try (step.options["ini"] ?? []).map { setting -> (section: String, key: String, value: String) in
            guard let equals = setting.firstIndex(of: "="), let dot = setting[..<equals].firstIndex(of: ".") else {
                throw WrappBuildError.buildRecipeProblem("\(step.origin): --ini=\(setting) isn't <section>.<key>=<value>")
            }
            return (String(setting[..<dot]), String(setting[setting.index(after: dot)..<equals]),
                    String(setting[setting.index(after: equals)...]))
        }
        let edited = try Self.edit(String(contentsOf: file, encoding: .utf8), settings: settings,
                                   mustExist: step.has("must-exist"))
        guard edited.missing.isEmpty else {
            throw WrappBuildError.buildRecipeProblem(
                "\(step.origin): \(file.lastPathComponent) has no \(edited.missing.joined(separator: ", ")) to change (--must-exist)")
        }
        try edited.text.write(to: file, atomically: true, encoding: .utf8)
        logger.notice("✓ Set \(settings.map { "\($0.section).\($0.key)=\($0.value)" }.joined(separator: ", ")) in \(file.lastPathComponent)")
    }

    /// `text`, an .ini file's, with `settings` set: the lines changed, and
    /// those not there added at the end of their section (or a new one),
    /// or with `mustExist`, named as missing. Its line endings are kept:
    /// Windows programs' files (cnc-ddraw's) end lines with CRLF.
    nonisolated static func edit(_ text: String, settings: [(section: String, key: String, value: String)],
                                 mustExist: Bool) -> (text: String, missing: [String]) {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        var missing: [String] = []
        for setting in settings {
            var section = ""
            var sectionEnd: Int?
            var found = false
            for index in lines.indices {
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") && line.hasSuffix("]") {
                    section = String(line.dropFirst().dropLast())
                    continue
                }
                guard section.caseInsensitiveCompare(setting.section) == .orderedSame else { continue }
                sectionEnd = index + 1
                guard let equals = line.firstIndex(of: "="),
                      line[..<equals].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(setting.key) == .orderedSame
                else { continue }
                lines[index] = "\(line[..<equals].trimmingCharacters(in: .whitespaces))=\(setting.value)"
                found = true
            }
            guard !found else { continue }
            if mustExist {
                missing.append("\(setting.section).\(setting.key)")
            } else if let sectionEnd {
                lines.insert("\(setting.key)=\(setting.value)", at: sectionEnd)
            } else {
                lines += ["[\(setting.section)]", "\(setting.key)=\(setting.value)"]
            }
        }
        return (lines.joined(separator: newline), missing)
    }
}
