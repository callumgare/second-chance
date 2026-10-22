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
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.WrappBuildInput")

/// Unified I/O for a wrapp build.
///
/// One implementation serves both GUI and headless runs, using env-var-first
/// resolution — an env var, when set, replaces the panel that would other-
/// wise prompt:
///
/// | Method                        | Env var override                        | Fallback (no env var)          |
/// |-------------------------------|-----------------------------------------|--------------------------------|
/// | `getDisk1Path()`              | `DISK_1_PATH`                           | NSOpenPanel (disk/ISO)         |
/// | `getDisk2Path(gameInfo:disk1:)` | `DISK_2_PATH`                         | NSAlert to swap discs, else NSOpenPanel |
/// | `getHerInstallerPath()`       | `HER_INSTALLER_PATH`                    | NSOpenPanel (.exe, .dmg or .app) |
/// | `steamGameFromEnvironment`    | `STEAM_GAME_SLUG`                       | nil: asked after sign-in       |
/// | `chooseSteamGame(from:)`      | — (only asked when the above is nil)    | NSAlert with the owned games   |
/// | `getSteamLaunchMode(for:)`    | `STEAM_LAUNCH_MODE` (`steam`/`direct`)  | NSAlert, two choices           |
/// | `askAboutSteamInUse(_:)`      | — (headless: nil, the build fails)      | NSAlert: try again, quit, cancel |
/// | `requestVolumeAccess()`       | — (skipped when paths env-supplied)     | NSOpenPanel grant-access       |
/// | `askAboutSuccessReports()`    | — (headless: not asked)                 | NSAlert, once ever             |
/// | `getOutputPath(gameName:)`    | `OUTPUT_PATH`                           | NSOpenPanel save dialog        |
/// | `shouldLaunchGame()`          | `LAUNCH_GAME`, `LAUNCH_GAME_ARGS`       | `(false, [])`                  |
/// | `confirmPatchFailure()`       | `PATCH_FAILURE_POLICY`                  | NSAlert                        |
/// | `onGameDetected()`            | `EXPECTED_GAME_SLUG` (fails on mismatch)| accepts whatever was detected  |
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
        guard let url = await selectDisc(message: "Put the first game disc in your Mac's disc drive, then select it here.") else {
            // Cancelling the very first dialog means the user never started —
            // distinct from cancelling a later prompt mid-install.
            throw WrappBuildError.userCancelledBeforeStart
        }
        return url
    }

    /// Second game disk, only asked for multi-disk games, and only once disk 1
    /// has been copied. When disk 1 is a disc in the drive, the person is
    /// asked to swap it for disc 2 (with an Eject button), and a disc that
    /// then appears is used without asking where it is.
    @MainActor
    func getDisk2Path(gameInfo: GameInfo, disk1: URL) async throws -> URL? {
        guard gameInfo.diskCount > 1 else { return nil }
        if let url = try diskPathFromEnv("DISK_2_PATH", label: "Disk 2") {
            return url
        }
        let pickerMessage = "Select disc 2 of \(gameInfo.title)."
        guard let disc1Volume = Self.ejectableVolume(containing: disk1) else {
            // A folder or a disc image: nothing to swap, just ask where disk 2 is.
            guard let url = await selectDisc(message: pickerMessage) else { throw WrappBuildError.userCancelled }
            return url
        }

        let volumesBefore = Self.ejectableVolumes()
        var ejectFailed = false
        while true {
            let alert = NSAlert()
            alert.messageText = "Now put in disc 2"
            alert.informativeText = ejectFailed
                ? "Disc 1 couldn't be ejected. Eject it from the Finder, put in disc 2, then click Continue."
                : "\(gameInfo.title) comes on two discs, and disc 1 has been copied. Take it out, put in disc 2, then click Continue."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Eject Disc 1")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // A disc that wasn't there before, other than disc 1, is disc 2.
                let new = Self.ejectableVolumes().filter { $0 != disc1Volume && !volumesBefore.contains($0) }
                if new.count == 1 {
                    logger.notice("Disc 2 found in the drive: \(new[0].path)")
                    return new[0]
                }
                guard let url = await selectDisc(message: pickerMessage) else { throw WrappBuildError.userCancelled }
                return url
            case .alertSecondButtonReturn:
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: disc1Volume)
                    ejectFailed = false
                } catch {
                    logger.warning("Couldn't eject disc 1 (\(disc1Volume.path)): \(error.localizedDescription)")
                    ejectFailed = true
                }
            default:
                throw WrappBuildError.userCancelled
            }
        }
    }

    /// The root of the ejectable volume (a CD) that `url` is on, or nil when
    /// it isn't on one: a folder on the Mac, or a mounted disc image.
    static func ejectableVolume(containing url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsEjectableKey, .volumeIsRootFileSystemKey]),
              values.volumeIsEjectable == true, values.volumeIsRootFileSystem != true,
              let volume = values.volume,
              // A disc image is ejectable too, but isn't a disc to swap.
              !ISOMounter.isDiskImageVolume(volume) else { return nil }
        return volume.standardizedFileURL
    }

    /// Every mounted ejectable volume that isn't a disc image.
    static func ejectableVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter {
            (try? $0.resourceValues(forKeys: Set(keys)))?.volumeIsEjectable == true && !ISOMounter.isDiskImageVolume($0)
        }.map(\.standardizedFileURL)
    }

    /// The extensions a Her Interactive download comes as: a Windows
    /// installer, a Mac disk image, or the installer app inside that image
    /// once it's opened.
    static let herDownloadExtensions = ["exe", "dmg", "app"]

    /// A game downloaded from Her Interactive: its Windows installer (.exe),
    /// its Mac disk image (.dmg), or the installer app in the opened image.
    @MainActor
    func getHerInstallerPath() async throws -> URL {
        if let path = environment["HER_INSTALLER_PATH"] {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            let fileExists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let fileExtension = url.pathExtension.lowercased()
            // An app is a folder; the others are files.
            guard fileExists, Self.herDownloadExtensions.contains(fileExtension),
                  isDirectory.boolValue == (fileExtension == "app") else {
                throw WrappBuildError.invalidPath("Her download path must be an existing .exe, .dmg or .app: \(path)")
            }
            return url
        }

        let panel = NSOpenPanel()
        panel.message = "Select the game you downloaded from Her Interactive: the .exe file for Windows, or the .dmg file for Mac."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.herDownloadExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        guard let url = await runOpenPanel(panel) else {
            // The first question asked: back to the welcome screen.
            throw WrappBuildError.userCancelledBeforeStart
        }
        return url
    }

    /// The Steam game `STEAM_GAME_SLUG` names, or nil when it isn't set.
    /// Read before Steam starts, so the install can go in with Steam's
    /// first start; a headless run must set it, as there's no one to ask.
    func steamGameFromEnvironment(among games: [GameInfo]) throws -> GameInfo? {
        guard let slug = environment["STEAM_GAME_SLUG"] else {
            if isHeadlessRun { throw WrappBuildError.missingRequiredParameter("STEAM_GAME_SLUG") }
            return nil
        }
        guard let game = games.first(where: { $0.id == slug && $0.isOnSteam }) else {
            throw WrappBuildError.invalidPath("STEAM_GAME_SLUG \(slug) isn't a game on Steam")
        }
        return game
    }

    /// Which of the games the signed-in Steam account owns to build. Asked
    /// once Steam has signed in, so the list holds only games it can install.
    @MainActor
    func chooseSteamGame(from owned: [GameInfo]) async throws -> GameInfo {
        if isHeadlessRun { throw WrappBuildError.missingRequiredParameter("STEAM_GAME_SLUG") }
        // In the order the games came out, as GameInfoProvider lists them
        // (and so `owned` arrives): how the series is known.
        let games = owned

        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        menu.addItems(withTitles: games.map(\.title))
        let alert = NSAlert()
        alert.messageText = "Which game do you want from Steam?"
        alert.informativeText = "These are the Nancy Drew games your Steam account owns. Second Chance installs the one you pick through Steam."
        alert.accessoryView = menu
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            // The first question the user is asked: back to the welcome screen.
            throw WrappBuildError.userCancelledBeforeStart
        }
        return games[menu.indexOfSelectedItem]
    }

    /// How a DRM-free Steam game should start. Only asked when the game
    /// offers the choice; the engine behind each answer is not the user's
    /// concern, so the question is about what they'll notice.
    @MainActor
    func getSteamLaunchMode(for game: GameInfo) async throws -> GameInfo.SteamLaunchMode {
        if let value = environment["STEAM_LAUNCH_MODE"] {
            guard let mode = GameInfo.SteamLaunchMode(rawValue: value.lowercased()) else {
                throw WrappBuildError.invalidPath("STEAM_LAUNCH_MODE must be steam or direct, not \(value)")
            }
            return mode
        }
        if isHeadlessRun { return .direct }

        let alert = NSAlert()
        alert.messageText = "How should \(game.title) start?"
        alert.informativeText = """
        Launch directly: starts faster and is more reliable, but saves stay on this Mac.

        Launch via Steam: keeps your saves in Steam Cloud, but starts slower.
        """
        alert.addButton(withTitle: "Launch Directly")
        alert.addButton(withTitle: "Launch via Steam")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .direct
        case .alertSecondButtonReturn: return .steam
        default: throw WrappBuildError.userCancelled
        }
    }

    /// Whether a person is there to sign in to Steam if it asks.
    var canSignInToSteam: Bool { !isHeadlessRun }

    /// What to do about another game holding Steam: quit it, try again, or
    /// give up. Nil in a headless run, which can't ask and fails instead.
    @MainActor
    func askAboutSteamInUse(_ holder: SteamLockHolder) async -> SteamLockHolder.Choice? {
        if isHeadlessRun { return nil }
        return holder.ask(blocked: "the game you're adding can't be installed until it quits.")
    }

    /// Grant access to a mounted volume (sandbox). Skipped entirely when the
    /// disk paths came from env vars — headless runs have no sandbox prompts.
    @MainActor
    func requestVolumeAccess(mountPoint: URL) async throws -> URL {
        // Headless/env-supplied runs can't prompt — pass the mount point through.
        if anyDiskPathFromEnv { return mountPoint }

        let accessPanel = NSOpenPanel()
        accessPanel.message = "Second Chance needs your permission to read the game disc. Click Allow to continue."
        accessPanel.prompt = "Allow"
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

        let panel = NSOpenPanel()
        panel.message = "Choose where to save the app for \(gameName). Your Applications folder is a good place: you'll find it there with your other apps."
        panel.prompt = "Save Here"
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
    /// 2. A headless run (env-supplied disks or game, or NON_INTERACTIVE) → continue
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

        if isHeadlessRun { return true }

        let alert = NSAlert()
        alert.messageText = "Game patch failed"
        alert.informativeText = "The patch \"\(patchName)\" failed to apply:\n\n\(error.localizedDescription)\n\nDo you want to continue installing without the patch?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue Without Patch")
        alert.addButton(withTitle: "Cancel Installation")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Whether to send success reports, asked once, after the first build
    /// that worked: it's a question about games that work, and by then the
    /// person has seen one. Neither answer is pushed, so neither button is
    /// the default. Not asked in a headless run or one that can't report,
    /// nor once answered: Settings changes it after that.
    @MainActor
    func askAboutSuccessReports() async {
        guard !isHeadlessRun, FailureReporter.isEnabled,
              ReportingPreferences.load().successReports == nil else { return }

        let alert = NSAlert()
        alert.messageText = "Send success reports?"
        alert.informativeText = """
        Second Chance can let the developer know when a game is set up or played, and whether it worked: \
        which game, where it came from, and the Second Chance and macOS versions. Nothing about you or your \
        files is sent.

        It helps show which games are known to work, so Second Chance can get better for everyone. You can \
        change this any time in Settings.
        """
        let send = alert.addButton(withTitle: "Send")
        let dontSend = alert.addButton(withTitle: "Don't Send")
        send.keyEquivalent = ""
        dontSend.keyEquivalent = "\u{1b}"
        let answer = alert.runModal() == .alertFirstButtonReturn
        ReportingPreferences.update { $0.successReports = answer }
        logger.notice("Success reports: \(answer ? "on" : "off"), as asked after the first successful build")

        guard answer else { return }
        let thanks = NSAlert()
        thanks.messageText = "Thank you!"
        thanks.informativeText = "Your success reports will help show which games work."
        thanks.addButton(withTitle: "OK")
        thanks.runModal()
    }

    // MARK: - Callbacks

    /// The detected game (drives the UI). When `EXPECTED_GAME_SLUG` names the
    /// game the caller asked for (sc does), a different game fails the build:
    /// otherwise a wrong disc builds the wrong wrapp, and the caller reports
    /// success for the game it wanted.
    func onGameDetected(_ gameInfo: GameInfo) async throws {
        if let expected = environment["EXPECTED_GAME_SLUG"], !expected.isEmpty, expected != gameInfo.id {
            logger.critical("❌ Expected \(expected), but the disc is \(gameInfo.title) (\(gameInfo.id))")
            throw WrappBuildError.wrongGame(expected: expected, detected: gameInfo.id)
        }
        await MainActor.run {
            viewModel?.detectedGame = gameInfo
        }
    }

    /// The build finished: reveal the new app in Finder for the person who
    /// made it. Only for a build started from the app's window (a view
    /// model), and not a headless one: a test that builds with an app-like
    /// environment and no view model then deletes its output, and Finder's
    /// window fell back to the temporary folder, one left open per run.
    @MainActor
    func onWrappBuildComplete(_ wrappPath: URL) async {
        guard viewModel != nil, !isHeadlessRun else { return }
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
        anyDiskPathFromEnv || environment["HER_INSTALLER_PATH"] != nil
            || environment["STEAM_GAME_SLUG"] != nil || environment["NON_INTERACTIVE"] == "true"
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

    /// Ask for a game disc. Disc images are accepted as well, though the
    /// message doesn't offer them.
    @MainActor
    private func selectDisc(message: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.folder] + [UTType(filenameExtension: "iso")].compactMap { $0 }
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
