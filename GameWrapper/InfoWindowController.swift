//
//  InfoWindowController.swift
//  GameWrapper
//
//  Controller for the info/warning window. Hosts InfoWindowView (SwiftUI).

import Foundation
import AppKit
import SwiftUI

var globalInfoWindow: InfoWindowController?

class InfoWindowController: NSWindowController {
    private let viewModel: InfoWindowViewModel
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
    }

    func updateMessage(_ message: String) {
        DispatchQueue.main.async {
            self.viewModel.message = message
        }
    }

    func notifyGameLoaded() {
        DispatchQueue.main.async {
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
            self.viewModel.showError(exitCode: exitCode)
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    override func close() {
        viewModel.stopTimer()
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
