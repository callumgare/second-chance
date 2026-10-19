//
//  InfoWindowController.swift
//  WrappTemplate
//
//  Controller for the info/warning window. Hosts InfoWindowView (SwiftUI).

import Foundation
import AppKit
import SwiftUI

var globalInfoWindow: InfoWindowController?

class InfoWindowController: NSWindowController {
    private let viewModel: InfoWindowViewModel
    /// Watches for a heavily loaded Mac while the game loads; stopped once it
    /// has loaded, failed, or the window closes.
    private var loadMonitor: SystemLoadMonitor?
    let appSupportPath: URL
    var onWarningConfirmed: (() -> Void)?

    /// Whether the save warning is currently visible.
    var isShowingWarning: Bool {
        if case .warning = viewModel.phase { return true }
        return false
    }

    /// Whether the game has successfully loaded (info window was dismissed).
    var hasGameLoaded: Bool {
        viewModel.gameHasLoaded
    }

    init(gameTitle: String, appSupportPath: URL, gameSlug: String = "nancy-drew", saveWarningEnabled: Bool = true, customMessage: String? = nil) {
        self.appSupportPath = appSupportPath

        let message = customMessage ?? "Loading \(gameTitle)..."
        let shouldShow = saveWarningEnabled && !Self.hasUserDismissedSaveWarning(appSupportPath: appSupportPath)
        self.viewModel = InfoWindowViewModel(message: message, saveWarningEnabled: shouldShow, gameSlug: gameSlug)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Nancy Drew"
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: InfoWindowView(viewModel: viewModel))

        super.init(window: window)

        // Wire up the confirm callback: save pref then notify caller
        viewModel.onConfirm = { [weak self] in
            guard let self else { return }
            if self.viewModel.dontShowAgain {
                self.saveDontShowSaveWarning()
            }
            self.onWarningConfirmed?()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    func show() {
        window?.makeKeyAndOrderFront(nil)
        startLoadMonitor()
    }

    private func startLoadMonitor() {
        guard loadMonitor == nil else { return }
        let monitor = SystemLoadMonitor { [weak self] reading in
            guard let self, !self.viewModel.gameHasLoaded else { return }
            self.viewModel.heavyLoad = reading
        }
        loadMonitor = monitor
        monitor.start()
    }

    func updateMessage(_ message: String) {
        DispatchQueue.main.async {
            self.viewModel.message = message
        }
    }

    func notifyGameLoaded() {
        DispatchQueue.main.async {
            self.loadMonitor?.stop()
            self.viewModel.markGameLoaded()
            self.close()
        }
    }

    func hideWarning() {
        viewModel.phase = .loading
        viewModel.startSlowLoadingTimer()
    }

    func showError(exitCode: Int32) {
        DispatchQueue.main.async {
            self.loadMonitor?.stop()
            self.viewModel.heavyLoad = nil
            self.viewModel.showError(exitCode: exitCode)
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Safe to call from any thread: the game launcher calls it from its
    /// background queue when the game exits, and AppKit traps (SIGILL) on a
    /// window closed off the main thread. Off-main calls are queued, so they
    /// stay in order with `showError`, which is queued the same way.
    override func close() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.close() }
            return
        }
        viewModel.stopTimer()
        loadMonitor?.stop()
        window?.close()
    }

    // MARK: - Save Warning Preferences

    static func hasUserDismissedSaveWarning(appSupportPath: URL) -> Bool {
        let prefFile = appSupportPath.appendingPathComponent("dont-show-save-warning")
        return FileManager.default.fileExists(atPath: prefFile.path)
    }

    private func saveDontShowSaveWarning() {
        let prefFile = appSupportPath.appendingPathComponent("dont-show-save-warning")
        try? "true".write(to: prefFile, atomically: true, encoding: .utf8)
    }
}
