//
//  InstallerPlan.swift
//  SecondChance
//
//  How one attempt at running a game's installer goes, decided once from
//  what is known before it starts: the installer's type, which attempt this
//  is, whether the disc has an InstallShield answer file, and the game. What
//  to run, with which arguments, whether AutoIt drives it, and whether the
//  person will see its wizard all follow from these, so they can't disagree
//  with each other, and are tested without running anything.

import Foundation
import GameCatalog
import SecondChanceKit

nonisolated struct InstallerPlan: Equatable, Sendable {
    let installerPath: String
    let type: InstallerType
    /// 0 for the unattended attempt, 1 for the installer's own wizard.
    let attempt: Int
    /// `nancy-drew-installer/setup.iss` is there: InstallShield can install
    /// silently from it.
    let hasAnswerFile: Bool
    /// The installer as a program inside Wine names it, which is what
    /// AutoIt is given (`windowsPath(ofInstaller:driveC:)`).
    let installerWindowsPath: String
    /// The AutoIt script the step names (`--automation`), as Wine names it
    /// once it's put in the prefix: for an InstallShield installer that,
    /// run silently from its answer file, wouldn't exit by itself.
    let automationScript: String?
    /// Where an MSI or Inno Setup installer writes its own log, as Windows sees it.
    let logPath: String?

    init(installerPath: String, type: InstallerType, attempt: Int, hasAnswerFile: Bool, automationScript: String? = nil,
         driveC: URL? = nil, logPath: String? = nil) {
        self.installerPath = installerPath
        self.type = type
        self.attempt = attempt
        self.hasAnswerFile = hasAnswerFile
        self.installerWindowsPath = driveC.map { Self.windowsPath(ofInstaller: installerPath, driveC: $0) } ?? installerPath
        self.automationScript = automationScript
        self.logPath = logPath
    }

    /// AutoIt clicks through an InstallShield wizard that, run silently from
    /// its answer file, wouldn't exit by itself, when the step names a script.
    var usesAutoIt: Bool {
        type == .installShield && attempt == 0 && hasAnswerFile && automationScript != nil
    }

    /// The installer shows the person its own wizard rather than installing
    /// by itself.
    var runsInteractively: Bool {
        if usesAutoIt { return false }
        switch type {
        case .msi, .innoSetup: return attempt > 0
        case .installShield: return attempt > 0 || !hasAnswerFile
        case .unknown: return true
        }
    }

    /// The installer's own arguments, the same with a script as without.
    var installerArguments: [String] {
        switch type {
        case .msi:
            let log = logPath ?? "nancy-drew-install-log.txt"
            // Silent the first time; the wizard after. Its log either way.
            return attempt == 0 ? ["/qn", "/l*", log, "/i", installerPath] : ["/l*", log, "/i", installerPath]
        case .installShield:
            guard attempt == 0 && hasAnswerFile else { return ["/r"] }  // the wizard, recording
            return ["/s", "/sms", "/f1C:\\\(WrappLayout.installersFolder)\\setup.iss"]
        case .innoSetup:
            let log = logPath.map { ["/LOG=\($0)"] } ?? []
            return attempt == 0 ? ["/verysilent", "/norestart"] + log : log
        case .unknown:
            return []
        }
    }

    /// The Windows program to run.
    var program: String {
        if usesAutoIt { return "C:\\autoit\\AutoIt3.exe" }
        return type == .msi ? "msiexec" : installerPath
    }

    /// Its arguments: with AutoIt, the script, then the installer's own
    /// command for the script to start.
    var arguments: [String] {
        guard usesAutoIt, let automationScript else { return installerArguments }
        return [automationScript, installerWindowsPath] + installerArguments
    }

    /// The installer as a program inside Wine names it: its C: path when it
    /// is in the prefix, as a copied disc's is. An installer outside the
    /// prefix keeps its Mac path, which Wine reaches through the drive the
    /// build lends its folder (`GameInstallerRunner.lendFolder`).
    static func windowsPath(ofInstaller installerPath: String, driveC: URL) -> String {
        let driveCPath = driveC.standardizedFileURL.path
        let installer = URL(fileURLWithPath: installerPath).standardizedFileURL.path
        guard installer.hasPrefix(driveCPath + "/") else { return installerPath }
        return "C:" + installer.dropFirst(driveCPath.count).replacingOccurrences(of: "/", with: "\\")
    }

    /// Through `wine start /wait`, which waits for a GUI installer.
    var usesStart: Bool { !usesAutoIt && type != .msi }

    /// What runs, for the log.
    var description: String {
        let prefix = usesStart ? "wine start /wait " : ""
        return prefix + ([program] + arguments).joined(separator: " ")
    }

    /// What AutoIt automates, for the log; nil when AutoIt isn't used.
    var automatedDescription: String? {
        guard usesAutoIt else { return nil }
        return "wine start /wait \(installerPath) \(installerArguments.joined(separator: " "))"
    }
}
