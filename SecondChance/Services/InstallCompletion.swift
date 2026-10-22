//
//  InstallCompletion.swift
//  SecondChance
//
//  Whether an installer that exited cleanly actually finished. An installer
//  killed or crashing partway can still exit 0 under Wine (an Inno Setup
//  install whose worker was killed exited 0 with 159 MB of 560 MB in place),
//  and the game's exe is usually among the first files unpacked, so neither
//  the exit code nor finding the exe proves much. Each installer family
//  records its own finish, only once it has finished:
//
//  - Inno Setup writes "Installation process succeeded." to its `/LOG`.
//  - msiexec ends its log with the INSTALL action returning 1 (success).
//  - InstallShield writes its uninstall log, `setup.ilg`, into the install
//    folder. Its `/f2` result file and its uninstall registry key are no use:
//    both appeared, saying success, seconds into an install later killed.
//

import Foundation

nonisolated enum InstallCompletion {

    /// The line Inno Setup logs once every file, registry entry and shortcut
    /// is in place.
    static let innoSuccessLine = "Installation process succeeded."

    /// Nil when `log` (an Inno Setup `/LOG` file) records the install
    /// finishing, else why not.
    static func innoProblem(log: String) -> String? {
        if log.contains(innoSuccessLine) { return nil }
        return "Inno Setup's log has no \"\(innoSuccessLine)\" line\(lastLine(of: log))"
    }

    /// Nil when `log` (an msiexec `/l*` file) records the install finishing,
    /// else why not. Windows' msiexec logs "Installation success or error
    /// status: 0"; Wine's only logs the top-level action's result, where 1
    /// means success.
    static func msiProblem(log: String) -> String? {
        let finished = log.split(whereSeparator: \.isNewline).contains { line in
            (line.contains("Action ended") && line.contains(": INSTALL. Return value 1."))
                || line.contains("Installation success or error status: 0")
        }
        if finished { return nil }
        return "msiexec's log doesn't record the install finishing\(lastLine(of: log))"
    }

    /// Nil when InstallShield's uninstall log is where its version puts it,
    /// else why not. InstallShield 6 writes it into the install folder, which
    /// may be a folder above the game's exe; 7 and later into
    /// `InstallShield Installation Information\{product GUID}` under
    /// Program Files.
    static func installShieldProblem(gameDir: URL, driveC: URL, fileManager: FileManager = .default) -> String? {
        // Resolved, since the temp wrapp is under /var, which is /private/var.
        let root = driveC.resolvingSymlinksInPath().path
        var dir = gameDir.resolvingSymlinksInPath()
        var searched: [URL] = []
        while dir.path.hasPrefix(root) && dir.path != root {
            searched.append(dir)
            dir.deleteLastPathComponent()
        }
        for programFiles in ["Program Files (x86)", "Program Files"] {
            let info = driveC.appendingPathComponent(programFiles)
                .appendingPathComponent("InstallShield Installation Information")
            let products = (try? fileManager.contentsOfDirectory(at: info, includingPropertiesForKeys: nil)) ?? []
            searched += products
        }
        for folder in searched {
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            if names.contains(where: isInstallShieldUninstallLog) { return nil }
        }
        return "InstallShield wrote no setup.ilg uninstall log, which it does once an install finishes, "
            + "in \(gameDir.lastPathComponent), the folders above it or InstallShield Installation Information"
    }

    /// `setup.ilg` (InstallShield 6 and later) or `DeIsL1.isu` (InstallShield 5).
    static func isInstallShieldUninstallLog(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".ilg") || (lower.hasPrefix("deisl") && lower.hasSuffix(".isu"))
    }

    /// Reads an installer log, which may be UTF-8, Latin-1 or (msiexec on
    /// Windows) UTF-16.
    static func readLog(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func lastLine(of log: String) -> String {
        guard let last = log.split(whereSeparator: \.isNewline)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return " (the log is empty)"
        }
        return "; it stops at: \(last.trimmingCharacters(in: .whitespaces))"
    }
}
