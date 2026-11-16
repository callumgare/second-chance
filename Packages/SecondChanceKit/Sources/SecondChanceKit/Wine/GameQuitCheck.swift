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
//    the routine ones every launch logs, nor one the game had been logging
//    since `recurringLead` or more before it quit;
//  - quit within `crashWindow` of an exception nothing handled: with no crash
//    dialog, the program ends once winedbg has written its backtrace.
//
//  See docs/wine-in-process-helpers.md#quit-watch.

import Foundation

nonisolated public final class GameQuitCheck: @unchecked Sendable {
    /// Why an exit counts as a failure.
    public struct Failure: Equatable, Sendable {
        /// For the log: what was seen, e.g. "it quit before it drew anything".
        public let summary: String
        /// For the player: a sentence saying what went wrong.
        public let explanation: String
        /// The Wine errors logged during the launch, oldest first.
        public let wineErrors: [String]
    }

    /// Starts the line the wrapp logs for a failure, which the integration
    /// tests look for in the wrapp's log.
    public static let failureMarker = "■ That was no quit"

    /// How soon after a Wine error an exit counts as caused by it. White Wolf
    /// quit 0.8 s after Wine refused its display mode. Five seconds caught a
    /// healthy launch that quit 4.8 s after an unrelated error, so the window
    /// stays just above the quickest real one.
    static let errorWindow: TimeInterval = 1

    /// How long before an exit an error must first have been logged to count
    /// as one the game logs all along, which says nothing about why it quit.
    /// The Deadly Device on Wine 11.22 logs a GL error from its first frame
    /// on, and quitting from its menu, 40 s to 3 min in, was blamed on it.
    /// White Wolf's refused mode was logged 0.8 s before it quit.
    static let recurringLead: TimeInterval = 10

    /// How soon after an exception nothing handled an exit counts as that
    /// crash. The prefix has no crash dialog (the wine module's
    /// `nocrashdialog`), so a crashed program ends once winedbg has written
    /// its backtrace to the log: seconds, longer on a loaded Mac.
    static let crashWindow: TimeInterval = 30

    // `routineErrors`, `routineSteamErrors` and `routineBigFishErrors`, the
    // Wine errors healthy launches log that say nothing about why a game
    // quit, are the wine, steam and big-fish modules' data
    // (GameQuitCheck+RoutineErrors.swift). A launcher's errors come down the
    // game's own stream, so its routine ones count for its games.

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
    /// When each kind of error (`kind(of:)`) was first and last logged. Kept
    /// apart from `errors`, which an error logged every frame would fill,
    /// pushing out a new one just before the exit.
    private var errorKinds: [String: (first: Date, last: Date)] = [:]
    /// Enough kinds for any launch; one whose text varies past what `kind(of:)`
    /// takes out doesn't grow it.
    private let errorKindLimit = 200

    public init(graphicsAPI: GameGraphicsAPI, throughSteam: Bool, throughBigFish: Bool = false) {
        drawsWithDirect3D = graphicsAPI == .direct3D
        routine = Self.routineErrors + (throughSteam ? Self.routineSteamErrors : [])
            + (throughBigFish ? Self.routineBigFishErrors : [])
    }

    /// Feed every line of Wine's output, quit watch's reports among them.
    public func observe(line: String, at time: Date = Date()) {
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
        let kind = Self.kind(of: line)
        state.withLock {
            errors.append((time, line))
            if errors.count > errorLimit { errors.removeFirst(errors.count - errorLimit) }
            if let seen = errorKinds[kind] {
                errorKinds[kind] = (seen.first, time)
            } else if errorKinds.count < errorKindLimit {
                errorKinds[kind] = (time, time)
            }
        }
    }

    public func windowDidAppear() {
        state.withLock { windowAppeared = true }
    }

    /// Something outside the game asked it to quit, so its exit is no failure.
    public func quitRequested(_ reason: String) {
        state.withLock { quitRequest = quitRequest ?? reason }
    }

    /// Whether something asked the game to quit: the player, through its
    /// menu or the wrapp, or the Mac logging out.
    public var wasQuitRequested: Bool {
        state.withLock { quitRequest != nil }
    }

    /// Why the game's exit at `exitTime` was a failure, or nil if it may have
    /// been a quit.
    public func failure(exitedAt exitTime: Date = Date()) -> Failure? {
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
                situation = String(localized: "The game quit before its window appeared.")
            } else if drawsWithDirect3D, quitWatchArmed, !drewFrame {
                summary = "it quit before it drew anything"
                situation = String(localized: "The game quit before it showed anything.")
            } else if let last = lastTellingError(before: exitTime) {
                summary = String(format: "it quit %.1f s after Wine reported an error", exitTime.timeIntervalSince(last))
                // For the player, so no "Wine": the summary, for the log, has that.
                situation = String(localized: "The game quit just after something went wrong in it.")
            } else if let crash = errors.last(where: { Self.isCrash($0.line) }),
                      exitTime.timeIntervalSince(crash.at) <= Self.crashWindow {
                summary = String(format: "it quit %.1f s after an exception nothing handled", exitTime.timeIntervalSince(crash.at))
                situation = String(localized: "The game quit just after something went wrong in it.")
            } else {
                return nil
            }
            return Failure(summary: summary, explanation: cause ?? situation, wineErrors: lines)
        }
    }

    /// When the last error that could explain an exit at `exitTime` was
    /// logged: one within `errorWindow` of it, of a kind first logged less
    /// than `recurringLead` before it. Called holding `state`.
    private func lastTellingError(before exitTime: Date) -> Date? {
        errorKinds.values
            .filter { exitTime.timeIntervalSince($0.last) <= Self.errorWindow && exitTime.timeIntervalSince($0.first) < Self.recurringLead }
            .map(\.last)
            .max()
    }

    /// An error's text without what changes between two of the same: the
    /// thread that logged it (`0378:err:…`) and addresses and handles.
    static func kind(of line: String) -> String {
        line.replacingOccurrences(of: #"^[0-9a-fA-F]{4}:"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b(0x)?[0-9a-fA-F]{6,}\b"#, with: "#", options: .regularExpression)
    }

    /// Whether a line of Wine's output is an error: an `err:` channel line, or
    /// the report of an exception the game didn't handle.
    static func isWineError(_ line: String) -> Bool {
        line.contains(":err:") || line.contains("Unhandled page fault")
            || line.contains("Unhandled exception") || line.contains("Unhandled stack overflow")
    }

    /// Whether a line of Wine's output reports an exception the program
    /// didn't handle, which ends it.
    static func isCrash(_ line: String) -> Bool {
        line.contains("Unhandled page fault") || line.contains("Unhandled exception") || line.contains("Unhandled stack overflow")
    }

    /// What a Wine error means for the player, for the errors known to end a
    /// game; nil for the rest.
    static func knownCause(of line: String) -> String? {
        if line.contains("NtUserChangeDisplaySettings"), line.contains("DISPLAY") {
            return String(localized: "The game asked for a screen setting this Mac doesn't have, and quit when it couldn't have it.")
        }
        if isCrash(line) {
            return String(localized: "Something went wrong inside the game, and it had to close.")
        }
        if line.contains(":err:module:import_dll") {
            return String(localized: "The game couldn't load a file it needs.")
        }
        return nil
    }
}
