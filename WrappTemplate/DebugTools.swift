//
//  DebugTools.swift
//  WrappTemplate
//
//  What `--debug` and `--debug-options` add: the debug settings shown before
//  the game starts, and the shells and Wine tools the Debug menu opens.

import Foundation
import AppKit
import Logging
import os
import SecondChanceKit
import SecondChanceReporting
import GameCatalog

// MARK: - Debug Settings

func showDebugSettings(_ config: GameConfig, initialDebugMode: Bool) -> (shouldContinue: Bool, debugMode: Bool) {
    // Initialize NSApplication if not already done
    _ = NSApplication.shared
    installEditMenuIfNeeded()
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    // Process events briefly to allow activation to complete
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

    // Keep showing dialog until user chooses to continue or cancel
    while true {
        let alert = NSAlert()
        alert.messageText = "Debug Settings"
        let debugStatus = initialDebugMode ? "Enabled" : "Disabled"
        alert.informativeText = "Game: \(config.appPath.lastPathComponent)\nEngine: \(config.gameEngine.rawValue)\nPrefix: \(config.winePrefix.path)\n\n"
            + "Launch Command: \(getGameLaunchInfo(config).formatLaunchCommand())\n\nDebug Mode: \(debugStatus)"
        alert.alertStyle = .informational

        // Add checkbox for debug mode
        let debugCheckbox = NSButton(checkboxWithTitle: "Enable Debug Mode (show log window)", target: nil, action: nil)
        debugCheckbox.state = initialDebugMode ? .on : .off
        alert.accessoryView = debugCheckbox

        alert.addButton(withTitle: "Continue Launch")
        alert.addButton(withTitle: "Open Debug Shell")
        alert.addButton(withTitle: "Wine Control Panel")
        alert.addButton(withTitle: "Wine Config")
        alert.addButton(withTitle: "Show Wine Prefix in Finder")
        alert.addButton(withTitle: "Crash Now (test crash reporting)")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        let debugModeEnabled = debugCheckbox.state == .on

        switch response {
        case .alertFirstButtonReturn:  // Continue Launch
            return (true, debugModeEnabled)
        case .alertSecondButtonReturn:  // Open Debug Shell
            launchShell(config)
        case .alertThirdButtonReturn:  // Wine Control Panel
            launchWineControlPanel(config)
        case NSApplication.ModalResponse(rawValue: 1003):  // Wine Config
            launchWineConfig(config)
        case NSApplication.ModalResponse(rawValue: 1004):  // Show Wine Prefix in Finder
            showWinePrefixInFinder(config)
        case NSApplication.ModalResponse(rawValue: 1005):  // Crash Now
            FailureReporter.crashForTesting()
        default:  // Cancel
            return (false, debugModeEnabled)
        }
    }
}

func launchWineShell(_ config: GameConfig) {
    mainLogger.notice("Opening Wine shell...")

    let wine = config.wine

    mainLogger.notice("Wine prefix: \(config.winePrefix)")
    mainLogger.notice("Wine environment variables: \(wine.variables)")

    // Get the game launch command
    let launchInfo = getGameLaunchInfo(config)
    let gameLaunchCommand = launchInfo.formatLaunchCommand()

    // Build shell script using process substitution for init file (to work around SIP stripping DYLD_* variables)
    // Note: they'll still be stripped when you call system binaries like "env" from within the shell but other binaries
    // should inherit them.
    var script = "#!/bin/bash\n"
    script += "exec /bin/bash --init-file <(cat <<'INIT_EOF'\n"

    // Welcome message
    script += "clear\n"
    script += "echo 'Wine Debug Shell'\n"
    script += "echo '================'\n"
    script += "echo 'Wine environment variables have been set.'\n"
    script += "echo ''\n"
    script += "echo 'Game launch command:'\n"
    // Properly escape single quotes in the game launch command for display
    let escapedCommand = gameLaunchCommand.replacingOccurrences(of: "'", with: "'\\''")
    script += "echo '  \(escapedCommand)'\n"
    script += "echo ''\n"
    script += "echo 'Useful commands:'\n"
    script += "echo '  wine --version'\n"
    script += "echo '  wineserver -k                                    (kill all Wine processes)'\n"
    script += "echo '  \"$(which wineserver)\" -f -p                      (start the wineserver - for some reason this fails unless path is absolute)'\n"
    script += "echo '  wine winecfg                                          (Wine configuration)'\n"
    script += "echo '  wine \"C:\\windows\\syswow64\\cnc-ddraw config.exe\"  (cnc-ddraw configuration)'\n"
    script += "echo ''\n"

    // Export all Wine environment variables; Wine's binaries come first on
    // their PATH.
    script += wine.shellExports + "\n"
    script += "echo 'Wine binaries are now in PATH'\n"

    // CD to drive_c directory
    let driveCPath = wine.driveC.path
    let escapedDriveCPath = driveCPath.replacingOccurrences(of: "'", with: "'\\''")
    script += "cd '\(escapedDriveCPath)'\n"
    script += "echo 'Current directory: '\n"
    script += "pwd\n"
    script += "echo ''\n"

    script += "INIT_EOF\n"
    script += ")\n"

    // Write script to temporary .command file
    let tempCommand = FileManager.default.temporaryDirectory.appendingPathComponent("debug-shell-\(UUID().uuidString).command")

    do {
        try script.write(to: tempCommand, atomically: true, encoding: .utf8)

        // Make it executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempCommand.path)

        // Open the .command file (macOS will open it in Terminal)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [tempCommand.path]
        try process.run()

        mainLogger.notice("Debug shell opened in Terminal")
    } catch {
        mainLogger.error("Error creating shell command file: \(error)")
    }
}

