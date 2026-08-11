//
//  PermissionWaitWindow.swift
//  GamePuppeteer
//
//  Small progress window shown while waiting for macOS permission grants.

import Foundation
import AppKit

final class PermissionWaitWindowController: NSWindowController {
    private let messageLabel: NSTextField
    private let instructionsLabel: NSTextField
    private let spinnerView: NSProgressIndicator
    private let manualConfirmationRequired: Bool
    private let systemSettingsAnchor: String
    private let manualConfirmButton: NSButton
    private let openSystemSettingsButton: NSButton
    private let showInFinderButton: NSButton

    private(set) var didRequestManualConfirmation = false
    var requiresManualConfirmation: Bool { manualConfirmationRequired }

    init(
        permissionName: String,
        instructions: String,
        manualConfirmationRequired: Bool,
        systemSettingsAnchor: String
    ) {
        self.manualConfirmationRequired = manualConfirmationRequired
        self.systemSettingsAnchor = systemSettingsAnchor

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: manualConfirmationRequired ? 240 : 210),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "GamePuppeteer"
        window.level = .floating
        window.isReleasedWhenClosed = false

        spinnerView = NSProgressIndicator()
        spinnerView.style = .spinning
        spinnerView.controlSize = .regular
        spinnerView.translatesAutoresizingMaskIntoConstraints = false

        manualConfirmButton = NSButton(title: "I've Added Permission", target: nil, action: nil)
        manualConfirmButton.bezelStyle = .rounded
        manualConfirmButton.translatesAutoresizingMaskIntoConstraints = false

        openSystemSettingsButton = NSButton(title: "Open System Settings", target: nil, action: nil)
        openSystemSettingsButton.bezelStyle = .rounded
        openSystemSettingsButton.translatesAutoresizingMaskIntoConstraints = false

        showInFinderButton = NSButton(title: "Show App In Finder", target: nil, action: nil)
        showInFinderButton.bezelStyle = .rounded
        showInFinderButton.translatesAutoresizingMaskIntoConstraints = false

        messageLabel = NSTextField(labelWithString: "Waiting for \(permissionName) permission...")
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.font = NSFont.boldSystemFont(ofSize: 14)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        var effectiveInstructions = instructions
        if manualConfirmationRequired {
            // Screen Recording permission changes are not reliably observable in-process
            // on all macOS versions, so manual confirmation is required.
            effectiveInstructions += "\n\nAutomatic detection is unavailable here. After granting permission, click 'I've Added Permission'."
        }

        instructionsLabel = NSTextField(labelWithString: effectiveInstructions)
        instructionsLabel.alignment = .center
        instructionsLabel.lineBreakMode = .byWordWrapping
        instructionsLabel.maximumNumberOfLines = 0
        instructionsLabel.font = NSFont.systemFont(ofSize: 12)
        instructionsLabel.textColor = NSColor.secondaryLabelColor
        instructionsLabel.translatesAutoresizingMaskIntoConstraints = false

        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 14
        stackView.translatesAutoresizingMaskIntoConstraints = false

        if !manualConfirmationRequired {
            stackView.addArrangedSubview(spinnerView)
        }
        stackView.addArrangedSubview(messageLabel)
        stackView.addArrangedSubview(instructionsLabel)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .gravityAreas
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        if manualConfirmationRequired {
            manualConfirmButton.target = self
            manualConfirmButton.action = #selector(confirmPermissionManually)
            manualConfirmButton.keyEquivalent = "\r"
        }

        openSystemSettingsButton.target = self
        openSystemSettingsButton.action = #selector(openSystemSettings)
        buttonRow.addArrangedSubview(openSystemSettingsButton)

        showInFinderButton.target = self
        showInFinderButton.action = #selector(showAppInFinder)
        buttonRow.addArrangedSubview(showInFinderButton)

        if manualConfirmationRequired {
            buttonRow.addArrangedSubview(manualConfirmButton)
            window?.defaultButtonCell = manualConfirmButton.cell as? NSButtonCell
        }
        stackView.addArrangedSubview(buttonRow)

        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            messageLabel.widthAnchor.constraint(equalToConstant: 440),
            instructionsLabel.widthAnchor.constraint(equalToConstant: 440),
        ])
    }

    func show() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        if !manualConfirmationRequired {
            spinnerView.startAnimation(nil)
        }
        pumpUIEvents(until: Date(timeIntervalSinceNow: 0.05))
    }

    func waitForManualConfirmation(timeout: TimeInterval) -> Bool {
        guard manualConfirmationRequired else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if didRequestManualConfirmation {
                return true
            }
            pumpUIEvents(until: Date().addingTimeInterval(0.1))
        }

        return false
    }

    func pumpUIEvents(until deadline: Date) {
        while let event = NSApp.nextEvent(
            matching: .any,
            until: deadline,
            inMode: .default,
            dequeue: true
        ) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }

    override func close() {
        if !manualConfirmationRequired {
            spinnerView.stopAnimation(nil)
        }
        super.close()
    }

    @objc
    private func confirmPermissionManually() {
        didRequestManualConfirmation = true
    }

    @objc
    private func showAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc
    private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(systemSettingsAnchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
