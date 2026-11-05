//
//  NancyDrewQuitScenario.swift
//  WrappPuppeteer
//
//  Launch a Nancy Drew wrapp, get it to the main menu, and quit through the
//  game's own Exit button — proving the game starts and responds to input.

import Foundation
import AppKit
import CoreGraphics
import Logging
import SecondChanceKit
import PuppeteerCore
import WrappBuilder

struct NancyDrewQuitScenario {
    struct Options {
        // The waits are sized for a machine with every core busy, where Wine
        // runs many times slower than on an idle one; each ends as soon as
        // what it waits for happens, so they only cost time on a failure.

        /// How long to wait for the game's window once its process is up.
        var windowDetectTimeout: TimeInterval = 300
        /// How long to wait for the game's process to appear. A Wine wrapp
        /// waits up to 600 s for Wine's desktop before it starts the game
        /// (`GameLauncher.prepareDesktop`), so this has to outlast that.
        var processDetectTimeout: TimeInterval = 900
        var infoWindowTimeout: TimeInterval = 60
        /// How long the info window may stay up once the game's window is.
        /// The wrapp closes it as soon as it sees that window, so this is
        /// only slack for a loaded machine.
        var infoWindowCloseTimeout: TimeInterval = 30
        /// How long the game's window may take to go fullscreen once it
        /// has focus. Native fullscreen waits for the window to settle
        /// first, which on a loaded machine can take a while.
        var fullScreenTimeout: TimeInterval = 120
        var quitTimeout: TimeInterval = 300
        /// How long the wrapp's cursor lock may take to finish before the
        /// first click. It waits up to 100 s for the window to settle, then
        /// spends up to ~35 s on middle clicks.
        var cursorLockSettleTimeout: TimeInterval = 180
        /// The most the whole run may take (`ProcessCleanup.limitRuntime`):
        /// above the phases' own limits added up, so only a wedged run meets it.
        var maxRuntime: TimeInterval = 2700
        /// Launch the wrapp with `--debug`
        var debugMode = false
        /// Record the game window into this directory from when it appears
        /// until the run ends — for seeing what a game shows before its menu,
        /// and what the clicks did (`--record`).
        var recordDirectory: URL?
        /// Click nothing: record for this long, then quit (`--record-seconds`).
        var watchOnlySeconds: TimeInterval?
        /// While only watching: when to click the game, in seconds from its
        /// window going fullscreen, to see what a click skips.
        var watchClicks: [TimeInterval] = []
        /// Once at the menu, quit through the game's Quit menu item (⌘⌥Q)
        /// rather than its Exit button (`--quit-from-menu`).
        var quitFromMenu = false
        /// How long the game may take to close once asked to from its menu:
        /// the wrapp waits for Wine, which takes seconds.
        var menuQuitTimeout: TimeInterval = 60
    }

    let wrapp: Wrapp
    let options: Options
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.NancyDrewQuitScenario")

