//
//  WineDisplayMode.swift
//  WineKit
//
//  Setting the display mode a launch says (`--wine.display-mode`) in the
//  game's Wine session, before the game starts.

import Foundation
import Logging
import WrappFormat

/// Sets a display mode for the rest of a Wine session, as a game made for
/// that screen would find it on Windows.
///
/// The prefix has Wine's `EmulateModeset` on, so the change never touches the
/// Mac's display: win32u reports the mode to every program in the session and
/// scales their windows up to the display, the shape kept
/// (docs/wine-in-process-helpers.md#a-display-mode-the-launch-sets). Bioscopia's
/// Director projector covers whatever screen it finds with its window and
/// draws its 800x600 stage in the middle; told the screen is 800x600, its
/// window is the stage, and Wine scales it up to fill the display.
///
/// Wine has no program that sets a display mode, so the wrapp carries one,
/// display_mode.exe (`Packages/Modules/wine/DisplayMode/`), written out to a
/// temporary file each time and run. It changes the mode without
/// `CDS_FULLSCREEN`, so explorer.exe's restorer, which puts back only a
/// fullscreen change, and only as its program exits, leaves it until the
/// session ends; Wine keeps the current mode in the session's volatile
/// registry, so the next session starts from the display's again.
nonisolated public enum WineDisplayMode {
    /// Long enough for a Wine program to start on a fully loaded Mac, where
    /// one has taken over 30 seconds.
    static let timeout: TimeInterval = 180

    /// Set `mode` in `wine`'s session: true when Wine took it. A failure is
    /// logged, never thrown: the game then starts at the display's own size,
    /// as it would have without the launch's option.
    @discardableResult
    public static func set(_ mode: RecordedLaunch.DisplayMode, in wine: Wine, logger: Logger) async -> Bool {
        guard let program = Data(base64Encoded: programBase64, options: .ignoreUnknownCharacters) else {
            logger.error("[Display mode] The program that sets it can't be read; the game starts at the display's own size")
            return false
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("second-chance-display-mode-\(UUID().uuidString).exe")
        defer {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                logger.debug("[Display mode] Couldn't remove \(file.path): \(error.localizedDescription)")
            }
        }
        do {
            try program.write(to: file)
            let said = try await wine.output(of: .program(file.path, [String(mode.width), String(mode.height)]),
                                             timeout: timeout, onTimeout: .stopProgram)
            let line = said.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            logger.notice("[Display mode] Set to \(mode) for the game (\(line))")
            return true
        } catch {
            logger.warning("[Display mode] Couldn't set \(mode), so the game starts at the display's own size: \(error)")
            return false
        }
    }
}
