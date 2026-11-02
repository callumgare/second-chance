//
//  InfoWindowController.swift
//  WrappTemplate
//
//  Controller for the info/warning window. Hosts InfoWindowView (SwiftUI).

import Foundation
import AppKit
import SwiftUI
import SecondChanceKit
import SecondChanceReporting
import Logging

private nonisolated let infoWindowControllerLogger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.InfoWindow")

var globalInfoWindow: InfoWindowController?

class InfoWindowController: NSWindowController {
    private let viewModel: InfoWindowViewModel
    /// The wrapp's load monitor, observed while the game loads; the window
    /// stops listening once the game has loaded, failed, or the window
    /// closes. The monitor itself runs on for the rest of the wrapp's run,
    /// sampling less often once the game has loaded.
    private let loadMonitor: SystemLoadMonitor?
    /// Watches the launch for signs it's getting somewhere, from `show()`
    /// until the game has loaded, failed, or the window closes.
    let activity: LaunchActivityMonitor?
    let appSupportPath: URL
    var onWarningConfirmed: (() -> Void)?
    /// Offers to start the game without Steam when the launch fails, or may
    /// have. Set before `show()`.
    /// Reports the launch as stuck; see `giveUpIfStuck`.
    var reportStuckLaunch: (() -> (FailureReport, Task<ReportOutcome, Never>))? {
        get { viewModel.reportStuckLaunch }
        set { viewModel.reportStuckLaunch = newValue }
    }

    /// For `applicationShouldTerminate`: quitting while the window says the
    /// launch may have failed reports it as stuck first, and quits again
    /// once that's done. Returns whether it did, in which case the quit
    /// should be cancelled for now. Main thread only.
    func giveUpIfStuck() -> Bool {
        guard viewModel.giveUpIfStuck() else { return false }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    var onLaunchWithoutSteam: (() -> Void)? {
        get { viewModel.onLaunchWithoutSteam }
        set { viewModel.onLaunchWithoutSteam = newValue }
    }

    var onLastSessionChoice: ((InfoWindowViewModel.LastSessionChoice) -> Void)? {
        get { viewModel.onLastSessionChoice }
        set { viewModel.onLastSessionChoice = newValue }
    }

    var onSignInToSteamAfresh: (() -> Void)? {
        get { viewModel.onSignInToSteamAfresh }
        set { viewModel.onSignInToSteamAfresh = newValue }
    }

    var onTryAgain: (() -> Void)? {
        get { viewModel.onTryAgain }
        set { viewModel.onTryAgain = newValue }
    }

    var reportStuckLaunchWithoutQuitting: (() -> Bool)? {
        get { viewModel.reportStuckLaunchWithoutQuitting }
        set { viewModel.reportStuckLaunchWithoutQuitting = newValue }
    }

    var onPossibleFailure: (() -> Void)? {
        get { viewModel.onPossibleFailure }
        set { viewModel.onPossibleFailure = newValue }
    }

    /// Say Steam is slow or stuck signing in, or no longer. Any thread.
    nonisolated func setSteamNotice(_ notice: SteamSignInNotice?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.viewModel.steamNotice = notice
            }
        }
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

    /// `stage` is what the launch waits on first: Steam, for a game that
    /// needs it, or else the game.
    init(stage: LoadingStage, appSupportPath: URL, gameSlug: String = "nancy-drew", gameTitle: String = "Nancy Drew",
         saveWarningEnabled: Bool = true, loadMonitor: SystemLoadMonitor? = nil, activity: LaunchActivityMonitor? = nil) {
        self.appSupportPath = appSupportPath
        self.loadMonitor = loadMonitor
        self.activity = activity

        let shouldShow = saveWarningEnabled && !Self.hasUserDismissedSaveWarning(appSupportPath: appSupportPath)
        self.viewModel = InfoWindowViewModel(stage: stage, saveWarningEnabled: shouldShow, gameSlug: gameSlug, gameTitle: gameTitle)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: InfoWindowView.width, height: 100),
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

