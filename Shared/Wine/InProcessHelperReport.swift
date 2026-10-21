//
//  InProcessHelperReport.swift
//  Shared
//
//  What the in-process helpers (native fullscreen, cursor lock, mode
//  scaling, quit watch, puppet control) say about
//  themselves, gathered from the game's output, and a check that the ones the
//  wrapp armed did arm. A helper that never arms is otherwise silent — the
//  game just runs in a window, or swallows its first click — which is how
//  both went unnoticed when the bundled Wine stopped naming processes the way
//  they matched on. See docs/wine-in-process-helpers.md.

import Foundation
import Logging

nonisolated final class InProcessHelperReport: @unchecked Sendable {
    enum Helper: String, CaseIterable, Sendable {
        case nativeFullscreen = "NativeFullscreen"
        case cursorLock = "CursorLock"
        case modeScaling = "EmulatedMode"
        case quitWatch = "QuitWatch"
        case puppetControl = "PuppetControl"

        var name: String {
            switch self {
            case .nativeFullscreen: return "Native fullscreen"
            case .cursorLock: return "Cursor lock"
            case .modeScaling: return "Mode scaling"
            case .quitWatch: return "Quit watch"
            case .puppetControl: return "Puppet control"
            }
        }

        /// The variable that arms it (`WineEnvironment.inProcessHelperVariables`).
        var variable: String {
            switch self {
            case .nativeFullscreen: return "NATIVE_MACOS_FULLSCREEN_EXE"
            case .cursorLock: return "CURSOR_LOCK_EXE"
            case .modeScaling: return "EMULATED_MODE_SCALING_EXE"
            case .quitWatch: return "QUIT_WATCH_EXE"
            case .puppetControl: return "PUPPET_CONTROL_EXE"
            }
        }

        /// What a player (or the test) sees when it never arms.
        var consequence: String {
            switch self {
            case .nativeFullscreen: return "the game stays in a window"
            case .cursorLock: return "the game's first click will be swallowed"
            case .modeScaling: return "a game that switches the display mode will draw into a corner of the screen"
            case .quitWatch: return "a game that quits before it has drawn anything won't be reported as failing"
            case .puppetControl: return "WrappPuppeteer can't see or click the game"
            }
        }

        /// The line the wrapp logs when the helper arms, which the integration
        /// tests look for in the wrapp's log.
        var armedMarker: String { "[Helpers] \(name) armed" }
    }

    /// One status line from a helper (format in helper_common.h).
    struct Line: Equatable, Sendable {
        let helper: Helper
        let level: Logger.Level
        let message: String

        init?(_ line: String) {
            let prefix = "second-chance-helper["
            guard line.hasPrefix(prefix), let close = line.firstIndex(of: "]"),
                  let helper = Helper(rawValue: String(line[line.index(line.startIndex, offsetBy: prefix.count)..<close]))
            else { return nil }
            let rest = line[line.index(after: close)...].drop(while: { $0 == " " })
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            switch rest[..<colon] {
            case "notice": level = .notice
            case "warning": level = .warning
            case "error": level = .error
            default: return nil
            }
            self.helper = helper
            message = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }

    /// How long after the game's window appears a helper has to report
    /// arming before it counts as not having armed. Arming happens when the
    /// game first draws, well before its window shows, so this is only slack.
    static let armDeadline: TimeInterval = 60

    private let expected: [Helper]
    private let logger: Logger
    private let state = NSLock()
    private var armed: Set<Helper> = []
    private var checked = false

    /// `armingVariables` is what the game was started with: the helpers
    /// whose variables are set are the ones expected to arm.
    init(armingVariables: [String: String], logger: Logger) {
        expected = Helper.allCases.filter { armingVariables[$0.variable] != nil }
        self.logger = logger
    }

    /// Feed one line of the game's output; anything that isn't a helper's
    /// status line is ignored.
    func observe(line text: String) {
        guard let line = Line(text) else { return }
        if line.message.hasPrefix("armed") {
            let first = state.withLock { armed.insert(line.helper).inserted }
            if first { logger.notice("\(line.helper.armedMarker) (\(line.message))") }
        } else {
            logger.log(level: line.level, "[Helpers] \(line.helper.name): \(line.message)")
        }
    }

    /// The game's window is up: check, `armDeadline` later, that every
    /// expected helper armed.
    func gameWindowAppeared() {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.armDeadline) { [self] in
            _ = check()
        }
    }

    /// Log an error for each expected helper that hasn't armed, and return
    /// them. Checks once; later calls return nothing.
    @discardableResult
    func check() -> [Helper] {
        let missing: [Helper] = state.withLock {
            guard !checked else { return [] }
            checked = true
            return expected.filter { !armed.contains($0) }
        }
        for helper in missing {
            logger.error("[Helpers] \(helper.name) never armed in the game, \(Int(Self.armDeadline))s after its window appeared: \(helper.consequence). The helper may not recognise the game's process; see docs/wine-in-process-helpers.md")
        }
        return missing
    }
}
