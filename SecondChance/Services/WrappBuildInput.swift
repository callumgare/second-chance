//
//  WrappBuildInput.swift
//  SecondChance
//
//  Unified I/O for wrapp building. Handles all user/env interactions — input
//  paths (disks, installer exe), output choices (save location, launch
//  decision), confirmations, and callbacks.
//
//  Every path/choice method checks a corresponding env var FIRST; if set, it
//  is used with no UI. If unset, the user is prompted (NSOpenPanel/NSAlert).
//  This eliminates the old Interactive / NonInteractive context split — the
//  same code path handles both modes. Headless mode is just "all env vars
//  set, no prompts."
//

import Foundation
import AppKit
import UniformTypeIdentifiers

/// In-process test seam: set disk paths before tapping the UI to bypass
/// NSOpenPanel. Production code never touches this — it stays nil and the
/// panels show normally.
struct PreconfiguredPaths {
    static var disk1: URL?
    static var disk2: URL?
    static var outputDir: URL?
    static var isConfigured: Bool { disk1 != nil }
    static func clear() { disk1 = nil; disk2 = nil; outputDir = nil }
}

/// Unified I/O for a wrapp build.
///
/// Replaces `InstallationContext` + `InteractiveContext` + `NonInteractiveContext`
/// with a single implementation using env-var-first resolution:
///
/// | Method                        | Env var override                        | Fallback (no env var)          |
/// |-------------------------------|-----------------------------------------|--------------------------------|
/// | `getDisk1Path()`              | `DISK_1_PATH`                           | NSOpenPanel (disk/ISO)         |
/// | `getDisk2Path(gameInfo:)`     | `DISK_2_PATH`                           | NSOpenPanel (disk/ISO)         |
/// | `getHerInstallerPath()`       | `HER_INSTALLER_PATH`                    | NSOpenPanel (.exe)             |
/// | `requestVolumeAccess()`       | — (skipped when paths env-supplied)     | NSOpenPanel grant-access       |
/// | `getOutputPath(gameName:)`    | `OUTPUT_PATH`                           | NSOpenPanel save dialog        |
/// | `shouldLaunchGame()`          | `LAUNCH_GAME`, `LAUNCH_GAME_ARGS`       | `(false, [])`                  |
/// | `confirmPatchFailure()`       | `PATCH_FAILURE_POLICY`                  | NSAlert                        |
///
/// There are **no separate interactive/non-interactive classes** — one code
/// path handles both.
class WrappBuildInput {
    private let environment: [String: String]
    private weak var viewModel: WrappBuildViewModel?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        viewModel: WrappBuildViewModel?
    ) {
        self.environment = environment
        self.viewModel = viewModel
    }

    // MARK: - Input Paths

    /// First game disk (directory or ISO). Cancelling this very first prompt
    /// means the user never started — distinct from cancelling later prompts.
    @MainActor
    func getDisk1Path() async throws -> URL {
        if let url = try diskPathFromEnv("DISK_1_PATH", label: "Disk 1") {
            return url
        }
        if let path = PreconfiguredPaths.disk1 { return path }
        guard let url = await selectDiskOrISO(message: "Select the first game disk or ISO:") else {
            // Cancelling the very first dialog means the user never started —
            // distinct from cancelling a later prompt mid-install.
            throw WrappBuildError.userCancelledBeforeStart
        }
        return url
    }

    /// Second game disk, only prompted for multi-disk games.
    @MainActor
    func getDisk2Path(gameInfo: GameInfo) async throws -> URL? {
        guard gameInfo.diskCount > 1 else { return nil }
        if let url = try diskPathFromEnv("DISK_2_PATH", label: "Disk 2") {
            return url
        }
        if let path = PreconfiguredPaths.disk2 { return path }
        guard let url = await selectDiskOrISO(message: "Select the second game disk or ISO:") else {
            throw WrappBuildError.userCancelled
        }
        return url
    }

    /// Her Interactive Windows installer (.exe).
    @MainActor
    func getHerInstallerPath() async throws -> URL {
        if let path = environment["HER_INSTALLER_PATH"] {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  url.pathExtension.lowercased() == "exe" else {
                throw WrappBuildError.invalidPath("Her installer path must be an existing .exe file: \(path)")
            }
            return url
        }

        let panel = NSOpenPanel()
        panel.message = "Select the Windows game installer:"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "exe")].compactMap { $0 }

        guard let url = await runOpenPanel(panel) else {
            throw WrappBuildError.userCancelled
        }
        return url
    }

    /// Grant access to a mounted volume (sandbox). Skipped entirely when the
    /// disk paths came from env vars — headless runs have no sandbox prompts.
    @MainActor
    func requestVolumeAccess(mountPoint: URL) async throws -> URL {
        // Headless/env-supplied runs can't prompt — pass the mount point through.
        if anyDiskPathFromEnv || PreconfiguredPaths.isConfigured { return mountPoint }

        let accessPanel = NSOpenPanel()
        accessPanel.message = "Please grant access to the mounted volume to continue"
        accessPanel.prompt = "Grant Access"
        accessPanel.canChooseFiles = false
        accessPanel.canChooseDirectories = true
        accessPanel.directoryURL = mountPoint
        accessPanel.canCreateDirectories = false

        let response: NSApplication.ModalResponse
        if let keyWindow = NSApp.keyWindow {
            response = await accessPanel.beginSheetModal(for: keyWindow)
        } else {
            response = accessPanel.runModal()
        }

        guard response == .OK, let selectedURL = accessPanel.url else {
            throw NSError(domain: "ISOMount", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Access to mounted volume was denied"
            ])
        }
        return selectedURL
    }

    // MARK: - Output Choices

    /// Where to save the finished wrapp.
    @MainActor
    func getOutputPath(gameName: String) async throws -> URL {
        if let path = environment["OUTPUT_PATH"] {
            let url = URL(fileURLWithPath: path)
            // Create directory if it doesn't exist
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        if let dir = PreconfiguredPaths.outputDir { return dir }

        let panel = NSOpenPanel()
        panel.message = "Choose where to save the Nancy Drew app:"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard let url = await runOpenPanel(panel) else {
            throw WrappBuildError.userCancelled
        }
        return url
    }

    /// Whether to launch the finished wrapp (headless automation support).
    func shouldLaunchGame() async -> (Bool, [String]) {
        let shouldLaunch = environment["LAUNCH_GAME"] == "true"
        let args = parseGameArgs(environment["LAUNCH_GAME_ARGS"])
        return (shouldLaunch, args)
    }

    // MARK: - Confirmations

    /// Ask whether to continue after a game patch failed.
    ///
    /// Resolution order:
    /// 1. `PATCH_FAILURE_POLICY=continue|cancel` env var (headless automation)
    /// 2. Env-supplied disk paths (headless run) → continue
    /// 3. NSAlert (GUI)
    ///
    /// A modal alert under a `.prohibited` activation policy (non-interactive
    /// mode) is invisible and unfocusable — and would hang the build forever —
    /// so headless runs never prompt.
    @MainActor
    func confirmPatchFailure(patchName: String, error: Error) async -> Bool {
        switch environment["PATCH_FAILURE_POLICY"]?.lowercased() {
        case "continue": return true
        case "cancel": return false
        default: break
        }

        if anyDiskPathFromEnv { return true }

        let alert = NSAlert()
        alert.messageText = "Game patch failed"
        alert.informativeText = "The patch \"\(patchName)\" failed to apply:\n\n\(error.localizedDescription)\n\nDo you want to continue installing without the patch?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue Without Patch")
        alert.addButton(withTitle: "Cancel Installation")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Callbacks

    /// The detected game (drives the UI).
    func onGameDetected(_ gameInfo: GameInfo) async {
        await MainActor.run {
            viewModel?.detectedGame = gameInfo
        }
    }

    /// The build finished (GUI reveals in Finder; headless does nothing).
    @MainActor
    func onWrappBuildComplete(_ wrappPath: URL) async {
        guard !isHeadlessRun else { return }
        // Show in Finder
        NSWorkspace.shared.selectFile(wrappPath.path, inFileViewerRootedAtPath: "")
    }

    // MARK: - Env Helpers

    /// True when any disk path was env-supplied — used to detect headless runs
    /// where prompts must never appear.
    private var anyDiskPathFromEnv: Bool {
        environment["DISK_1_PATH"] != nil
    }

    /// True when running headless (any build input env var set or the
    /// NON_INTERACTIVE flag present).
    private var isHeadlessRun: Bool {
        anyDiskPathFromEnv || environment["NON_INTERACTIVE"] == "true"
    }

    /// Resolve a disk path (directory or ISO) from an env var with validation.
    private func diskPathFromEnv(_ name: String, label: String) throws -> URL? {
        guard let path = environment[name] else { return nil }
        let url = URL(fileURLWithPath: path)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WrappBuildError.invalidPath("\(label) path does not exist: \(path)")
        }

        guard isDirectory.boolValue || url.pathExtension.lowercased() == "iso" else {
            throw WrappBuildError.invalidPath("\(label) path must be a directory or ISO file")
        }

        return url
    }

    // MARK: - Panel Helpers

    @MainActor
    private func runOpenPanel(_ panel: NSOpenPanel) async -> URL? {
        let response: NSApplication.ModalResponse
        if let keyWindow = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: keyWindow)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    @MainActor
    private func selectDiskOrISO(message: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.folder, UTType(filenameExtension: "iso")!]
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")

        return await runOpenPanel(panel)
    }

    /// Split by spaces, respecting quoted strings.
    private func parseGameArgs(_ argsString: String?) -> [String] {
        guard let args = argsString else { return [] }

        var result: [String] = []
        var current = ""
        var inQuotes = false

        for char in args {
            if char == "\"" {
                inQuotes = !inQuotes
            } else if char == " " && !inQuotes {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
