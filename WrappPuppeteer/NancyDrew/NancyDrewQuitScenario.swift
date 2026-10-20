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
        /// How long to keep looking for the Exit button
        var findExitTimeout: TimeInterval = 300
        /// How long the wrapp's cursor lock may take to finish before the
        /// first click. It waits up to 100 s for the window to settle, then
        /// spends up to ~35 s on middle clicks.
        var cursorLockSettleTimeout: TimeInterval = 180
        /// Only logged — nothing enforces it yet.
        var maxRuntime: TimeInterval = 60
        /// Launch the wrapp with `--debug`
        var debugMode = false
    }

    let wrapp: Wrapp
    let options: Options
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.NancyDrewQuitScenario")

    func run() -> PuppetResult {
        logger.notice("🎮 Starting Nancy Drew quit scenario")
        logger.notice("   App: \(wrapp.appPath)")
        logger.notice("   Engine: \(wrapp.engineSetting)")
        logger.notice("   Executable: \(wrapp.gameExeName)")
        if wrapp.engine == .wine {
            logger.notice("   Wine prefix: \(wrapp.winePrefix.path)")
        }
        logger.notice("   Max runtime: \(Int(options.maxRuntime))s")

        ProcessCleanup.install(cleanupCommands: wrapp.cleanupCommands)

        // The wrapp and the game serve their windows on sockets here
        // (docs/wine-in-process-helpers.md#puppet-control).
        guard let directory = makeControlDirectory() else {
            return .failed("Couldn't create a directory for the wrapp's control sockets")
        }
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let wrappSocket = ControlSocket(path: directory + "/wrapp.sock")
        let game = WindowControl(socket: ControlSocket(path: directory + "/game.sock"))
        let context = Context(directory: directory, wrapp: wrappSocket, game: game)

        guard let app = ProcessControl.launch(appPath: wrapp.appPath, arguments: options.debugMode ? ["--debug"] : [],
                                              environment: ["SECOND_CHANCE_PUPPET_DIR": directory]) else {
            return .failed("Failed to launch game")
        }
        ProcessCleanup.track(appPid: app.processIdentifier, helperPid: nil)

        let appName = app.localizedName ?? "WrappTemplate"
        logger.notice("ℹ️  Game process: \(appName) (PID: \(app.processIdentifier))")

        if wrapp.engine == .wine {
            logger.notice("ℹ️  Wine game - checking for info window...")
            Thread.sleep(forTimeInterval: 1)
            guard InfoWindow.dismiss(wrapp: wrappSocket, timeout: options.infoWindowTimeout) else {
                forceQuit(app)
                return .failed("Failed to dismiss info window")
            }
        }

        guard let (gamePid, _) = waitForGameWindow() else {
            forceQuit(app)
            return .failed("Game process or window did not appear in time")
        }

        logger.notice("ℹ️  Game process PID: \(gamePid)")
        ProcessCleanup.track(appPid: app.processIdentifier, helperPid: gamePid)

        // Checked before waiting for focus: a wrapp that missed the game
        // starting leaves "Loading…" over the game until it exits, and never
        // brings the game to the front either, so the focus wait would fail
        // first and hide the cause.
        guard InfoWindow.waitForClose(wrapp: wrappSocket, timeout: options.infoWindowCloseTimeout) else {
            optionalScreenshot(prefix: "info-window-still-open")
            forceQuit(app)
            return .failed("The wrapp's info window was still open \(Int(options.infoWindowCloseTimeout))s after the game's window appeared")
        }

        guard waitForGameFocus(pid: gamePid, context: context) else {
            forceQuit(app)
            return .failed("Game window did not become active in time")
        }

        // Every wrapp opens its game fullscreen: native fullscreen for Wine,
        // `-f` for ScummVM. A game left in a window still plays, so nothing
        // else here would notice.
        guard waitForFullScreen(context: context) else {
            forceQuit(app)
            return .failed("Game window did not go into a fullscreen Space within \(Int(options.fullScreenTimeout))s")
        }

        if let failure = clickExit(appName: appName, app: app, gamePid: gamePid, context: context) {
            return .failed(failure)
        }

        logger.notice("⏳ Waiting for game to exit...")
        if ProcessControl.waitForTermination(app, helperPid: gamePid, timeout: options.quitTimeout) {
            logger.notice("✅ Game exited cleanly")
            return .passed
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
        wrapp.engine.judgesFocusByFullscreen ? .reportsFullscreen({ context.game.state()?.fullscreen == true }) : .frontmost
    }

    /// Capture the game window, through the game, into /tmp for diagnosing a
    /// failure later, and log where.
    private func diagnosticCapture(_ context: Context, prefix: String) {
        let path = "/tmp/\(prefix)-\(Int(Date().timeIntervalSince1970)).png"
        if context.game.capture(to: path) != nil {
            logger.notice("📸 Game window: \(path)")
        }
    }

    /// A screenshot of the whole screen, which shows what else was in front —
    /// but only if WrappPuppeteer happens to have Screen Recording, which it
    /// doesn't need.
    private func optionalScreenshot(prefix: String) {
        guard CGPreflightScreenCaptureAccess() else { return }
        if let path = ScreenCapture.captureScreen(prefix: prefix) {
            logger.notice("📸 Full screen screenshot: \(path)")
        }
    }

    /// Show the click ring where a window point is on screen. The game's
    /// window position comes from the on-screen window list, which needs no
    /// permission.
    private func showClick(at point: CGPoint, gamePid: Int32) {
        guard let window = WindowFinder.mainWindow(ofPid: gamePid) else { return }
        InputControl.showClick(at: CGPoint(x: window.bounds.minX + point.x, y: window.bounds.minY + point.y))
    }

    private func forceQuit(_ app: NSRunningApplication) {
        ProcessControl.forceQuit(app, cleanupCommands: wrapp.cleanupCommands)
    }

    /// Wait for the game's process, then its window. Returns the game
    /// process's PID and its windows.
    private func waitForGameWindow() -> (pid: Int32, windows: [WindowInfo])? {
        let processName = wrapp.engine.gameProcessName(gameExeName: wrapp.gameExeName)
        logger.notice("⏳ Waiting for game process (timeout: \(Int(options.processDetectTimeout))s), then its window...")
        let start = Date()

        logger.notice("[Step 1] Monitoring for \(processName) process...")
        guard let process = ProcessFinder.waitForProcess(named: processName, timeout: options.processDetectTimeout) else {
            return nil
        }
        let pid = process.pid

        logger.notice("[Step 2] Monitoring for windows from \(processName) (PID: \(pid))...")
        guard let windows = WindowFinder.waitForWindows(timeout: options.windowDetectTimeout, where: { $0.ownerPid == pid }) else {
            logger.critical("❌ Timeout: \(processName) process found but no windows appeared")
            WindowFinder.logAllWindows()
            return nil
        }

        logger.notice("✅ Game window detected after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        for (index, window) in windows.enumerated() {
            logger.notice("   [\(index + 1)] \(window.title) - \(Int(window.bounds.width))x\(Int(window.bounds.height))")
        }
        return (pid, windows)
    }

    /// Wait for the game's window to take focus.
    private func waitForGameFocus(pid: Int32, context: Context) -> Bool {
        logger.notice("[Step 3] Waiting for game to become active...")
        // 120s, not the default 10: on a loaded machine a game's first window
        // can take a while before macOS will bring it in front (Ghost of
        // Thornton Hall's has stayed behind the wrapp for over 10s).
        guard FocusDetector.waitForFocus(pid: pid, strategy: focusStrategy(context), activate: wrapp.engine.activatesForFocus, timeout: 120) else {
            WindowFinder.logAllWindows()
            optionalScreenshot(prefix: "game-not-focused")
            return false
        }

        NSSound.beep()
        // What was on screen, for diagnosing later failures
        diagnosticCapture(context, prefix: "game-window-detected")
        return true
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
                logger.notice("   [\(Int(Date().timeIntervalSince(start)))s] Not in a fullscreen Space yet (game says: \(state.map { "\(Int($0.size.width))x\(Int($0.size.height)), native=\($0.native), covering the screen=\($0.fullscreen && !$0.native)" } ?? "nothing"))")
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
                    return (nil, "The wrapp's cursor lock was still waiting \(Int(options.cursorLockSettleTimeout))s before the first click — see '[CursorLock]' in the wrapp's log")
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

    /// Look for the Exit button and click it, clicking the Her Interactive
    /// logo first if the game is still on its splash screen. Nil once Exit
    /// has been clicked and the game lost focus or exited; otherwise why not.
    ///
    /// The first click, whichever it is, must reach the game: a Wine game's
    /// cnc-ddraw swallows it unless the wrapp's cursor lock took the cursor
    /// first, and on the logo — which any click skips — nothing else would
    /// show it.
    private func clickExit(appName: String, app: NSRunningApplication, gamePid: Int32, context: Context) -> String? {
        logger.notice("🎮 Attempting to quit game...")
        let strategy = focusStrategy(context)
        let notFound = "OCR could not find Exit button"

        // Only cnc-ddraw swallows a first click, so only a Wine game has a
        // first click to check.
        var firstClickToCheck = wrapp.engine == .wine
        /// Click a window point, checking the first click wasn't swallowed;
        /// the failure if it was.
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
                logger.error("❌ The first click is what took the cursor: cnc-ddraw swallowed it, so the wrapp's cursor lock didn't take hold — see '[CursorLock]' in the wrapp's log")
                diagnosticCapture(context, prefix: "first-click-swallowed")
                return "The game's first click was swallowed: cnc-ddraw took the cursor on it rather than from the wrapp's cursor lock"
            }
            return nil
        }

        var clickedInteractive = false
        var clickedExitButton = false
        // Where Exit was last found (in window points), and when it was last
        // clicked: on a loaded machine the game can miss the click, and with
        // its own cursor then drawn over the label OCR may never find it again.
        var lastExitLocation: CGRect?
        var lastExitClick = Date.distantPast
        let startTime = Date()
        var attempt = 0

        while Date().timeIntervalSince(startTime) < options.findExitTimeout {
            attempt += 1
            let iterationStartTime = Date()

            if attempt == 1 { NSSound.beep() }

            // Losing focus after clicking Exit means the game is shutting down;
            // losing it before means something else took over the screen.
            guard FocusDetector.isFocused(pid: gamePid, strategy: strategy) else {
                if clickedExitButton { return nil }
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
            let scale = pixels.width / state.size.width
            let toPoints = { (rect: CGRect) in
                CGRect(x: rect.minX / scale, y: rect.minY / scale, width: rect.width / scale, height: rect.height / scale)
            }

            let searchStartTime = Date()
            let analysis = MainMenuScreen.analyze(screenshotPath: shotPath, app: app)
            logger.notice("    ⏱️  Search took \(String(format: "%.2f", Date().timeIntervalSince(searchStartTime)))s")
            try? FileManager.default.removeItem(atPath: shotPath)

            var exitTarget = analysis.quitButton.map(toPoints)
            if let found = exitTarget {
                lastExitLocation = found
            } else if let remembered = lastExitLocation, Date().timeIntervalSince(lastExitClick) >= 3 {
                logger.notice("  ↻ 'Exit Game' not found this time — clicking where it was found before")
                exitTarget = remembered
            }

            if let exitLocation = exitTarget {
                guard FocusDetector.isFocused(pid: gamePid, strategy: strategy) else {
                    if clickedExitButton { return nil }
                    forceQuit(app)
                    return notFound
                }

                logger.notice(clickedExitButton ? "  ✓ Clicking 'Exit Game' button again..." : "  ✓ Found 'Exit Game' button, clicking...")
                clickedExitButton = true

                var clickPoint = CGPoint(x: exitLocation.midX, y: exitLocation.midY)

                // The Scarlet Hand's Exit hotspot sits above its label
                if appName.contains("Scarlet Hand") {
                    clickPoint.y -= exitLocation.height / 2
                }

                if let failure = click(at: clickPoint) {
                    forceQuit(app)
                    return failure
                }
                lastExitClick = Date()
                Thread.sleep(forTimeInterval: 1)

                // The game draws its own cursor into the frame, so left on the
                // button it hides part of the label from OCR (or hover-
                // highlights it) and a retry can't find it. Park it against the
                // left edge, clear of the centred menu text and of the
                // bottom-right corner the quit-button template is searched in.
                context.game.move(to: CGPoint(x: 20, y: state.size.height / 2))

                if !ProcessControl.isRunning(app, helperPid: gamePid) {
                    logger.notice("✅ Game exited successfully")
                    return nil
                }
            }

            if let interactiveLocation = analysis.interactiveLogo.map(toPoints), !clickedInteractive {
                logger.notice("  ✓ Found 'interactive' logo, clicking to enable menu...")
                Thread.sleep(forTimeInterval: 1)
                let logoPoint = CGPoint(x: interactiveLocation.midX, y: interactiveLocation.midY)
                if let failure = click(at: logoPoint) {
                    forceQuit(app)
                    return failure
                }
                clickedInteractive = true
                Thread.sleep(forTimeInterval: 2)
            }

            let remainingTime = 0.2 - Date().timeIntervalSince(iterationStartTime)
            if remainingTime > 0 { Thread.sleep(forTimeInterval: remainingTime) }
        }

        // Each attempt's screenshot is deleted once analysed, so without this
        // a menu that never appeared leaves no trace of what was on screen.
        logger.error("❌ No Exit button or logo found within \(Int(options.findExitTimeout))s")
        diagnosticCapture(context, prefix: "exit-not-found")
        optionalScreenshot(prefix: "exit-not-found")
        WindowFinder.logAllWindows()
        forceQuit(app)
        return notFound
    }
}
