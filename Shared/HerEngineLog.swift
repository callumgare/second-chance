//
//  HerEngineLog.swift
//  Shared
//
//  The log Her Interactive's later engine writes about its own run.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.HerEngineLog")

/// `Debug.LOG`, which the games from Ghost of Thornton Hall on write to their
/// folder in Documents, afresh on every launch.
///
/// Those games' exit codes are meaningless: the engine's `ExitInstance` ends in
/// MFC's, which returns the `wParam` of the last message MFC itself handled.
/// The games run their own message loop, so that is whatever message happened
/// to pass through last — 1 on most quits, 0 on some, the same clean quit
/// either way. The log's last word is the game's own verdict: it writes
/// `ExitInstance(), good exit...` once its cleanup is done, and a run that
/// crashes on the way out never gets there.
nonisolated enum HerEngineLog {
    static let fileName = "Debug.LOG"
    static let cleanExitLine = "ExitInstance(), good exit..."

    /// Whether a log's contents say the game finished its cleanup.
    static func reportsCleanExit(_ contents: String) -> Bool {
        contents.split(whereSeparator: \.isNewline).contains { $0.hasSuffix(cleanExitLine) }
    }

    /// The game's log in one of `documents`' folders, written since `since`
    /// and reporting a clean exit — nil when there is none, including for
    /// every game that doesn't keep this log.
    static func cleanExitLog(inDocuments documents: URL, since: Date) -> URL? {
        // A wrapp's Documents is a link to its saves, and listing a link
        // fails with "Not a directory" rather than following it.
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(at: documents.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)
        } catch {
            logger.debug("No game log to check: can't list \(documents.path): \(error.localizedDescription)")
            return nil
        }
        for folder in folders {
            let log = folder.appendingPathComponent(fileName)
            guard let modified = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified >= since,
                  let data = try? Data(contentsOf: log) else { continue }
            if reportsCleanExit(String(decoding: data, as: UTF8.self)) {
                return log
            }
        }
        return nil
    }
}
