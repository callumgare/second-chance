//
//  ProgressFileWriter.swift
//  SecondChance
//
//  Writes a wrapp build's progress as JSON lines to a file, for whoever
//  started the build to follow: the dev CLI (`sc wrapp build`, via
//  SECOND_CHANCE_PROGRESS_PATH) and the integration tests (via
//  TEST_RUNNER_PROGRESS_PATH). It is a subscriber to `EventBus.app` like any
//  other, so it reports exactly what the UI and tests see. Log text stays
//  separate, on stderr.
//
//  One object per line:
//    {"event":"stage","stage":"installingGame","text":"Game installing","fraction":0.5}
//    {"event":"completed","path":"/…/Nancy Drew - X.app"}
//    {"event":"failed","message":"…"}
//  plus, from the integration tests, per-game lines:
//    {"event":"game","slug":"stay-tuned","phase":"started"}
//    {"event":"game","slug":"stay-tuned","phase":"finished","result":"passed","seconds":81.2}
//

import Foundation
import Logging

nonisolated final class ProgressFileWriter: @unchecked Sendable {
    private nonisolated static let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.ProgressFileWriter")

    private let handle: FileHandle
    private let lock = NSLock()
    private var token: EventBus<AppEvent>.Token?

    /// A writer for the path in `variable`, or nil when it isn't set (or the
    /// file can't be opened — logged, since progress is a nicety).
    static func fromEnvironment(_ variable: String) -> ProgressFileWriter? {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else { return nil }
        return ProgressFileWriter(path: path)
    }

    /// A writer appending to `path` (created if missing), or nil when it
    /// can't be opened — logged, since progress is a nicety.
    ///
    /// Opened with `O_APPEND`, so every record lands at the file's end at the
    /// moment it's written: the integration suites each have a writer on the
    /// same file, and with an offset of their own (seeking to the end only
    /// once, on opening) each overwrote the other's records.
    convenience init?(path: String) {
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            Self.logger.error("Can't open progress file \(path) (\(String(cString: strerror(errno)))); progress won't be reported")
            return nil
        }
        self.init(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }

    private init(handle: FileHandle) {
        self.handle = handle
    }

    /// Write one record.
    func write(_ record: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else {
            Self.logger.error("Progress record isn't valid JSON: \(record)")
            return
        }
        lock.lock()
        handle.write(data + Data("\n".utf8))
        lock.unlock()
    }

    /// Report the build's progress, completion and failure from the bus.
    /// Subscribing again is a no-op.
    func subscribe(to bus: EventBus<AppEvent>) async {
        guard currentToken() == nil else { return }
        // Captured strongly on purpose: the subscription keeps the writer
        // alive until `unsubscribe`, so callers needn't hold on to it.
        let token = await bus.subscribe { event in
            self.handle(event)
        }
        setToken(token)
    }

    func unsubscribe(from bus: EventBus<AppEvent>) async {
        guard let token = currentToken() else { return }
        await bus.unsubscribe(token)
        setToken(nil)
    }

    private func currentToken() -> EventBus<AppEvent>.Token? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    private func setToken(_ newValue: EventBus<AppEvent>.Token?) {
        lock.lock()
        token = newValue
        lock.unlock()
    }

    private func handle(_ event: AppEvent) {
        guard case .wrappBuild(let buildEvent) = event else { return }
        switch buildEvent {
        case .progress(let state):
            guard let stage = Self.stageName(state) else { return }
            var record: [String: Any] = ["event": "stage", "stage": stage, "text": Self.text(state)]
            if let fraction = state.progress { record["fraction"] = fraction }
            write(record)
        case .completed(let wrappPath):
            write(["event": "completed", "path": wrappPath.path])
        case .failed(let error):
            write(["event": "failed", "message": error.localizedDescription])
        case .patchFailed(let id, let message):
            write(["event": "patch-failed", "id": id, "message": message])
        default:
            break
        }
    }

    /// A stable name for each in-flight state, for machine readers.
    static func stageName(_ state: WrappBuildState) -> String? {
        switch state {
        case .detectingGame: return "detectingGame"
        case .settingUpWrapp: return "settingUpWrapp"
        case .copyingInstaller: return "copyingInstaller"
        case .installingGame: return "installingGame"
        case .configuringWrapp: return "configuringWrapp"
        case .savingApp: return "savingApp"
        case .completed: return "completed"
        case .error: return "error"
        case .idle, .selectingWrappSource, .selectingSource: return nil
        }
    }

    /// The stage for a person: what the progress view shows, with the
    /// substep whenever there is one (the view waits 5 s before showing it,
    /// to avoid flashing; a terminal line doesn't flash).
    static func text(_ state: WrappBuildState) -> String {
        guard let substep = state.substep, state.elapsedSeconds == nil else { return state.displayText }
        let base = state.displayText.replacingOccurrences(of: "...", with: "")
        return "\(base) — \(substep)"
    }
}
