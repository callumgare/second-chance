//
//  WrappBuildInput.swift
//  SecondChance
//
//  Unified I/O for wrapp building. Handles all user/env interactions — input
//  paths (disks, installer exe), output choices (save location, launch
//  decision), confirmations, and callbacks.
//
//  Every path/choice method checks a corresponding env var FIRST; if set, it
//  is used with no UI. If unset, the user is asked: in the main window
//  (`BuildQuestion`), or with an open panel or an alert.
//  This eliminates the old Interactive / NonInteractive context split — the
//  same code path handles both modes. Headless mode is just "all env vars
//  set, no prompts."
//

import Foundation
import AppKit
import UniformTypeIdentifiers
import Logging
import SecondChanceKit
import SecondChanceReporting
import GameCatalog

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
/// | `getDisk2Path(gameInfo:disk1:)` | `DISK_2_PATH`                         | Ejects disc 1; main window, answered by disc 2 going in, or NSOpenPanel |
/// | `getHerInstallerPath()`       | `HER_INSTALLER_PATH`                    | NSOpenPanel (.exe, .dmg or .app) |
/// | `getMacROM(rejected:)`        | `MAC_ROM_PATH`                          | Main window, then NSOpenPanel  |
/// | `steamGameFromEnvironment`    | `STEAM_GAME_SLUG`                       | nil: asked after sign-in       |
/// | `chooseSteamGame(from:)`      | — (only asked when the above is nil)    | main window, the owned games   |
/// | `getSteamLaunchMode(for:)`    | `SECOND_CHANCE_INPUTS`'s `launch-mode`, or `STEAM_LAUNCH_MODE` (`steam`/`direct`) | main window, two choices |
/// | `askAboutSteamInUse(_:)`      | — (headless: nil, the build fails)      | main window: try again, quit, cancel |
/// | `takeSteamSignInAfreshRequest()` | — (headless: never)                  | the progress screen's button   |
/// | `bigFishGameFromEnvironment`  | `BIG_FISH_GAME_SLUG`                    | nil: asked after sign-in       |
/// | `chooseBigFishGame(from:)`    | — (only asked when the above is nil)    | main window, the owned games   |
/// | `chooseDownload(from:)`       | `DOWNLOAD_PROGRAM`                      | main window, the free games    |
/// | `confirmDownload(_:)`         | — (headless: goes ahead)                | main window: where it's from   |
/// | `confirmReinstall(_:source:)` | — (headless: fails, as up to date)      | main window: install again, cancel |
/// | `isBigFishTrial`              | `BIG_FISH_TRIAL=1` (tests only)         | false: the full game           |
/// | `bigFishTestSignIn`           | `BIG_FISH_TEST_SIGN_IN=1`, `BIG_FISH_EMAIL`, `BIG_FISH_PASSWORD` (tests only) | nil: the person signs in |
/// | `askAboutSuccessReports()`    | — (headless: not asked)                 | main window, once ever         |
/// | `getSaveLocation(for:)`       | `OUTPUT_PATH` (replaces an older app)    | NSOpenPanel; cancelling asks to choose again or start over; asks before replacing |
/// | `shouldLaunchGame()`          | `LAUNCH_GAME`, `LAUNCH_GAME_ARGS`       | `(false, [])`                  |
/// | `confirmPatchFailure()`       | `PATCH_FAILURE_POLICY`                  | main window                    |
/// | `askAboutUnrecognisedGame(_:)` | — (headless: installs it anyway)       | main window: choose another, install anyway, cancel |
/// | `chooseGameProgram(among:)`   | — (headless: the first, as ranked)      | main window, the programs      |
/// | `ensureRosetta(bus:)`         | — (headless: fails if it's missing)     | NSAlert offering to install it |
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

    /// The error a question cancelled back to the welcome screen ends the
    /// build with, the screen meanwhile saying it's stopping: the build
    /// may have Steam or Big Fish to stop and a half-made app to remove.
    private func cancelledBeforeStart() -> WrappBuildError {
        viewModel?.windDownAfterCancelledQuestion()
        return .userCancelledBeforeStart
    }

    typealias Question = WrappBuildViewModel.BuildQuestion

    /// Cancel and Continue, for a question with a list to pick from.
    static var cancelOrContinue: [Question.Action] {
        [.init(title: String(localized: "Cancel"), role: .cancel),
         .init(title: String(localized: "Continue"), role: .primary)]
    }

    /// Ask `question` in the main window, and wait for the answer: nil when
    /// it was withdrawn, the build cancelled, or there's no window to ask in.
    @MainActor
    private func ask(_ question: Question) async -> WrappBuildViewModel.BuildAnswer? {
        guard let viewModel else {
            logger.warning("No window to ask \"\(question.title)\" in: taken as cancelled")
            return nil
        }
        return await viewModel.ask(question)
    }

    // MARK: - Input Paths

    /// First game disk (directory or ISO). Cancelling this very first prompt
    /// means the user never started — distinct from cancelling later prompts.
    @MainActor
    func getDisk1Path() async throws -> URL {
        if let url = try diskPathFromEnv("DISK_1_PATH", label: "Disk 1") {
            return url
        }
        if let url = takeRetryInstaller() { return url }
        guard let url = await selectDisc(message: "Put the first game disc in your Mac's disc drive, then select it here.") else {
            // Cancelling the very first dialog means the user never started —
            // distinct from cancelling a later prompt mid-install.
            throw cancelledBeforeStart()
        }
        viewModel?.chosenInstaller = url
        return url
    }

    /// Second game disk, only asked for multi-disk games, and only once disk 1
    /// has been copied. When disk 1 is a disc in the drive, it is ejected
    /// and the person asked for disc 2; a disc that then goes in is used
    /// without anyone clicking anything.
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
        // Disc 1 is done with: out it comes, rather than asking for a click.
        var ejectFailed = !(await Self.eject(disc1Volume))
        while true {
            let (question, eject, choose) = Self.disc2Question(for: gameInfo, ejectFailed: ejectFailed)
            // A new disc going in answers the question: Disk Arbitration says
            // when it has mounted.
            var inserted: URL?
            let watcher = DiscMountWatcher { [weak viewModel] volume in
                guard volume != disc1Volume, !volumesBefore.contains(volume),
                      Self.ejectableVolumes().contains(volume) else { return }
                inserted = volume
                viewModel?.withdrawQuestion()
            }
            let answer = await ask(question)
            watcher.stop()
            if let inserted {
                logger.notice("Disc 2 went in: \(inserted.path)")
                return inserted
            }
            switch answer?.action {
            case choose:
                // A disc that wasn't there before, other than disc 1, is disc 2.
                let new = Self.ejectableVolumes().filter { $0 != disc1Volume && !volumesBefore.contains($0) }
                if new.count == 1 {
                    logger.notice("Disc 2 found in the drive: \(new[0].path)")
                    return new[0]
                }
                if let url = await selectDisc(message: pickerMessage) { return url }
                // Cancelling the panel goes back to waiting for the disc.
            case eject where eject != nil:
                ejectFailed = !(await Self.eject(disc1Volume))
            default:
                throw WrappBuildError.userCancelled
            }
        }
    }

    // MARK: - Questions

    /// Which game to get from Steam, of the `games` the account owns.
    static func steamGameQuestion(_ games: [GameInfo]) -> Question {
        Question(
            title: String(localized: "Which game do you want from Steam?"),
            detail: String(localized: "These are the Nancy Drew games your Steam account owns. Second Chance installs the one you pick through Steam."),
            choicesLabel: String(localized: "Games"),
            choices: games.map { .init(title: $0.title) },
            actions: cancelOrContinue,
            step: .source,
            comesToFront: true)
    }

    /// How a DRM-free Steam game should start: `.direct`, then `.steam`.
    static func launchModeQuestion(for game: GameInfo) -> Question {
        Question(
            title: String(localized: "How should \(game.title) start?"),
            detail: String(localized: "Either way it's the same game. They differ in how quickly it starts and where your saves are kept."),
            choicesLabel: String(localized: "Ways to start the game"),
            choices: [
                .init(title: String(localized: "Launch Directly"),
                      detail: String(localized: "Starts faster and is more reliable, but saves stay on this Mac.")),
                .init(title: String(localized: "Launch via Steam"),
                      detail: String(localized: "Keeps your saves in Steam Cloud, but starts slower.")),
            ],
            actions: cancelOrContinue,
            step: .source)
    }

    /// Put in disc 2, with which of its buttons ejects disc 1 (offered once
    /// that has failed) and which chooses disc 2 in an open panel.
    static func disc2Question(for gameInfo: GameInfo, ejectFailed: Bool) -> (Question, eject: Int?, choose: Int) {
        var actions: [Question.Action] = [.init(title: String(localized: "Cancel"), role: .cancel)]
        let eject = ejectFailed ? actions.count : nil
        if ejectFailed { actions.append(.init(title: String(localized: "Eject Disc 1"))) }
        let choose = actions.count
        actions.append(.init(title: String(localized: "Choose Disc 2…"), role: .primary))
        let question = Question(
            title: String(localized: "Now put in disc 2"),
            detail: ejectFailed
                ? String(localized: """
                    Disc 1 couldn't be ejected. Eject it from the Finder and put in disc 2: installing carries on by \
                    itself once it's in. If disc 2 is already on this Mac, choose it instead.
                    """)
                : String(localized: """
                    \(gameInfo.title) comes on two discs, and disc 1 has been copied. Take it out and put in disc 2: \
                    installing carries on by itself once it's in. If disc 2 is already on this Mac, choose it instead.
                    """),
            actions: actions,
            waiting: String(localized: "Waiting for disc 2…"))
        return (question, eject, choose)
    }

    /// Eject the disc at `volume`, off the main thread (it can take a few
    /// seconds); whether it went.
    private static func eject(_ volume: URL) async -> Bool {
        do {
            try await Blocking.run { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) }
            logger.notice("Ejected disc 1 (\(volume.path))")
            return true
        } catch {
            logger.warning("Couldn't eject disc 1 (\(volume.path)): \(error.localizedDescription)")
            return false
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

    /// What Try Again started this build from (`WrappBuildViewModel.retryBuild`),
    /// if it's still there: the disc or download the failed build used.
    @MainActor
    func takeRetryInstaller() -> URL? {
        guard let viewModel, let url = viewModel.retryInstaller else { return nil }
        viewModel.retryInstaller = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.notice("Trying again, but \(url.path) has gone: asking for it again")
            return nil
        }
        logger.notice("Trying again from \(url.path)")
        viewModel.chosenInstaller = url
        return url
    }

    /// The extensions a Her Interactive download comes as: a Windows
    /// installer, a Mac disk image, or the installer app inside that image
    /// once it's opened. A sparse bundle is a disk image made on a Mac (of
    /// a disc, with Disk Utility).
    nonisolated static let herDownloadExtensions = ["exe", "dmg", "app", "sparsebundle"]

    /// Whether `url`, which exists, is a Her download by its name and kind:
    /// an app is a folder, and so is a sparse bundle (whatever its name),
    /// the others are files.
    nonisolated static func isHerDownload(_ url: URL, isDirectory: Bool) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        guard herDownloadExtensions.contains(fileExtension) else { return false }
        if fileExtension == "app" { return isDirectory }
        if isDirectory { return ISOMounter.isMacDiskImage(url) && ISOMounter.isDiskImageBundle(url) }
        return fileExtension != "sparsebundle"
    }

    /// A game downloaded from Her Interactive: its Windows installer (.exe),
    /// its Mac disk image (.dmg), or the installer app in the opened image.
    @MainActor
    func getHerInstallerPath() async throws -> URL {
        if let path = environment["HER_INSTALLER_PATH"] {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            let fileExists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard fileExists, Self.isHerDownload(url, isDirectory: isDirectory.boolValue) else {
                throw WrappBuildError.invalidPath("Her download path must be an existing .exe, .dmg or .app: \(path)")
            }
            return url
        }

        if let url = takeRetryInstaller() { return url }

        let panel = NSOpenPanel()
        panel.message = String(localized: """
            Select the game you downloaded from Her Interactive: the .exe file for Windows, \
            or for Mac the .dmg file or the installer app inside it.
            """)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.herDownloadExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        guard let url = await runOpenPanel(panel) else {
            // The first question asked: back to the welcome screen.
            throw cancelledBeforeStart()
        }
        viewModel?.chosenInstaller = url
        return url
    }

    /// A classic Mac's ROM, for a game the basilisk module runs: the file
    /// `MAC_ROM_PATH` names, or one the person chooses, told first what it
    /// is and where one can be had. nil when there's no one to ask (a
    /// headless build without `MAC_ROM_PATH`); throws when they cancel. The
    /// file is the caller's to check (`MacROMs`); `rejected` is a file that
    /// wasn't one, asked about again; with `asking` false, only
    /// `MAC_ROM_PATH` is looked at.
    @MainActor
    func getMacROM(rejected: URL? = nil, asking: Bool = true) async throws -> URL? {
        if rejected == nil, let path = environment["MAC_ROM_PATH"] {
            return URL(fileURLWithPath: path)
        }
        guard asking, viewModel != nil, environment["NON_INTERACTIVE"] != "true" else { return nil }
        let detail = rejected == nil
            ? String(localized: """
                To run Mac games, Second Chance needs the contents of the ROM chip from an old Mac: a Quadra 650 \
                or 800 works best. Second Chance keeps it, so it's asked for only once.
                """)
            : String(localized: """
                That file isn't the ROM of a Mac that Second Chance can run. Choose the ROM of a Quadra 650 or \
                800, or a Centris 650.
                """)
        for _ in 0..<20 {
            let question = Question(
                title: String(localized: "This Game Needs a Mac's ROM"), detail: detail,
                actions: [.init(title: String(localized: "Cancel"), role: .cancel),
                          .init(title: String(localized: "Find One at the Internet Archive")),
                          .init(title: String(localized: "Choose the ROM File…"), role: .primary)])
            guard let answer = await ask(question), answer.action != 0 else { throw WrappBuildError.userCancelled }
            if answer.action == 1 {
                if let page = URL(string: Self.macROMPage) { NSWorkspace.shared.open(page) }
                continue
            }
            let panel = NSOpenPanel()
            panel.message = String(localized: "Choose the ROM file of an old Mac.")
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            if let url = await runOpenPanel(panel) { return url }
        }
        throw WrappBuildError.userCancelled
    }

    /// Where a Mac's ROM can be had: the Internet Archive's copy of a
    /// Quadra 800's.
    static let macROMPage = "https://archive.org/details/800_20250604"

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

        let question = Self.steamGameQuestion(games)
        guard let answer = await ask(question), answer.action == 1, let chosen = answer.choice else {
            // The first question the user is asked: back to the welcome screen.
            throw cancelledBeforeStart()
        }
        return games[chosen]
    }

    /// Which free game to download: `DOWNLOAD_PROGRAM` (a bundle id,
    /// `freeware/skifree`, or a game's id), else asked from the list.
    @MainActor
    func chooseDownload(from editions: [ShippedBundles.DownloadEdition]) async throws -> ShippedBundles.DownloadEdition {
        if let wanted = environment["DOWNLOAD_PROGRAM"] {
            guard let edition = editions.first(where: { $0.game.programID == wanted || $0.game.id == wanted }) else {
                throw WrappBuildError.invalidPath("DOWNLOAD_PROGRAM \(wanted) has no download edition; there are: "
                    + editions.map(\.game.programID).joined(separator: ", "))
            }
            return edition
        }
        if isHeadlessRun { throw WrappBuildError.missingRequiredParameter("DOWNLOAD_PROGRAM") }
        guard !editions.isEmpty else { throw WrappBuildError.internalError("No shipped bundle has a download edition") }

        let question = Question(
            title: String(localized: "Which game do you want?"),
            detail: String(localized: "These games are free: their makers give them away. Second Chance downloads the one you pick."),
            choicesLabel: String(localized: "Games"),
            choices: editions.map { .init(title: $0.game.title) },
            actions: Self.cancelOrContinue,
            step: .source)
        guard let answer = await ask(question), answer.action == 1, let chosen = answer.choice else {
            // The first question the person is asked: back to the welcome screen.
            throw cancelledBeforeStart()
        }
        return editions[chosen]
    }

    /// Whether to install the game of an app that is already up to date
    /// again, from the start: returns when the person says so, and throws
    /// `userCancelledBeforeStart` when they don't. A headless run has nobody
    /// to ask, so it stops, saying the app is up to date.
    @MainActor
    func confirmReinstall(_ game: GameInfo, source: WrappSource) async throws {
        if isHeadlessRun { throw WrappBuildError.alreadyUpToDate(title: game.title) }
        // Whole sentences for each, so each translates whole.
        let detail = switch source {
        case .disk: String(localized: "There's nothing new for it. You can install the game again from the start, which needs its discs.")
        case .herDownload: String(localized: """
            There's nothing new for it. You can install the game again from the start, which needs the file \
            you downloaded from Her Interactive.
            """)
        case .steam: String(localized: "There's nothing new for it. You can install the game again from the start, from Steam.")
        case .bigFish: String(localized: "There's nothing new for it. You can install the game again from the start, from Big Fish Games.")
        case .download: String(localized: "There's nothing new for it. You can install the game again from the start, by downloading it again.")
        }
        let question = Question(
            title: String(localized: "The app for \(game.title) is already up to date"),
            detail: detail,
            actions: [.init(title: String(localized: "Cancel"), role: .cancel),
                      .init(title: String(localized: "Install Again"), role: .primary)])
        guard await ask(question)?.action == 1 else {
            // Nothing has changed yet: back to the welcome screen.
            throw cancelledBeforeStart()
        }
    }

    /// Tell the person why the game is free and where it comes from before
    /// it downloads. A headless run has nobody to tell, and goes ahead.
    @MainActor
    func confirmDownload(_ notice: DownloadNotice) async throws {
        if isHeadlessRun { return }
        let question = Question(
            title: notice.title, detail: notice.body,
            actions: [.init(title: String(localized: "Cancel"), role: .cancel),
                      .init(title: String(localized: "Download"), role: .primary)],
            step: .source)
        guard await ask(question)?.action == 1 else {
            // Nothing has been downloaded yet: back to the welcome screen.
            throw cancelledBeforeStart()
        }
    }

    /// The values `SECOND_CHANCE_INPUTS` gives the edition's inputs, by name
    /// (`{"launch-mode":"steam"}`): JSON, as an environment variable's name
    /// can't keep an input's case and hyphens.
    func inputs() throws -> [String: String] {
        guard let json = environment["SECOND_CHANCE_INPUTS"], !json.isEmpty else { return [:] }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] else {
            throw WrappBuildError.invalidPath("SECOND_CHANCE_INPUTS must be a JSON object of names to text, not \(json)")
        }
        return parsed
    }

    /// How a DRM-free Steam game should start. Only asked when the game
    /// offers the choice; the engine behind each answer is not the user's
    /// concern, so the question is about what they'll notice.
    @MainActor
    func getSteamLaunchMode(for game: GameInfo) async throws -> String {
        let modes = ["direct", "steam"]
        if let value = try inputs()["launch-mode"] ?? environment["STEAM_LAUNCH_MODE"] {
            guard modes.contains(value.lowercased()) else {
                throw WrappBuildError.invalidPath("STEAM_LAUNCH_MODE must be steam or direct, not \(value)")
            }
            return value.lowercased()
        }
        if isHeadlessRun { return "direct" }

        let question = Self.launchModeQuestion(for: game)
        guard let answer = await ask(question), answer.action == 1, let chosen = answer.choice else {
            // Nothing is installed yet: back to the welcome screen.
            throw cancelledBeforeStart()
        }
        return modes[chosen]
    }

    /// Whether a person is there to sign in to Steam if it asks.
    var canSignInToSteam: Bool { !isHeadlessRun }

    /// What to do about another game holding Steam: quit it, try again, or
    /// give up. Nil in a headless run, which can't ask and fails instead.
    @MainActor
    func askAboutSteamInUse(_ holder: SteamLockHolder) async -> SteamLockHolder.Choice? {
        if isHeadlessRun { return nil }
        let prompt = holder.prompt(blocked: String(localized: "The game you're adding can't be installed until it quits."))
        let question = Question(
            title: prompt.title, detail: prompt.detail,
            actions: prompt.buttons.map {
                .init(title: $0.title, role: $0.destructive ? .destructive : $0.choice == .tryAgain ? .primary : $0.choice == .cancel ? .cancel : .other)
            })
        guard let answer = await ask(question) else { return .cancel }
        return prompt.buttons[answer.action].choice
    }

    /// Whether the person has asked, from the progress screen's notice that
    /// Steam is stuck signing in, to sign in to Steam afresh. Taking it
    /// clears it, so the next call says no. Never in a headless run.
    @MainActor
    func takeSteamSignInAfreshRequest() -> Bool {
        guard let viewModel, !isHeadlessRun else { return false }
        defer { viewModel.steamSignInAfreshRequested = false }
        return viewModel.steamSignInAfreshRequested
    }

    /// The Big Fish game `BIG_FISH_GAME_SLUG` names, or nil when it isn't
    /// set; a headless run must set it, as there's no one to ask.
    func bigFishGameFromEnvironment(among games: [GameInfo]) throws -> GameInfo? {
        guard let slug = environment["BIG_FISH_GAME_SLUG"] else {
            if isHeadlessRun { throw WrappBuildError.missingRequiredParameter("BIG_FISH_GAME_SLUG") }
            return nil
        }
        guard let game = games.first(where: { $0.id == slug && $0.isOnBigFish }) else {
            throw WrappBuildError.invalidPath("BIG_FISH_GAME_SLUG \(slug) isn't a game on Big Fish Games")
        }
        return game
    }

    /// Build the free trial of the game named by `BIG_FISH_GAME_SLUG` rather
    /// than the full game: no sign-in, no library. For the integration tests,
    /// which can then try every game Big Fish sells.
    var isBigFishTrial: Bool { environment["BIG_FISH_TRIAL"] == "1" }

    /// The test harness's Big Fish account, for a headless build to sign in
    /// with (`BIG_FISH_TEST_SIGN_IN=1` with `BIG_FISH_EMAIL` and
    /// `BIG_FISH_PASSWORD`). Nil otherwise: a person signs in themselves.
    var bigFishTestSignIn: (email: String, password: String)? {
        guard environment["BIG_FISH_TEST_SIGN_IN"] == "1",
              let email = environment["BIG_FISH_EMAIL"], !email.isEmpty,
              let password = environment["BIG_FISH_PASSWORD"], !password.isEmpty else { return nil }
        return (email, password)
    }

    /// Whether a person is there to sign in to Big Fish's Game Manager.
    var canSignInToBigFish: Bool { !isHeadlessRun }

    /// Which of the games the signed-in Big Fish account owns to build, each
    /// edition it owns a choice of its own. Asked once it has signed in.
    @MainActor
    func chooseBigFishGame(from owned: [BigFishGameChoice]) async throws -> BigFishGameChoice {
        if isHeadlessRun { throw WrappBuildError.missingRequiredParameter("BIG_FISH_GAME_SLUG") }
        let question = Question(
            title: String(localized: "Which game do you want from Big Fish Games?"),
            detail: String(localized: """
                These are the Nancy Drew games your Big Fish Games account has. \
                Second Chance installs the one you pick through Big Fish's Game Manager.
                """),
            choicesLabel: String(localized: "Games"),
            choices: owned.map { .init(title: $0.displayName) },
            actions: Self.cancelOrContinue,
            step: .source,
            comesToFront: true)
        guard let answer = await ask(question), answer.action == 1, let chosen = answer.choice else {
            // The first question the person is asked: back to the welcome screen.
            throw cancelledBeforeStart()
        }
        return owned[chosen]
    }

    // MARK: - Output Choices

    /// Where to save the finished wrapp: the app's full path. An app already
    /// there is replaced (`saveWrapp`), after asking, in the GUI.
    ///
    /// This is asked once the game is installed, so cancelling the panel
    /// doesn't throw the install away at once: the person is asked whether
    /// to choose a place again or start over.
    @MainActor
    func getSaveLocation(for gameInfo: GameInfo) async throws -> URL {
        if let path = environment["OUTPUT_PATH"] {
            let url = URL(fileURLWithPath: path)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                logger.error("Couldn't make the output folder \(url.path): \(error.localizedDescription)")
                throw WrappBuildError.saveFailed(destination: url.path, reason: error.localizedDescription)
            }
            return url.appendingPathComponent(gameInfo.appBundleName)
        }

        while true {
            guard let folder = await chooseOutputFolder(for: gameInfo) else {
                if await askChooseAgainOrStartOver(gameInfo) { continue }
                throw WrappBuildError.userCancelled
            }
            let destination = folder.appendingPathComponent(gameInfo.appBundleName)
            if FileManager.default.fileExists(atPath: destination.path), !askToReplace(destination, gameInfo) {
                continue
            }
            return destination
        }
    }

    @MainActor
    private func chooseOutputFolder(for gameInfo: GameInfo) async -> URL? {
        let panel = NSOpenPanel()
        panel.message = String(localized: """
            Choose where to save the app for \(gameInfo.title). \
            Your Applications folder is a good place: you'll find it there with your other apps.
            """)
        panel.prompt = String(localized: "Save Here")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = Self.defaultOutputFolder()
        // The panel holds its delegate weakly.
        let validator = WritableFolderValidator()
        panel.delegate = validator

        let url = await runOpenPanel(panel)
        withExtendedLifetime(validator) {}
        return url
    }

    /// The save panel was cancelled with the game installed: true to choose
    /// a place again, false to start over and throw the install away.
    @MainActor
    private func askChooseAgainOrStartOver(_ gameInfo: GameInfo) async -> Bool {
        let question = Question(
            title: String(localized: "\(gameInfo.title) is installed, but not saved yet"),
            detail: String(localized: "Choose where to save the game's app to keep it. Starting over throws away the game that was just installed."),
            actions: [.init(title: String(localized: "Start Over"), role: .destructive),
                      .init(title: String(localized: "Choose Where to Save…"), role: .primary)])
        return await ask(question)?.action == 1
    }

    /// The game's app is already at `destination`: true to replace it,
    /// false to choose somewhere else. A copy that's open is asked about
    /// until it has been quit, since replacing it would pull the game out
    /// from under the player.
    @MainActor
    private func askToReplace(_ destination: URL, _ gameInfo: GameInfo) -> Bool {
        while true {
            let isOpen = NSWorkspace.shared.runningApplications.contains {
                $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "\(gameInfo.appName) is already in \(FileManager.default.displayName(atPath: destination.deletingLastPathComponent().path))")
            alert.informativeText = isOpen
                ? "It's open right now. Quit it, then click Replace to put the new one in its place. Your saved games are kept."
                : "Replace it with the one just installed? Your saved games are kept."
            alert.addButton(withTitle: String(localized: "Replace"))
            alert.addButton(withTitle: String(localized: "Choose Another Place"))
            guard alert.runModalAskingForAttention() == .alertFirstButtonReturn else { return false }
            let stillOpen = NSWorkspace.shared.runningApplications.contains {
                $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL
            }
            if !stillOpen { return true }
        }
    }

    /// /Applications, or for someone who isn't an administrator, and so can't
    /// add apps there, the Applications folder in their home folder.
    private static func defaultOutputFolder() -> URL {
        let shared = URL(fileURLWithPath: "/Applications")
        if FileManager.default.isWritableFile(atPath: shared.path) { return shared }
        let own = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        do {
            try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        } catch {
            logger.warning("Couldn't make \(own.path) to offer instead of /Applications: \(error.localizedDescription)")
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return own
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
    /// The error itself is only logged: the person is told what the patch
    /// would have fixed, in Her Interactive's words, not why it failed.
    @MainActor
    func confirmPatchFailure(_ patch: GamePatch, error: Error) async -> Bool {
        switch environment["PATCH_FAILURE_POLICY"]?.lowercased() {
        case "continue": return true
        case "cancel": return false
        default: break
        }

        if isHeadlessRun { return true }

        let question = Question(
            title: String(localized: "A fix for the game couldn't be added"),
            detail: String(localized: """
                Her Interactive made a fix for this game, "\(patch.title)", and Second Chance couldn't add it. \
                The game will still work without it. What it fixes:

                \(patch.fixes)
                """),
            actions: [.init(title: String(localized: "Stop Installing"), role: .cancel),
                      .init(title: String(localized: "Continue Without It"), role: .primary)])
        return await ask(question)?.action == 1
    }

    /// What to do with a disc or download whose game wasn't recognised.
    enum UnrecognisedGameChoice {
        case installAnyway
        /// Choose another disc or download, and detect again.
        case chooseAnother
    }

    /// The disc or download isn't a game Second Chance recognises: perhaps
    /// the wrong disc, or a game it doesn't know. It can still be installed,
    /// as Other, if the person wants it to be; cancelling goes back to the
    /// welcome screen, as nothing has been built yet. A headless run
    /// installs it anyway, as one always has.
    @MainActor
    func askAboutUnrecognisedGame(_ source: WrappSource) async throws -> UnrecognisedGameChoice {
        if isHeadlessRun { return .installAnyway }

        let what = source == .disk ? "disc" : "download"
        // Whole sentences for each, so each translates whole.
        let question = Question(
            title: String(localized: "Second Chance doesn't recognise this game"),
            detail: source == .disk
                ? String(localized: """
                    It may be the wrong disc, or a game Second Chance doesn't know. \
                    You can choose another disc, or install it anyway, though it may not work.
                    """)
                : String(localized: """
                    It may be the wrong download, or a game Second Chance doesn't know. \
                    You can choose another download, or install it anyway, though it may not work.
                    """),
            actions: [.init(title: String(localized: "Install Anyway")),
                      .init(title: String(localized: "Cancel"), role: .cancel),
                      .init(title: source == .disk ? String(localized: "Choose Another Disc…") : String(localized: "Choose Another Download…"),
                            role: .primary)])
        switch await ask(question)?.action {
        case 2:
            logger.notice("Unrecognised game: choosing another \(what)")
            return .chooseAnother
        case 0:
            logger.notice("Unrecognised game: installing it anyway")
            return .installAnyway
        default:
            logger.notice("Unrecognised game: cancelled")
            throw cancelledBeforeStart()
        }
    }

    enum UnidentifiedInstallerChoice: Equatable {
        /// Try installing the game with this program from the disc.
        case tryProgram(String)
        /// Choose another disc, and start again with it.
        case chooseAnother
    }

    /// The disc has no installer by any name Second Chance knows, only other
    /// programs (`GameDetector.installerLookup`): perhaps a special edition, or
    /// one in another language. The person can try one of them, choosing which
    /// when there are several, or another disc; cancelling goes back to the
    /// welcome screen. A headless run tries the first, as one always has.
    @MainActor
    func askAboutUnidentifiedInstaller(programs: [String]) async throws -> UnidentifiedInstallerChoice {
        guard let first = programs.first else { throw WrappBuildError.installerNotFound }
        if isHeadlessRun {
            logger.warning("No installer recognised on the disc: trying \(first)")
            return .tryProgram(first)
        }

        // With several, which to try is picked from a list.
        let question = Question(
            title: String(localized: "Second Chance couldn't find this disc's installer"),
            detail: String(localized: """
                It may be a disc Second Chance doesn't know, such as a special edition or one in another language. \
                You can choose another disc, or try a program on it to install the game, though it may not work.
                """),
            choicesLabel: String(localized: "Which program should it try?"),
            choices: programs.count > 1 ? programs.map { .init(title: $0) } : [],
            actions: [.init(title: String(localized: "Choose Another Disc…")),
                      .init(title: String(localized: "Cancel"), role: .cancel),
                      .init(title: String(localized: "Try It"), role: .primary)])
        let answer = await ask(question)
        switch answer?.action {
        case 2:
            let program = answer?.choice.map { programs[$0] } ?? first
            logger.notice("No installer recognised: trying \(program)")
            return .tryProgram(program)
        case 0:
            logger.notice("No installer recognised: choosing another disc")
            return .chooseAnother
        default:
            logger.notice("No installer recognised: cancelled")
            throw cancelledBeforeStart()
        }
    }

    /// Which of the programs the install left is the game, when it isn't
    /// where the game's details say and more than one is new. `programs`
    /// comes ranked, likeliest first (`GameInstallerRunner.rankedGamePrograms`),
    /// and the list starts on the first. A headless run takes that one.
    @MainActor
    func chooseGameProgram(among programs: [String]) async throws -> String {
        guard let first = programs.first else { throw WrappBuildError.gameExecutableNotFound }
        if isHeadlessRun {
            logger.warning("More than one program could be the game: using \(first)")
            return first
        }

        let question = Question(
            title: String(localized: "Which program starts the game?"),
            detail: String(localized: "The game installed several programs, and Second Chance can't tell which one is the game. The likeliest is chosen for you."),
            choicesLabel: String(localized: "Programs"),
            choices: programs.map { .init(title: $0) },
            actions: Self.cancelOrContinue)
        guard let answer = await ask(question), answer.action == 1, let index = answer.choice else {
            logger.notice("Choosing the game's program: cancelled")
            throw WrappBuildError.userCancelled
        }
        let chosen = programs[index]
        logger.notice("Chosen as the game's program: \(chosen)")
        return chosen
    }

    /// Make sure this Mac can run Wine before the build asks for anything:
    /// without Rosetta every Wine program fails. When it's missing, the
    /// person is offered it (macOS then asks for an administrator's
    /// password); declining goes back to the welcome screen, as nothing has
    /// been built yet. A headless run fails, saying how to install it.
    @MainActor
    func ensureRosetta(bus: EventBus<AppEvent>) async throws {
        guard await !Rosetta.isInstalled() else { return }
        if isHeadlessRun { throw WrappBuildError.rosettaMissing }

        let alert = NSAlert()
        alert.messageText = String(localized: "Second Chance needs Rosetta")
        alert.informativeText = String(localized: """
            The games were made for Windows, and what lets them run on this Mac needs Rosetta, a free part of macOS from Apple. \
            Installing it takes a minute or two, and means agreeing to Apple's licence for it. Your Mac will ask for your password.
            """)
        alert.addButton(withTitle: String(localized: "Install Rosetta"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModalAskingForAttention() == .alertFirstButtonReturn else {
            logger.notice("Rosetta is missing, and the person chose not to install it")
            throw cancelledBeforeStart()
        }

        await bus.publishWrappBuild(.progress(.settingUpWrapp(substep: String(localized: "Installing Rosetta"))))
        let outcome = await Rosetta.install()
        // Back to the welcome screen, where the source's prompts appear.
        await bus.publishWrappBuild(.progress(.idle))
        switch outcome {
        case .installed: return
        case .cancelled: throw cancelledBeforeStart()
        case .failed: throw WrappBuildError.rosettaInstallFailed
        }
    }

    /// Whether to send success reports, asked once, after the first build
    /// that worked: it's a question about games that work, and by then the
    /// person has seen one. The main window asks it, in place of the
    /// build's progress. Not asked in a headless run or one that can't
    /// report, nor once answered: Settings changes it after that.
    @MainActor
    func askAboutSuccessReports() async {
        guard let viewModel, !isHeadlessRun, FailureReporter.isEnabled,
              ReportingPreferences.load().successReports == nil else { return }
        await viewModel.askAboutSuccessReports()
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
    /// The build is done: bounce the Dock icon if the person has gone off
    /// to do something else. The completion page offers to play it and to
    /// show it in the Finder; nothing opens over it.
    func onWrappBuildComplete(_ wrappPath: URL) async {
        guard viewModel != nil, !isHeadlessRun else { return }
        await MainActor.run { NSApp.askForAttention() }
    }

    // MARK: - Env Helpers

    /// True when any disk path was env-supplied — used to detect headless runs
    /// where prompts must never appear.
    private var anyDiskPathFromEnv: Bool {
        environment["DISK_1_PATH"] != nil
    }

    /// Whether nobody is there to answer the installer's own wizard: a
    /// headless run. The installer runner asks this rather than reading the
    /// environment itself, so the two never disagree.
    var isUnattended: Bool { isHeadlessRun }

    /// True when running headless (any build input env var set or the
    /// NON_INTERACTIVE flag present).
    private var isHeadlessRun: Bool {
        anyDiskPathFromEnv || environment["HER_INSTALLER_PATH"] != nil
            || environment["STEAM_GAME_SLUG"] != nil || environment["BIG_FISH_GAME_SLUG"] != nil
            || environment["BIG_FISH_TRIAL"] != nil || environment["DOWNLOAD_PROGRAM"] != nil
            || environment["NON_INTERACTIVE"] == "true"
    }

    /// Resolve a disk path (a folder, or any file, which is mounted as a disc
    /// image) from an env var with validation.
    private func diskPathFromEnv(_ name: String, label: String) throws -> URL? {
        guard let path = environment[name] else { return nil }
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WrappBuildError.invalidPath("\(label) path does not exist: \(path)")
        }

        return url
    }

    // MARK: - Panel Helpers

    @MainActor
    /// Turns down a folder the game's app can't be saved in while the panel
    /// is still open: found only once the build had finished, it lost the
    /// whole install.
    final class WritableFolderValidator: NSObject, NSOpenSavePanelDelegate {
        func panel(_ sender: Any, validate url: URL) throws {
            guard !FileManager.default.isWritableFile(atPath: url.path) else { return }
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [
                NSLocalizedDescriptionKey: "You can't save in “\(FileManager.default.displayName(atPath: url.path))”.",
                NSLocalizedRecoverySuggestionErrorKey: "Your Mac account doesn't have permission to add things there. "
                    + "Choose another folder, such as the Applications folder in your home folder.",
            ])
        }
    }

    private func runOpenPanel(_ panel: NSOpenPanel) async -> URL? {
        // A sheet on Second Chance's own window, never on Settings or the
        // log window, whichever happens to be key.
        NSApp.askForAttention()
        let response: NSApplication.ModalResponse
        if let window = NSApp.installerWindow {
            response = await panel.beginSheetModal(for: window)
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
        // A game's app is a hidden extra, as disc images are: updating it
        // from itself (UpdateWrappBuilder) until it is a source of its own.
        panel.allowedContentTypes = [.folder, .applicationBundle] + [UTType(filenameExtension: "iso")].compactMap { $0 }
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
