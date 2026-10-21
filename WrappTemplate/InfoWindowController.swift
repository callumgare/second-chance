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
    /// The wrapp's load monitor, observed while the game loads; the window
    /// stops listening once the game has loaded, failed, or the window
    /// closes. The monitor itself runs on for the rest of the wrapp's run,
    /// sampling less often once the game has loaded.
    private let loadMonitor: SystemLoadMonitor?
    let appSupportPath: URL
    var onWarningConfirmed: (() -> Void)?
    /// Offers to start the game without Steam when the launch fails, or may
    /// have. Set before `show()`.
    var onLaunchWithoutSteam: (() -> Void)? {
        get { viewModel.onLaunchWithoutSteam }
        set { viewModel.onLaunchWithoutSteam = newValue }
    }

    /// Whether the save warning is currently visible.
    var isShowingWarning: Bool {
        if case .warning = viewModel.phase { return true }
        return false
    }

    /// The middle of the save warning's I Understand button, in window
    /// coordinates; nil unless the warning is showing.
    var confirmButtonLocation: NSPoint? {
        guard isShowingWarning, let hostingView = window?.contentView, viewModel.confirmButtonFrame != .zero else { return nil }
        let frame = viewModel.confirmButtonFrame
        return hostingView.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
    }

    /// For logs: where the button was measured, and the hosting view's size.
    var confirmButtonGeometry: String {
        "button \(viewModel.confirmButtonFrame) in a \(window?.contentView?.frame.size ?? .zero) view"
    }

    /// What I Understand does, without clicking it.
    func pressConfirm() {
        viewModel.confirm()
    }

    /// Whether the game has successfully loaded (info window was dismissed).
    var hasGameLoaded: Bool {
        viewModel.gameHasLoaded
    }

    /// `stage` is what the launch waits on first: Steam, for a game that
    /// needs it, or else the game.
    init(stage: LoadingStage, appSupportPath: URL, gameSlug: String = "nancy-drew", gameTitle: String = "Nancy Drew",
         saveWarningEnabled: Bool = true, loadMonitor: SystemLoadMonitor? = nil) {
        self.appSupportPath = appSupportPath
        self.loadMonitor = loadMonitor

        let shouldShow = saveWarningEnabled && !Self.hasUserDismissedSaveWarning(appSupportPath: appSupportPath)
        self.viewModel = InfoWindowViewModel(stage: stage, saveWarningEnabled: shouldShow, gameSlug: gameSlug)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = gameTitle
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
        loadMonitor?.observe { [weak self] reading in
            guard let self, !self.viewModel.gameHasLoaded else { return }
            self.viewModel.heavyLoad = reading
        }
    }

    /// Show that the launch has moved on to `stage`. Safe from any thread.
    func setStage(_ stage: LoadingStage) {
        DispatchQueue.main.async {
            self.viewModel.setStage(stage)
        }
    }

    func notifyGameLoaded() {
        DispatchQueue.main.async {
            self.loadMonitor?.observe(nil)
            self.loadMonitor?.slowDown()
            self.viewModel.markGameLoaded()
            self.close()
        }
    }

    func hideWarning() {
        viewModel.phase = .loading
        viewModel.startStageTimers()
    }

    /// `explanation` says what went wrong, when the wrapp knows: for a game
    /// that quit unexpectedly rather than crashing. `report` is its failure
    /// report, already being sent by `sending`.
    func showError(exitCode: Int32, explanation: String? = nil,
                   report: FailureReport? = nil, sending: Task<ReportOutcome, Never>? = nil) {
        DispatchQueue.main.async {
            self.loadMonitor?.observe(nil)
            self.viewModel.heavyLoad = nil
            if let report, let sending {
                self.viewModel.failureReport.track(report, sending: sending)
            }
            self.viewModel.showError(exitCode: exitCode, explanation: explanation)
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
        loadMonitor?.observe(nil)
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