        // A launch can take minutes on a busy Mac: floating above every app
        // all that time would cover whatever the player went off to do.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateLevel), name: name, object: nil)
        }

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
        // The monitor calls its observer on the main queue.
        loadMonitor?.observe { [weak self] reading in
            MainActor.assumeIsolated {
                guard let self, !self.viewModel.gameHasLoaded else { return }
                self.viewModel.heavyLoad = reading
            }
        }
        // So does this one.
        activity?.start { [weak self] sign in
            MainActor.assumeIsolated {
                self?.viewModel.noteProgress(sign)
            }
        }
    }

    /// A sign the launch is getting somewhere. Safe from any thread.
    nonisolated func noteProgress(_ sign: LaunchProgressSign) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.viewModel.noteProgress(sign)
            }
        }
    }

    /// Show that the launch has moved on to `stage`. Safe from any thread.
    nonisolated func setStage(_ stage: LoadingStage) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.viewModel.setStage(stage)
                // While Steam waits on the player in its own window, this one
                // mustn't float over it: both open in the middle of the screen,
                // and this one would hide the sign-in's QR code.
                self.updateLevel()
            }
        }
    }

    /// Above other windows while the game app is the one in front (Wine's
    /// own windows open over it otherwise), and not while the player is in
    /// another app. Nor while Steam waits on the player in its own window:
    /// both open in the middle of the screen, and this one would hide the
    /// sign-in's QR code. The closing window floats regardless
    /// (`showQuitting`).
    @objc private func updateLevel() {
        guard let window, !viewModel.phase.isQuitting else { return }
        window.level = NSApp.isActive && !viewModel.stage.isWaitingOnThePlayer ? .floating : .normal
    }

    func notifyGameLoaded() {
        DispatchQueue.main.async {
            self.loadMonitor?.observe(nil)
            self.loadMonitor?.slowDown()
            self.activity?.stop()
            self.viewModel.markGameLoaded()
            self.close()
        }
    }

    /// The wrapp is quitting, and has got as far as `step`. Safe from any
    /// thread. The window shows once the quit has run for
    /// `QuitStep.showAfter`, so a quick one shows nothing, and then follows
    /// each step. Never over the error window: someone reading why the game
    /// failed keeps it.
    nonisolated func quitting(_ step: InfoWindowViewModel.QuitStep) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.quitStep = step
                if self.quitStarted == nil {
                    self.quitStarted = Date()
                    DispatchQueue.main.asyncAfter(deadline: .now() + InfoWindowViewModel.QuitStep.showAfter) {
                        MainActor.assumeIsolated { self.showQuitting() }
                    }
                } else if case .quitting = self.viewModel.phase {
                    self.viewModel.phase = .quitting(step)
                }
            }
        }
    }

    private var quitStarted: Date?
    private var quitStep = InfoWindowViewModel.QuitStep.closing

    private func showQuitting() {
        guard !viewModel.phase.isFailure else { return }
        viewModel.stopTimer()
        loadMonitor?.observe(nil)
        activity?.stop()
        viewModel.heavyLoad = nil
        viewModel.phase = .quitting(quitStep)
        window?.level = .floating
        // Without activating: the wrapp may be hidden from the Dock, and
        // whoever quit it has moved on.
        window?.orderFrontRegardless()
        infoWindowControllerLogger.notice("[Cleanup] Still quitting after \(Int(InfoWindowViewModel.QuitStep.showAfter))s: showing that it's closing")
    }

    /// `explanation` says what went wrong, when the wrapp knows: for a game
    /// that quit unexpectedly rather than crashing. `report` is its failure
    /// report, already being sent by `sending`.
    func showError(exitCode: Int32, explanation: String? = nil,
                   report: FailureReport? = nil, sending: Task<ReportOutcome, Never>? = nil) {
        DispatchQueue.main.async {
            self.loadMonitor?.observe(nil)
            self.activity?.stop()
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

    /// Queued, as `showError` is, so the two stay in order.
    override func close() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.closeNow() }
        }
    }

    private func closeNow() {
        viewModel.stopTimer()
        loadMonitor?.observe(nil)
        activity?.stop()
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
