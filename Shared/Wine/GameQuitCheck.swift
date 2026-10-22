//
//  GameQuitCheck.swift
//  Shared
//
//  Whether a Wine game's exit was the player quitting or the game failing.
//
//  A game that can't run often just quits, exit code 0, and Wine games return
//  all sorts of codes when the player quits, so the exit code can't say which
//  it was. The White Wolf of Icicle Creek quit two seconds after its window
//  appeared when the display had no mode it could switch to, and the wrapp
//  logged it as a clean quit.
//
//  So the wrapp watches for signs instead. Unless something asked the game to
//  quit (the wrapp quitting, which the launcher sees itself; ⌘Q, the Dock or
//  a logout reaching the game's process, which quit watch reports), an exit
//  is a failure when the game:
//
//  - quit before its window appeared (or put any frame on screen);
//  - draws with Direct3D and quit before putting a frame on screen (quit
//    watch reports the first; cnc-ddraw presents on a timer whatever the
//    game does, so its frames say nothing about the game);
//  - quit within `errorWindow` of Wine reporting an error that isn't one of
//    the routine ones every launch logs.
//
//  See docs/wine-in-process-helpers.md#quit-watch.

import Foundation

nonisolated final class GameQuitCheck: @unchecked Sendable {
    /// Why an exit counts as a failure.
    struct Failure: Equatable, Sendable {
        /// For the log: what was seen, e.g. "it quit before it drew anything".
        let summary: String
        /// For the player: a sentence saying what went wrong.
        let explanation: String
        /// The Wine errors logged during the launch, oldest first.
        let wineErrors: [String]
    }

    /// Starts the line the wrapp logs for a failure, which the integration
    /// tests look for in the wrapp's log.
    static let failureMarker = "■ That was no quit"

    /// How soon after a Wine error an exit counts as caused by it. White Wolf
    /// quit 0.8 s after Wine refused its display mode. Five seconds caught a
    /// healthy launch that quit 4.8 s after an unrelated error, so the window
    /// stays just above the quickest real one.
    static let errorWindow: TimeInterval = 1

    /// Wine errors that healthy launches log, and that say nothing about why a
    /// game quit. Matched anywhere in the line.
    static let routineErrors = [
        ":err:vulkan:",                    // this Wine has no Vulkan, and carries on without it
        ":err:environ:init_peb",           // a note that a 32-bit game runs in wow64 mode
        ":err:hid:",                       // a USB device that isn't a game controller
        ":err:winediag:ntlm_check_version", ":err:ntlm:", ":err:kerberos:",  // network sign-in, unused
        // Wine's desktop restoring the saved mode as it starts, refused on a
        // 120 Hz display (the emulated modes are 60 Hz). A game asking for its
        // own mode names the display instead.
        "NtUserChangeDisplaySettings Changing (null) display settings",
    ]

    /// What Steam logs as it starts, as well, for a game launched through it.
    static let routineSteamErrors = [
        ":err:combase:RoGetActivationFactory",  // Windows notification and pen APIs Wine lacks
        ":err:ole:",                            // COM classes Steam asks for that Wine lacks
        "gldriverquery.exe",                    // Steam's graphics probe, which needs a DLL it doesn't ship
    ]

    private let drawsWithDirect3D: Bool
    private let routine: [String]
    private let state = NSLock()
    private var errors: [(at: Date, line: String)] = []
    private var windowAppeared = false
    private var quitWatchArmed = false
    private var drewFrame = false
    private var quitRequest: String?
    /// Enough to explain an exit; a game logging errors all along doesn't grow it.
    private let errorLimit = 50

    init(graphicsAPI: GameGraphicsAPI, throughSteam: Bool) {
        drawsWithDirect3D = graphicsAPI == .direct3D
        routine = Self.routineErrors + (throughSteam ? Self.routineSteamErrors : [])
    }

    /// Feed every line of Wine's output, quit watch's reports among them.
    func observe(line: String, at time: Date = Date()) {
        if let report = InProcessHelperReport.Line(line) {
            guard report.helper == .quitWatch else { return }
            state.withLock {
                if report.message.hasPrefix("armed") { quitWatchArmed = true }
                if report.message.hasPrefix("first frame") { drewFrame = true }
                if report.message.hasPrefix("quit requested") { quitRequest = quitRequest ?? "the game was asked to quit" }
            }
            return
        }
        guard Self.isWineError(line), !routine.contains(where: line.contains) else { return }
        state.withLock {
            errors.append((time, line))
            if errors.count > errorLimit { errors.removeFirst(errors.count - errorLimit) }
        }
    }

    func windowDidAppear() {
        state.withLock { windowAppeared = true }
    }

    /// Something outside the game asked it to quit, so its exit is no failure.
    func quitRequested(_ reason: String) {
        state.withLock { quitRequest = quitRequest ?? reason }
    }

    /// Why the game's exit at `exitTime` was a failure, or nil if it may have
    /// been a quit.
    func failure(exitedAt exitTime: Date = Date()) -> Failure? {
        state.withLock {
            guard quitRequest == nil else { return nil }
            let lines = errors.map(\.line)
            let cause = lines.reversed().lazy.compactMap(Self.knownCause).first
            let summary: String
            let situation: String
            // A frame on screen means a window too, should the wrapp have
            // missed it (it looks only for so long).
            if !windowAppeared, !drewFrame {
                summary = "it quit before its window appeared"
                situation = "The game quit before its window appeared."
            } else if drawsWithDirect3D, quitWatchArmed, !drewFrame {
                summary = "it quit before it drew anything"
                situation = "The game quit before it showed anything."
            } else if let last = errors.last, exitTime.timeIntervalSince(last.at) <= Self.errorWindow {
                summary = String(format: "it quit %.1f s after Wine reported an error", exitTime.timeIntervalSince(last.at))
                situation = "The game quit just after Wine reported an error."
            } else {
                return nil
            }
            return Failure(summary: summary, explanation: cause ?? situation, wineErrors: lines)
        }
    }

    /// Whether a line of Wine's output is an error: an `err:` channel line, or
    /// the report of an exception the game didn't handle.
    static func isWineError(_ line: String) -> Bool {
        line.contains(":err:") || line.contains("Unhandled page fault")
            || line.contains("Unhandled exception") || line.contains("Unhandled stack overflow")
    }

    /// What a Wine error means for the player, for the errors known to end a
    /// game; nil for the rest.
    static func knownCause(of line: String) -> String? {
        if line.contains("NtUserChangeDisplaySettings"), line.contains("DISPLAY") {
            return "The game asked for a display mode this Mac doesn't have, and quit when it couldn't have it."
        }
        if line.contains("Unhandled page fault") || line.contains("Unhandled exception")
            || line.contains("Unhandled stack overflow") {
            return "The game crashed."
        }
        if line.contains(":err:module:import_dll") {
            return "The game couldn't load a file it needs."
        }
        return nil
    }
}