    func run() -> PuppetResult {
        logger.notice("🎮 Starting Nancy Drew quit scenario")
        logger.notice("   App: \(wrapp.appPath)")
        logger.notice("   Engine: \(wrapp.engineSetting)")
        logger.notice("   Executable: \(wrapp.gameExeName)")
        if wrapp.runsInWine {
            logger.notice("   Wine prefix: \(wrapp.winePrefix.path)")
        }
        logger.notice("   Max runtime: \(Int(options.maxRuntime))s")

        ProcessCleanup.install(cleanupCommands: wrapp.cleanupCommands)

        // What to do once the game is up: its bundle's scenario, parameters
        // and needles (docs/testing.md#scenarios).
        let program = TestData.program(of: wrapp)
        let test: ProgramTest
        do {
            test = try TestData.test(forProgram: program)
        } catch {
            return .failed("Couldn't read \(program)'s test: \(error)")
        }

        // The wrapp and the game serve their windows on sockets here
        // (docs/wine-in-process-helpers.md#puppet-control).
        guard let directory = makeControlDirectory() else {
            return .failed("Couldn't create a directory for the wrapp's control sockets")
        }
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let wrappSocket = ControlSocket(path: directory + "/wrapp.sock")

        // Saves and settings go in here too, gone with it, not the player's
        // (WrappTemplate/Configuration.swift): one the player set to play
        // in a window would fail the fullscreen check, and a test mustn't
        // change theirs.
        // A game started with the cursor at the top of the screen has its
        // fullscreen window's title bar showing until the mouse moves, over
        // the top of every capture (docs/testing.md). The middle of the left
        // edge is in the bar beside the picture on a widescreen display, so
        // a game that draws its own cursor doesn't draw it over the splash
        // screens, and is clear of the menu bar, the Dock and hot corners.
        // Moving the cursor needs no permission; all the test's clicks go
        // through the game's socket, so nothing moves it back.
        let screen = CGDisplayBounds(CGMainDisplayID())
        CGWarpMouseCursorPosition(CGPoint(x: screen.minX + 2, y: screen.midY))

        let environment = ["SECOND_CHANCE_PUPPET_DIR": directory, "SECOND_CHANCE_APP_SUPPORT_DIR": directory + "/data"]
        let launchedAt = Date()
        guard let app = ProcessControl.launch(appPath: wrapp.appPath, arguments: options.debugMode ? ["--debug"] : [],
                                              environment: environment) else {
            return .failed("Failed to launch game")
        }
        ProcessCleanup.track(appPid: app.processIdentifier, helperPid: nil)

        let appName = app.localizedName ?? "WrappTemplate"
        logger.notice("ℹ️  Game process: \(appName) (PID: \(app.processIdentifier))")

        if wrapp.runsInWine {
            logger.notice("ℹ️  Wine game - checking for info window...")
            Thread.sleep(forTimeInterval: 1)
            guard InfoWindow.dismiss(wrapp: wrappSocket, timeout: options.infoWindowTimeout) else {
                forceQuit(app)
                return .failed("Failed to dismiss info window")
            }
        }

        let gamePid: Int32
        switch waitForGameWindow(launchedAt: launchedAt) {
        case .found(let pid, _):
            gamePid = pid
        case .failed(let reason):
            forceQuit(app)
            return .failed(reason)
        }

        logger.notice("ℹ️  Game process PID: \(gamePid)")
        ProcessCleanup.track(appPid: app.processIdentifier, helperPid: gamePid)
        // Each process the helper is in serves on a socket of its own: a game
        // that runs as two processes, as Armadillo's do, has it in both, and
        // the one to talk to is the one with the window.
        let game = WindowControl(socket: ControlSocket(path: directory + "/game-\(gamePid).sock"))
        let context = Context(directory: directory, wrapp: wrappSocket, game: game)

        // The game refuses captures until its window is in its fullscreen
        // Space, so the frames start there.
        let recorder = options.recordDirectory.map { WindowRecorder(window: game, directory: $0, interval: 0.25) }
        let recordingStart = Date()
        recorder?.start()
        defer { recorder?.stop() }

        // Checked before waiting for focus: a wrapp that missed the game
        // starting leaves "Loading…" over the game until it exits, and never
        // brings the game to the front either, so the focus wait would fail
        // first and hide the cause.
        guard InfoWindow.waitForClose(wrapp: wrappSocket, timeout: options.infoWindowCloseTimeout) else {
            optionalScreenshot(prefix: "info-window-still-open")
            forceQuit(app)
            return .failed("The wrapp's info window was still open \(Int(options.infoWindowCloseTimeout))s after the game's window appeared")
        }

        switch waitForGameFocus(pid: gamePid, context: context) {
        case .focused:
            break
        case .timedOut:
            forceQuit(app)
            return .failed("Game window did not become active in time")
        case .blocked(let reason):
            forceQuit(app)
            return .failed("Game window couldn't become active: \(reason)")
        }

        // Every wrapp opens its game fullscreen: native fullscreen for Wine,
        // `-f` for ScummVM. A game left in a window still plays, so nothing
        // else here would notice.
        guard waitForFullScreen(context: context) else {
            forceQuit(app)
            return .failed("Game window did not go into a fullscreen Space within \(Int(options.fullScreenTimeout))s")
        }

        if let seconds = options.watchOnlySeconds {
            let fullscreenAt = Date()
            for at in options.watchClicks {
                let wait = at - Date().timeIntervalSince(fullscreenAt)
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                // Inside a 4:3 picture on a wide screen, near its top-left
                // corner, where no menu has a button: as a splash's click is.
                guard let size = context.game.state()?.size else { continue }
                let point = CGPoint(x: size.width * 0.2, y: size.height * 0.12)
                logger.notice("🖱️  [\(String(format: "%.1f", Date().timeIntervalSince(fullscreenAt)))s after fullscreen] Clicking at \(Int(point.x)),\(Int(point.y))")
                context.game.click(at: point)
            }
            let remaining = seconds - Date().timeIntervalSince(recordingStart)
            logger.notice("🎥 Watching for another \(Int(max(remaining, 0)))s\(options.watchClicks.isEmpty ? ", clicking nothing" : "")...")
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            forceQuit(app)
            return .passed
        }

        if let failure = runHandlers(test: test, app: app, gamePid: gamePid, context: context) {
            return .failed(failure)
        }

        logger.notice("⏳ Waiting for game to exit...")
        let quitTimeout = options.quitFromMenu ? options.menuQuitTimeout : options.quitTimeout
        if ProcessControl.waitForTermination(app, helperPid: gamePid, timeout: quitTimeout) {
            logger.notice("✅ Game exited cleanly")
            return .passed
        }
        // Wine's Quit has hung for good before (with the game's process made
        // an accessory app), stuck in -[NSApplication terminate:].
        if options.quitFromMenu {
            logger.error("❌ Quitting from the game's menu didn't close it within \(Int(quitTimeout))s")
            diagnosticCapture(context, prefix: "menu-quit")
            forceQuit(app)
            return .failed("Quitting from the game's menu (as ⌘⌥Q does) didn't close the game within \(Int(quitTimeout))s")
        }

        logger.warning("⚠️  Game did not exit cleanly, force quitting...")
        forceQuit(app)
        Thread.sleep(forTimeInterval: 2)
        if app.isTerminated {
            logger.notice("✅ Game force-quit successful")
            return .forcedQuit
        }
        return .failed("Failed to quit game even after force-quit")
    }

    // MARK: - Private

    /// The control sockets for this run.
    private struct Context {
        let directory: String
        let wrapp: ControlSocket
        let game: WindowControl
    }

