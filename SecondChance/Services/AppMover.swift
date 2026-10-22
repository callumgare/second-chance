//
//  AppMover.swift
//  SecondChance
//
//  Offers to move Second Chance into Applications when macOS is running it
//  translocated (`AppTranslocation`): opened where the download unpacked it,
//  so macOS runs a hidden read-only copy instead. From there Sparkle can't
//  install updates. Moving the original, taking the quarantine attribute off
//  it (Gatekeeper has already passed this copy, since it is running) and
//  reopening it from Applications ends that for good.

import AppKit
import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.AppMover")

@MainActor
enum AppMover {

    /// Ask to move, when the app is translocated. Moving reopens the app from
    /// Applications and quits this copy.
    static func offerIfTranslocated() {
        guard AppTranslocation.isTranslocated() else { return }
        guard let original = AppTranslocation.originalURL() else {
            logger.warning("Running translocated, but macOS didn't say where the original is; not offering to move")
            return
        }
        logger.notice("Running translocated, from a copy of \(original.path)")

        guard offerAlert().runModal() == .alertFirstButtonReturn else {
            logger.notice("Not moving to Applications, as asked")
            return
        }

        let moved: URL
        do {
            moved = try move(original)
        } catch {
            logger.error("Couldn't move \(original.path) to Applications: \(ErrorChain.describe(error))")
            showMoveFailed(original: original, error: error)
            return
        }
        logger.notice("Moved to \(moved.path); reopening from there")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: moved, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    logger.error("Couldn't reopen from \(moved.path): \(ErrorChain.describe(error))")
                    let alert = NSAlert()
                    alert.messageText = "Second Chance couldn't reopen itself"
                    alert.informativeText = "It's now in your Applications folder. Quit it and open it from there."
                    alert.runModal()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// The question: Move to Applications, or Not Now.
    static func offerAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Move Second Chance to your Applications folder"
        alert.informativeText = """
        Second Chance is still where it was downloaded, so macOS doesn't run it from there. \
        It runs a hidden, read-only copy instead, and makes a new one each time you open it. \
        From that copy, Second Chance can't install its own updates.

        Moving Second Chance to your Applications folder fixes this. \
        It will reopen from there, and you won't be asked again.
        """
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        return alert
    }

    /// Where the app goes: `/Applications` when it can be written to (an
    /// admin's account), else the person's own `~/Applications`.
    nonisolated static func applicationsFolder(fileManager: FileManager = .default) -> URL {
        let shared = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if fileManager.isWritableFile(atPath: shared.path) { return shared }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    }

    /// The app's name in Applications: its own, whatever the download was
    /// renamed to (`Second Chance 2.app`, from a second download).
    nonisolated static func destination(in applications: URL, bundleName: String) -> URL {
        applications.appendingPathComponent("\(bundleName).app", isDirectory: true)
    }

    /// Move `original` into Applications, replacing (to the Bin) an older copy
    /// there, and take the quarantine attribute off. A read-only original —
    /// one on a disk image — is copied instead.
    nonisolated static func move(_ original: URL, to applications: URL = applicationsFolder(),
                     bundleName: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Second Chance") throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
        let destination = destination(in: applications, bundleName: bundleName)
        if destination.standardizedFileURL.path != original.standardizedFileURL.path {
            if fileManager.fileExists(atPath: destination.path) {
                logger.notice("Moving the copy already at \(destination.path) to the Bin")
                try fileManager.trashItem(at: destination, resultingItemURL: nil)
            }
            do {
                try fileManager.moveItem(at: original, to: destination)
            } catch {
                logger.notice("Couldn't move \(original.path) (\(error.localizedDescription)); copying it instead")
                try fileManager.copyItem(at: original, to: destination)
            }
        }
        removeQuarantine(from: destination)
        return destination
    }

    /// Take `com.apple.quarantine` off `bundle` and everything in it.
    nonisolated static func removeQuarantine(from bundle: URL) {
        var paths = [bundle.path]
        if let contents = FileManager.default.enumerator(atPath: bundle.path) {
            for case let relative as String in contents {
                paths.append(bundle.appendingPathComponent(relative).path)
            }
        }
        var failures = 0
        for path in paths where removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
            failures += 1
        }
        if failures > 0 {
            logger.warning("Couldn't take the quarantine attribute off \(failures) files in \(bundle.path)")
        }
    }

    private static func showMoveFailed(original: URL, error: Error) {
        moveFailedAlert(original: original, error: error).runModal()
    }

    static func moveFailedAlert(original: URL, error: Error) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Second Chance couldn't move itself"
        alert.informativeText = """
        Quit Second Chance, drag it from \(original.deletingLastPathComponent().path) into your Applications folder, \
        then open it from there.

        \(error.localizedDescription)
        """
        return alert
    }
}