func launchScummvmShell(_ config: GameConfig) {
    mainLogger.notice("Opening ScummVM shell...")

    // Get the game launch info
    let launchInfo = getGameLaunchInfo(config)
    let gameLaunchCommand = launchInfo.formatLaunchCommand()

    // Build shell script
    var script = "#!/bin/bash\n"
    script += "exec /bin/bash --init-file <(cat <<'INIT_EOF'\n"

    // Welcome message
    script += "clear\n"
    script += "echo 'ScummVM Debug Shell'\n"
    script += "echo '==================='\n"
    script += "echo \(shellQuote("ScummVM binary: \(launchInfo.executable)"))\n"
    script += "echo ''\n"
    script += "echo 'Arguments:'\n"
    for arg in launchInfo.arguments {
        let escapedArg = arg.replacingOccurrences(of: "'", with: "'\\''")
        script += "echo '  \(escapedArg)'\n"
    }
    script += "echo ''\n"

    script += "echo 'Game launch command:'\n"
    let escapedCommand = gameLaunchCommand.replacingOccurrences(of: "'", with: "'\\''")
    script += "echo '  \(escapedCommand)'\n"
    script += "echo ''\n"
    script += "echo 'Useful commands:'\n"
    script += "echo \(shellQuote("  \(shellQuote(launchInfo.executable)) --help"))\n"
    script += "echo \(shellQuote("  \(shellQuote(launchInfo.executable)) --list-games"))\n"
    script += "echo ''\n"

    // CD to directory containing the binary (if there's a working directory, use that)
    let targetDir = launchInfo.workingDirectory ?? (launchInfo.executable as NSString).deletingLastPathComponent
    let escapedTargetDir = targetDir.replacingOccurrences(of: "'", with: "'\\''")
    script += "cd '\(escapedTargetDir)'\n"
    script += "echo 'Current directory: '\n"
    script += "pwd\n"
    script += "echo ''\n"

    script += "INIT_EOF\n"
    script += ")\n"

    // Write script to temporary .command file
    let tempCommand = FileManager.default.temporaryDirectory.appendingPathComponent("debug-shell-\(UUID().uuidString).command")

    do {
        try script.write(to: tempCommand, atomically: true, encoding: .utf8)

        // Make it executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempCommand.path)

        // Open the .command file (macOS will open it in Terminal)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [tempCommand.path]
        try process.run()

        mainLogger.notice("Debug shell opened in Terminal")
    } catch {
        mainLogger.error("Error creating shell command file: \(error)")
    }
}

func launchShell(_ config: GameConfig) {
    switch config.gameEngine {
    case .scummvm:
        launchScummvmShell(config)
    case .wine, .wineSteam, .wineSteamSilent:
        launchWineShell(config)
    }
}

func launchWineControlPanel(_ config: GameConfig) {
    mainLogger.notice("Launching Wine control panel...")
    runInTerminal(.wine(["control"]), with: config.wine)
}

func launchWineConfig(_ config: GameConfig) {
    mainLogger.notice("Launching Wine config...")
    // winecfg is a Windows program, run through wine: Wine has no bin/winecfg.
    runInTerminal(.wine(["winecfg"]), with: config.wine)
}

/// Run `command` with our own stdin, stdout and stderr, and wait for it:
/// its exit code, or 1 when it couldn't be run or was killed.
@discardableResult
func runInTerminal(_ command: WineCommand, with wine: Wine) -> Int32 {
    do {
        try Blocking.wait { try await wine.run(command, output: .terminal) }
        return 0
    } catch WineError.executionFailed(let code) {
        return code
    } catch {
        mainLogger.error("Couldn't run \(command.displayName): \(error)")
        return 1
    }
}

func showWinePrefixInFinder(_ config: GameConfig) {
    mainLogger.notice("Opening Wine prefix in Finder: \(config.winePrefix.path)")
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: config.winePrefix.path)
}

// MARK: - Debug Menu Handler

class DebugMenuHandler: NSObject {
    let config: GameConfig

    init(config: GameConfig) {
        self.config = config
        super.init()
    }

    @objc func openDebugShell() {
        launchShell(config)
    }
}