    /// A private directory for the sockets, short enough for a socket's path.
    private func makeControlDirectory() -> String? {
        let directory = "/tmp/wrapp-puppeteer-\(getpid())"
        try? FileManager.default.removeItem(atPath: directory)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            return directory
        } catch {
            logger.critical("❌ Couldn't create \(directory): \(error.localizedDescription)")
            return nil
        }
    }

    private func focusStrategy(_ context: Context) -> FocusStrategy {
        wrapp.judgesFocusByFullscreen ? .reportsFullscreen({ context.game.state()?.fullscreen == true }) : .frontmost
    }

    /// Capture the game window, through the game, into /tmp for diagnosing a
    /// failure later, and log where. The integration test attaches every
    /// capture logged with 📸 to its results.
    private func diagnosticCapture(_ context: Context, prefix: String) {
        let path = "/tmp/\(prefix)-window-\(Int(Date().timeIntervalSince1970)).png"
        if context.game.capture(to: path) != nil {
            logger.notice("📸 Game window: \(path)")
        }
    }

    /// A screenshot of the whole screen, which shows what else was in front —
    /// but only if WrappPuppeteer happens to have Screen Recording, which it
    /// doesn't need. Named apart from `diagnosticCapture`'s, which is often
    /// taken in the same second.
    private func optionalScreenshot(prefix: String) {
        guard CGPreflightScreenCaptureAccess() else {
            logger.notice("No full-screen screenshot: WrappPuppeteer doesn't have Screen Recording")
            return
        }
        if let path = ScreenCapture.captureScreen(prefix: "\(prefix)-screen") {
            logger.notice("📸 Full screen screenshot: \(path)")
        }
    }

    /// A warning for the integration test, which records it without failing
    /// the game (`AppPuppetRunner.judge`): something that slows the run or
    /// may stop working, rather than the game not working.
    private func warnForTest(_ text: String) {
        logger.warning("WRAPP_PUPPETEER: warning: \(text)")
    }

    /// Switch away from the game and back as a player would, and say why
    /// that went wrong, or nil. The game hands activation to the Finder,
    /// which is then activated, as Cmd-Tab to it does, so macOS slides off the
    /// game's fullscreen Space to the desktop; then WrappPuppeteer opens the
    /// wrapp as a click on its Dock icon does. The game has to be active
    /// again within `switchBackSeconds`: a Wine game's process has no Dock
    /// icon of its own, so the wrapp brings it forward. A Direct3D game
    /// whose mode Wine emulates once came back with its picture half a screen
    /// up; the caller checks the frame again once this returns. Not being
    /// able to switch away at all is the test's problem, not the game's, so
    /// it's only warned about.
    private func switchAwayAndBackFailure(_ context: Context, gamePid: Int32) -> String? {
        logger.notice("🔀 Switching away from the game to the Finder, then back by opening the game's app as its Dock icon would...")
        let switched = ProcessControl.switchTo(bundleIdentifier: "com.apple.finder") { pid in
            context.game.yieldActivation(to: pid)
        }
        // Away means inactive and off the screen: the slide to the desktop
        // takes a moment.
        let isAway = { (state: ControlledWindowState?) in state?.active == false && state?.onActiveSpace != true }
        let away = Date().addingTimeInterval(Self.switchBackSeconds)
        while switched, !isAway(context.game.state()), Date() < away {
            ProcessControl.handleEvents(for: 0.2)
        }
        guard context.game.state()?.active == false else {
            warnForTest("Couldn't switch away from the game, so coming back to it through the Dock wasn't checked")
            return nil
        }
        if context.game.state()?.onActiveSpace == true {
            warnForTest("The screen stayed on the game's Space after switching away, so coming back to it wasn't really checked")
        }
        logger.notice("   Switched away; opening the game's app...")
        ProcessControl.reopen(appPath: wrapp.appPath)
        // Back means active and on screen: an app made active needn't take
        // the screen to the Space its window is in. And focused as the rest
        // of the run judges it: a fullscreen window is briefly not, as it
        // moves back into its Space, and the run would take that for
        // something else having taken over the screen.
        let strategy = focusStrategy(context)
        let isBack = { (state: ControlledWindowState?) in
            state?.active == true && state?.onActiveSpace != false && FocusDetector.isFocused(pid: gamePid, strategy: strategy)
        }
        let back = Date().addingTimeInterval(Self.switchBackSeconds)
        while !isBack(context.game.state()), Date() < back {
            ProcessControl.handleEvents(for: 0.2)
        }
        guard isBack(context.game.state()) else {
            logger.error("❌ Opening the game's app, as its Dock icon does, didn't bring the game back within \(Int(Self.switchBackSeconds))s")
            diagnosticCapture(context, prefix: "switch-back")
            optionalScreenshot(prefix: "switch-back")
            return "Clicking the game's app in the Dock didn't bring the game back after switching away"
        }
        logger.notice("   ✓ The game is back in front")
        return nil
    }

    /// How long switching away from the game, or back to it, may take.
    private static let switchBackSeconds: TimeInterval = 15

    /// Light in a bar that comes and goes isn't the picture's framing. The
    /// corner Steam's overlay notice shows in is left out for a game started
    /// through Steam, so it doesn't hold the check up; for anything else
    /// that comes and goes (a cursor, a notice somewhere unexpected), a
    /// capture that fails is taken again, every second, for this long, and
    /// the framing is wrong only if none of them passes.
    private static let pictureFrameRecheckSeconds: TimeInterval = 12

    /// Why the game's picture, in a capture of its menu, is framed wrongly
    /// — light in the bars beside it, either a bar left undrawn or the
    /// picture stretched over it — or nil. A failing capture is taken again
    /// until one passes or `pictureFrameRecheckSeconds` is up; the last one
    /// is kept, and its path logged. `windowSize` is the window's, in points.
    private func pictureFrameFailure(_ context: Context, capturePath: String, windowSize: CGSize) -> String? {
        guard var image = PictureFrameCheck.image(atPath: capturePath) else {
            logger.warning("⚠️  Couldn't read the menu's capture, so the picture's framing wasn't checked")
            return nil
        }
        var ignoring: [CGRect] = []
        if windowSize.width > 0, windowSize.height > 0 {
            // The title bar, should something have brought it up.
            ignoring.append(CGRect(x: 0, y: 0, width: 1, height: min(1, Wrapp.titleBarHeight / windowSize.height)))
            if wrapp.showsSteamOverlay {
                let notice = Wrapp.steamOverlayNoticeSize
                let width = min(1, notice.width / windowSize.width), height = min(1, notice.height / windowSize.height)
                ignoring.append(CGRect(x: 1 - width, y: 1 - height, width: width, height: height))
            }
        }
        let check = { (image: CGImage) in
            PictureFrameCheck.findings(in: image, pictureAspect: Wrapp.pictureAspect, ignoring: ignoring)
        }
        var findings = check(image)
        let deadline = Date().addingTimeInterval(Self.pictureFrameRecheckSeconds)
        if !findings.isEmpty {
            logger.notice("  ⏳ Something light where the picture's bars are — looking again in case it goes away")
        }
        while !findings.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            guard context.game.capture(to: capturePath) != nil,
                  let again = PictureFrameCheck.image(atPath: capturePath) else { continue }
            image = again
            findings = check(image)
        }
        guard !findings.isEmpty else {
            logger.notice("  🖼️  The picture is framed rightly in \(image.width)x\(image.height): nothing light where the bars are")
            return nil
        }
        let described = findings.map { finding in
            if let colour = finding.flatColour {
                return "the \(finding.bar) bar is \(colour), not black"
            }
            let percent = Int((finding.lightFraction * 100).rounded())
            return "the picture reaches into the \(finding.bar) bar (\(percent)% of it isn't dark), so it's stretched or not 4:3"
        }.joined(separator: "; ")
        logger.error("❌ The game's picture is framed wrongly in \(image.width)x\(image.height): \(described)")
        let kept = "/tmp/picture-frame-\(Int(Date().timeIntervalSince1970)).png"
        if (try? FileManager.default.copyItem(atPath: capturePath, toPath: kept)) != nil {
            logger.notice("📸 Game window: \(kept)")
        }
        return "The game's picture is framed wrongly: \(described)"
    }

    /// Show the click ring where a window point is on screen. The game's
    /// window position comes from the on-screen window list, which needs no
    /// permission.
    private func showClick(at point: CGPoint, gamePid: Int32) {
        guard let window = WindowFinder.mainWindow(ofPid: gamePid) else { return }
        InputControl.showClick(at: CGPoint(x: window.bounds.minX + point.x, y: window.bounds.minY + point.y))
    }

    /// End the wrapp, then its engine, each firmly only if it won't go.
    private func forceQuit(_ app: NSRunningApplication) {
        ProcessControl.forceQuit(app) { wrapp.endEngine() }
    }

    private enum GameWindowWait {
        case found(pid: Int32, windows: [WindowInfo])
        case failed(String)
    }

    /// Wait for the game's process, one started since `launchedAt`, then
    /// its window. Found: the game process's PID and its windows.
    private func waitForGameWindow(launchedAt: Date) -> GameWindowWait {
        let processName = wrapp.gameProcessName
        logger.notice("⏳ Waiting for game process (timeout: \(Int(options.processDetectTimeout))s), then its window...")
        let start = Date()
        let timedOut = "Game process or window did not appear in time"

        logger.notice("[Step 1] Monitoring for \(processName) process...")
        guard let process = ProcessFinder.waitForProcess(named: processName, startedSince: launchedAt,
                                                                timeout: options.processDetectTimeout) else {
            return .failed(timedOut)
        }
        var pid = process.pid

        logger.notice("[Step 2] Monitoring for windows from \(processName) (PID: \(pid))...")
        let windowDeadline = Date().addingTimeInterval(options.windowDetectTimeout)
        while true {
            let watched = pid
            // A window of another process of the same exe counts too: a game
            // wrapped in Armadillo (Big Fish's) runs as two, and the window is
            // the second's, the first running it under its own debugger.
            let sameExe: (Int32) -> Bool = { owner in
                ProcessName.executable(ofPID: owner)?.caseInsensitiveCompare(processName) == .orderedSame
            }
            if let windows = WindowFinder.waitForWindows(timeout: windowDeadline.timeIntervalSinceNow,
                                                         where: { $0.ownerPid == watched || sameExe($0.ownerPid) },
                                                         giveUp: { !ProcessControl.isAlive(watched) }) {
                logger.notice("✅ Game window detected after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
                for (index, window) in windows.enumerated() {
                    logger.notice("   [\(index + 1)] \(window.title) - \(Int(window.bounds.width))x\(Int(window.bounds.height))")
                }
                let owner = windows.first?.ownerPid ?? watched
                if owner != watched {
                    logger.notice("   The window is \(processName)'s second process's (PID: \(owner)), not the first's (PID: \(watched))")
                }
                return .found(pid: owner, windows: windows.filter { $0.ownerPid == owner })
            }
            if ProcessControl.isAlive(watched) {
                logger.critical("❌ Timeout: \(processName) process found but no windows appeared")
                WindowFinder.logAllWindows()
                return .failed(timedOut)
            }
            // Gone without a window. A launcher stub (Steam's DRM wrapper,
            // say) can start the exe again, so look briefly for its successor
            // before calling it: waiting out the full window timeout for a
            // process that has already died only delays the failure by minutes.
            logger.warning("⚠️  \(processName) (PID: \(watched)) exited before showing a window; checking whether it started again...")
            if let successor = successor(named: processName, replacing: watched, within: 10),
               windowDeadline.timeIntervalSinceNow > 0 {
                pid = successor.pid
                logger.notice("[Step 2] Monitoring for windows from \(processName) (PID: \(pid))...")
                continue
            }
            logger.critical("❌ \(processName) exited before showing a window")
            return .failed("\(processName) exited before showing a window")
        }
    }

    /// A live process named `name` other than `pid`, if one starts within
    /// `timeout`. `pid` itself can linger in the process list as a zombie.
    private func successor(named name: String, replacing pid: Int32, within timeout: TimeInterval) -> RunningProcess? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = ProcessFinder.allProcesses().first(where: {
                $0.pid != pid && $0.name.lowercased() == name.lowercased() && ProcessControl.isAlive($0.pid)
            }) {
                return match
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    /// Wait for the game's window to take focus.
    private func waitForGameFocus(pid: Int32, context: Context) -> FocusWaitResult {
        logger.notice("[Step 3] Waiting for game to become active...")
        // 120s, not the default 10: on a loaded machine a game's first window
        // can take a while before macOS will bring it in front (Ghost of
        // Thornton Hall's has stayed behind the wrapp for over 10s). No
        // settling once it's focused: everything after polls the screen, and
        // a game's splash screens are only skipped if they're still up.
        let result = FocusDetector.waitForFocus(pid: pid, strategy: focusStrategy(context), activate: wrapp.activatesForFocus,
                                                timeout: 120, settleDelay: 0)
        switch result {
        case .focused:
            NSSound.beep()
            // What was on screen, for diagnosing later failures
            diagnosticCapture(context, prefix: "game-window-detected")
        case .timedOut:
            WindowFinder.logAllWindows()
            optionalScreenshot(prefix: "game-not-focused")
        case .blocked:
            // Nothing on screen but loginwindow, or nothing at all.
            break
        }
        return result
    }

    /// Wait for the game to report its window in a macOS fullscreen Space.
    /// Every engine's game should get one; a Direct3D game's borderless window
    /// merely covering the screen means the wrapp's native fullscreen didn't
    /// take it over, which is a failure. Asked of the game itself, so the
    /// display's shape doesn't come into it (on a display with a notch, a
    /// fullscreen Space's window sits below its strip).
    private func waitForFullScreen(context: Context) -> Bool {
        logger.notice("[Step 4] Waiting for the game's window to go fullscreen...")
        let start = Date()
        var lastLog = Date.distantPast
        var everAnswered = false
        while Date().timeIntervalSince(start) < options.fullScreenTimeout {
            let state = context.game.state()
            if state != nil { everAnswered = true }
            if let state, state.native {
                logger.notice("✅ Game window is in its own fullscreen Space (\(Int(state.size.width))x\(Int(state.size.height)) points, scale \(state.scale))")
                return true
            }
            if Date().timeIntervalSince(lastLog) >= 5 {
                let gameSays = state.map {
                    "\(Int($0.size.width))x\(Int($0.size.height)), native=\($0.native), covering the screen=\($0.fullscreen && !$0.native)"
                } ?? "nothing"
                logger.notice("   [\(Int(Date().timeIntervalSince(start)))s] Not in a fullscreen Space yet (game says: \(gameSays))")
                lastLog = Date()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if everAnswered {
            logger.error("❌ The game's window never went into a fullscreen Space — look for '[Helpers] Native fullscreen' in the wrapp's log")
        } else {
            logger.error("❌ The game never answered on \(context.game.socket.path): its puppet control didn't arm — look for '[Helpers] Puppet control' in the wrapp's log")
        }
        WindowFinder.logAllWindows()
        optionalScreenshot(prefix: "game-not-fullscreen")
        return false
    }

    /// Whether the game held the cursor just before WrappPuppeteer's first
    /// click, once the wrapp's cursor lock has finished: nil for a game that
    /// doesn't say (one built before it could), or whose lock never finished
    /// — the reason, then, in `failure`. A cursor lock that is `off` still
    /// counts: unarmed in a cnc-ddraw game, the first click is swallowed, and
    /// in a ScummVM game nothing ever holds the cursor.
    private func cursorBeforeFirstClick(_ context: Context) -> (held: Bool?, failure: String?) {
        let start = Date()
        var lastLog = Date.distantPast
        while true {
            guard let state = context.game.state() else {
                // A loaded Mac can miss one reply; a game that never answers
                // has bigger problems, which the clicks will show.
                if Date().timeIntervalSince(start) >= 30 {
                    logger.warning("⚠️  The game didn't say whether it held the cursor; not checking the first click")
                    return (nil, nil)
                }
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            switch state.cursorLock {
            case nil:
                return (nil, nil)
            case "waiting":
                if Date().timeIntervalSince(start) >= options.cursorLockSettleTimeout {
                    let waited = Int(options.cursorLockSettleTimeout)
                    return (nil, "The wrapp's cursor lock was still waiting \(waited)s before the first click — see '[CursorLock]' in the wrapp's log")
                }
                if Date().timeIntervalSince(lastLog) >= 10 {
                    logger.notice("  ⏳ Waiting for the wrapp's cursor lock to finish before clicking...")
                    lastLog = Date()
                }
                Thread.sleep(forTimeInterval: 0.5)
            default:
                logger.notice("  ℹ️  Before the first click: cursor lock \(state.cursorLock ?? "?"), cursor \(state.cursorHeld ? "held" : "free")")
                return (state.cursorHeld, nil)
            }
        }
    }

    /// Whether the first click is what got cnc-ddraw to take the cursor —
    /// which it does on the first button release in its window, eating that
    /// click. Only asked when the cursor was free before it. A Direct3D game
    /// never takes it, and a game that quit has nothing to ask.
    private func firstClickWasSwallowed(_ context: Context) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            guard let state = context.game.state() else { return false }
            // The app was deactivated and the cursor lock has started over:
            // a lock now may be its middle click's, not ours.
            if state.cursorLock == "waiting" {
                logger.warning("⚠️  The wrapp's cursor lock started again during the first click; can't tell whether it was swallowed")
                return false
            }
            if state.cursorHeld { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// What a handler's acting came to.
    private enum Outcome {
        /// It acted; look at the screen afresh.
        case acted
        /// It found its needle but did nothing this time.
        case waited
        /// The run is over: nil when it ended as it should, else why not.
        case finished(String?)
    }

    /// Run the scenario's handlers until the game ends (the goal): on every
    /// look at the game's window, each handler that waits for a whole-screen
    /// tag or a blank screen is tried in order, then the window is read for
    /// the rest's needles, which run in order on what was found
    /// (docs/testing.md#scenarios). Nil when the game ended as it should.
    ///
    /// The first click, whichever it is, must reach the game: a Wine game's
    /// cnc-ddraw swallows it unless the wrapp's cursor lock took the cursor
    /// first, and on a splash screen — which any click skips — nothing else
    /// would show it.
    private func runHandlers(test: ProgramTest, app: NSRunningApplication, gamePid: Int32, context: Context) -> String? {
        let scenario = test.scenario
        logger.notice("🎮 Running \(scenario.id): handlers \(scenario.handlers.map(\.id).joined(separator: ", "))")
        let strategy = focusStrategy(context)
        let notFound = "The game's menu, with its Exit, never appeared"

        var firstClickToCheck = wrapp.runsInWine && wrapp.graphics.mayUseCncDdraw
        if wrapp.runsInWine && !firstClickToCheck {
            logger.notice("  ℹ️  \(wrapp.gameExeName) draws with \(wrapp.graphics.logDescription): no cnc-ddraw to swallow its first click")
        }
        /// Click a window point, checking the first click wasn't swallowed;
        /// the failure if it was. Only cnc-ddraw swallows a first click, so
        /// only a Wine game that may draw through it has one to check.
        func click(at point: CGPoint) -> String? {
            var heldBefore: Bool?
            if firstClickToCheck {
                firstClickToCheck = false
                let before = cursorBeforeFirstClick(context)
                if let failure = before.failure { return failure }
                heldBefore = before.held
            }
            context.game.click(at: point)
            showClick(at: point, gamePid: gamePid)
            if heldBefore == false, firstClickWasSwallowed(context) {
                logger.error(
                    "❌ The first click is what took the cursor: cnc-ddraw swallowed it, so the wrapp's cursor lock didn't take hold — see '[CursorLock]' in the wrapp's log"
                )
                diagnosticCapture(context, prefix: "first-click-swallowed")
                return "The game's first click was swallowed: cnc-ddraw took the cursor on it rather than from the wrapp's cursor lock"
            }
            return nil
        }

        let handlers = scenario.handlers.filter { handler in
            let applies = handler.applies(with: scenario.parameters)
            if !applies { logger.notice("  ℹ️  Handler \(handler.id) is off for \(wrapp.gameSlug) (\(handler.condition ?? ""))") }
            return applies
        }
        /// Each whole-screen tag's screens, fingerprinted once.
        var screens: [String: [SplashScreen]] = [:]
        for handler in handlers where handler.when != Self.blankTag {
            let found = SplashScreen.screens(tagged: handler.when, in: test.needles)
            if !found.isEmpty { screens[handler.when] = found }
        }
        let fastHandlers = handlers.filter { $0.when == Self.blankTag || screens[$0.when] != nil }
        let readHandlers = handlers.filter { $0.when != Self.blankTag && screens[$0.when] == nil }
        let readNeedles = readHandlers.flatMap { test.needles.tagged($0.when) }.filter { $0.spec.kind != .screen }
        for (tag, list) in screens.sorted(by: { $0.key < $1.key }) {
            logger.notice("  ℹ️  \(list.count) screen(s) tagged \(tag) for \(wrapp.gameSlug): \(list.map(\.name).joined(separator: ", "))")
        }

        /// What each handler has done so far, by id.
        struct Memory {
            var actedAt = Date.distantPast
            var actedOn: ImageFingerprint?
            var acted = false
            /// Where its needle was last found, in window points.
            var lastSeen: CGPoint?
        }
        var memory: [String: Memory] = [:]
        /// The screens a whole-screen handler recognised, by name, whether
        /// it clicked them or another handler did while it waited on the
        /// cursor lock: none at all, when some are known, is warned about once
        /// the menu is up.
        var screensRecognised: Set<String> = []
        var loggedLockWait: String?
        var ended = false
        var reachedMenu = false
        var switchedAway = false
        let startTime = Date()
        var attempt = 0

        attemptLoop: while Date().timeIntervalSince(startTime) < scenario.timeout {
            attempt += 1
            let iterationStartTime = Date()
            if attempt == 1 { NSSound.beep() }

            // Losing focus after the ending click means the game is shutting
            // down; losing it before means something else took over the screen.
            guard FocusDetector.isFocused(pid: gamePid, strategy: strategy) else {
                if ended { return nil }
                forceQuit(app)
                return notFound
            }
            logger.notice("  → Attempt \(attempt) (elapsed: \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s)")

            // The game window alone, captured by the game: nothing in front
            // of it reaches the OCR, and once the game has closed its window
            // there is nothing to capture, rather than another app's text.
            let shotPath = "\(context.directory)/attempt.png"
            guard let state = context.game.state(), state.size.width > 0,
                  let pixels = context.game.capture(to: shotPath) else {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            defer { try? FileManager.default.removeItem(atPath: shotPath) }
            let scale = pixels.width / state.size.width
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
            // Until the cursor lock has finished, the first click can't be
            // made, and by then the screen may have gone: look again.
            let lockPending = firstClickToCheck && state.cursorLock == "waiting"
            let fingerprint = ImageFingerprint(imageAt: shotPath)

            // Whole screens are recognised in milliseconds, where reading
            // the window takes most of a second, so they're tried first. A
            // screen still showing after its click is clicked again only
            // after the handler's `retry-after`: some take a click only once
            // they have finished appearing. A different one is clicked at once.
            var actedOnScreen = false
            for handler in fastHandlers where !ended {
                var remembered = memory[handler.id, default: Memory()]
                let retry = handler.retryAfter ?? 0
                let point: CGPoint
                let name: String
                if handler.when == Self.blankTag {
                    guard fingerprint == nil, !lockPending, Date().timeIntervalSince(remembered.actedAt) >= retry else { continue }
                    guard case .clickAt(let fraction) = handler.actions.first(where: { if case .clickAt = $0 { true } else { false } }) else { continue }
                    point = CGPoint(x: state.size.width * fraction.x, y: state.size.height * fraction.y)
                    name = "blank screen"
                    logger.notice("  ✓ [\(elapsed)s] Blank screen, which \(handler.id) clicks: clicking...")
                } else {
                    guard let fingerprint, let match = SplashScreen.match(fingerprint, among: screens[handler.when] ?? []) else { continue }
                    screensRecognised.insert(match.screen.name)
                    if lockPending {
                        if loggedLockWait != match.screen.name {
                            logger.notice("  ⏳ [\(elapsed)s] Screen '\(match.screen.name)' — waiting for the wrapp's cursor lock before clicking")
                            loggedLockWait = match.screen.name
                        }
                        Thread.sleep(forTimeInterval: 0.2)
                        actedOnScreen = true
                        break
                    }
                    // The screen moving on from the one clicked is the click
                    // having taken; until it has, only a retry.
                    let unchanged = remembered.actedOn.map { fingerprint.distance(to: $0) <= SplashScreen.matchDistance } ?? false
                    guard !unchanged || Date().timeIntervalSince(remembered.actedAt) >= retry else { continue }
                    let fraction = match.clickFraction
                    point = CGPoint(x: fraction.x * state.size.width, y: fraction.y * state.size.height)
                    name = match.screen.name
                    logger.notice("  ✓ [\(elapsed)s] Screen '\(name)' (distance \(String(format: "%.3f", match.distance))), \(handler.id) clicking...")
                    remembered.actedOn = fingerprint
                }
                if let failure = click(at: point) {
                    forceQuit(app)
                    return failure
                }
                screensRecognised.insert(name)
                remembered.actedAt = Date()
                remembered.acted = true
                memory[handler.id] = remembered
                actedOnScreen = true
                break
            }
            if actedOnScreen { continue }

            let searchStartTime = Date()
            let found = MainMenuScreen.analyze(screenshotPath: shotPath, needles: readNeedles, app: app)
            logger.notice("    ⏱️  Search took \(String(format: "%.2f", Date().timeIntervalSince(searchStartTime)))s")

            for handler in readHandlers {
                var remembered = memory[handler.id, default: Memory()]
                let ends = handler.actions.contains(.expectEnd) || handler.actions.contains(.quit)
                guard !ended || ends else { continue }
                if handler.once, remembered.acted { continue }
                var target = found[handler.when].map { found in
                    CGPoint(x: found.clickPoint.x / scale, y: found.clickPoint.y / scale)
                }
                if target != nil, ends, !ended, !reachedMenu {
                    reachedMenu = true
                    let known = screens.values.reduce(0) { $0 + $1.count }
                    if known > 0, screensRecognised.isEmpty {
                        warnForTest("No splash screen was recognised: none of the \(known) recorded for \(wrapp.gameSlug) "
                            + "was recognised, so the recordings may no longer match the game (docs/testing.md#splash-screens)")
                    }
                }
                if let seen = target {
                    remembered.lastSeen = seen
                } else if let seen = remembered.lastSeen, let after = handler.repeatWhereLastSeen,
                          Date().timeIntervalSince(remembered.actedAt) >= after {
                    // On a loaded machine the game can miss the click, and
                    // with its own cursor then drawn over the label it may
                    // never be found again.
                    logger.notice("  ↻ \(handler.id): its \(handler.when) wasn't found this time — clicking where it was found before")
                    target = seen
                }
                guard let point = target else { continue }
                // As for a whole screen: not while the cursor lock is still
                // working, unless the run has already clicked its ending.
                if lockPending, !ended { continue }
                // Asked to quit through the game's Quit menu item instead
                // (--quit-from-menu): at once, as that is what is tested.
                if ends, !ended, options.quitFromMenu, found[handler.when] != nil {
                    logger.notice("  ✓ At the menu: quitting through the game's Quit menu item, as ⌘⌥Q does...")
                    guard context.game.quitApp() else {
                        forceQuit(app)
                        return "Couldn't ask the game to quit from its menu"
                    }
                    return nil
                }

                for action in handler.actions {
                    switch action {
                    case .check(let check):
                        guard !ended, found[handler.when] != nil else { continue }
                        switch runCheck(check, state: state, shotPath: shotPath, switchedAway: &switchedAway, gamePid: gamePid,
                                        app: app, context: context) {
                        case .acted: memory[handler.id] = remembered; continue attemptLoop
                        case .waited: break
                        case .finished(let failure): return failure
                        }
                    case .click, .clickAt:
                        guard FocusDetector.isFocused(pid: gamePid, strategy: strategy) else {
                            if ended { return nil }
                            forceQuit(app)
                            return notFound
                        }
                        var clickAt = point
                        if case .clickAt(let fraction) = action {
                            clickAt = CGPoint(x: state.size.width * fraction.x, y: state.size.height * fraction.y)
                        }
                        logger.notice(remembered.acted ? "  ✓ \(handler.id): clicking its \(handler.when) again..." : "  ✓ \(handler.id): found its \(handler.when), clicking...")
                        if let failure = click(at: clickAt) {
                            forceQuit(app)
                            return failure
                        }
                        remembered.acted = true
                        remembered.actedAt = Date()
                    case .quit:
                        logger.notice("  ✓ \(handler.id): found its \(handler.when), quitting the program as its app's Quit does...")
                        guard context.game.quitApp() else {
                            forceQuit(app)
                            return "Couldn't ask the program to quit"
                        }
                        return nil
                    case .expectEnd:
                        ended = true
                        memory[handler.id] = remembered
                        Thread.sleep(forTimeInterval: 1)
                        // The game draws its own cursor into the frame, so
                        // left on the button it hides part of the label (or
                        // hover-highlights it) and a retry can't find it.
                        // Parked against the left edge, clear of the centred
                        // menu text and of the bottom-right corner.
                        context.game.move(to: CGPoint(x: 20, y: state.size.height / 2))
                        if !ProcessControl.isRunning(app, helperPid: gamePid) {
                            logger.notice("✅ Game exited successfully")
                            return nil
                        }
                    }
                }
                memory[handler.id] = remembered
            }

            let remainingTime = 0.2 - Date().timeIntervalSince(iterationStartTime)
            if remainingTime > 0 { Thread.sleep(forTimeInterval: remainingTime) }
        }

        // Each attempt's screenshot is deleted once analysed, so without this
        // a menu that never appeared leaves no trace of what was on screen.
        logger.error("❌ The scenario's goal wasn't reached within \(Int(scenario.timeout))s")
        diagnosticCapture(context, prefix: "exit-not-found")
        optionalScreenshot(prefix: "exit-not-found")
        WindowFinder.logAllWindows()
        forceQuit(app)
        return notFound
    }

    /// The tag a handler waits on for a screen with nothing on it.
    static let blankTag = "blank"

    /// A check a handler asks for (`check: menu`): the menu, fully drawn,
    /// is what every run reaches, so its frame is checked the first time
    /// it's found, and again after switching away from the game and back.
    private func runCheck(_ check: String, state: ControlledWindowState, shotPath: String, switchedAway: inout Bool,
                          gamePid: Int32, app: NSRunningApplication, context: Context) -> Outcome {
        guard check == "menu" else {
            forceQuit(app)
            return .finished("The scenario asks for a check called \(check), which WrappPuppeteer doesn't have")
        }
        if let failure = pictureFrameFailure(context, capturePath: shotPath, windowSize: state.size) {
            forceQuit(app)
            return .finished(failure)
        }
        guard !switchedAway else { return .waited }
        switchedAway = true
        if let failure = switchAwayAndBackFailure(context, gamePid: gamePid) {
            forceQuit(app)
            return .finished(failure)
        }
        // The menu again, to check its frame as it is now.
        return .acted
    }
}
