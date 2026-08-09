//
//  InfoWindow.swift
//  GameWrapper
//
//  Info/Warning window management for Nancy Drew game wrappers

import Foundation
import AppKit

// MARK: - Global Reference

var globalInfoWindow: InfoWindowController?

// MARK: - Info Window Controller

class InfoWindowController: NSWindowController {
    private var messageLabel: NSTextField!
    private var spinnerView: NSProgressIndicator!
    private var loadingStackView: NSStackView!
    var warningStackView: NSStackView!  // Public so we can check if warning is shown
    private var confirmButton: NSButton!
    private var dontShowCheckbox: NSButton!
    
    private var gameHasLoaded = false
    private var userHasConfirmed = false
    private var appSupportPath: URL
    private var slowLoadingTimer: Timer?
    var onWarningConfirmed: (() -> Void)?
    
    init(gameTitle: String, appSupportPath: URL, saveWarningEnabled: Bool = true, customMessage: String? = nil) {
        self.appSupportPath = appSupportPath
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 100),  // Temporary height, will be resized
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Nancy Drew"
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
        
        let message = customMessage ?? "Loading \(gameTitle)..."
        setupUI(message: message, saveWarningEnabled: saveWarningEnabled)
        
        // Resize window to fit content
        resizeToFitContent()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI(message: String, saveWarningEnabled: Bool) {
        guard let contentView = window?.contentView else { return }
        
        // Main container stack view
        let containerStack = NSStackView()
        containerStack.orientation = .vertical
        containerStack.alignment = .centerX
        containerStack.spacing = 15  // Fixed spacing between sections
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(containerStack)
        
        // Warning section (now at the top)
        warningStackView = NSStackView()
        warningStackView.orientation = .vertical
        warningStackView.alignment = .centerX
        warningStackView.spacing = 15
        warningStackView.distribution = .gravityAreas  // Fit content without extra spacing
        warningStackView.translatesAutoresizingMaskIntoConstraints = false
        warningStackView.edgeInsets = NSEdgeInsetsZero  // Remove any default padding
        
        // Check if we should show the warning (only if game requires it AND user hasn't dismissed it)
        let shouldShowWarning = saveWarningEnabled && !hasUserDismissedSaveWarning()
        
        // Make warning more prominent with larger, bold text
        let warningLabel = NSTextField(labelWithString: "⚠️ Important: Save Your Progress Regularly!")
        warningLabel.isEditable = false
        warningLabel.isBordered = false
        warningLabel.backgroundColor = .clear
        warningLabel.alignment = .center
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.translatesAutoresizingMaskIntoConstraints = false
        warningLabel.maximumNumberOfLines = 0
        warningLabel.preferredMaxLayoutWidth = 400
        warningLabel.font = NSFont.boldSystemFont(ofSize: 14)  // Bold and larger
        warningLabel.textColor = NSColor.systemOrange  // Orange color for emphasis
        warningStackView.addArrangedSubview(warningLabel)
        
        let descriptionLabel = NSTextField(labelWithString: "This game was not designed to run on modern systems so saving regularly is recommended to avoid losing progress in the event of a crash.")
        descriptionLabel.isEditable = false
        descriptionLabel.isBordered = false
        descriptionLabel.backgroundColor = .clear
        descriptionLabel.alignment = .center
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.maximumNumberOfLines = 0
        descriptionLabel.preferredMaxLayoutWidth = 400
        descriptionLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        descriptionLabel.textColor = NSColor.secondaryLabelColor
        warningStackView.addArrangedSubview(descriptionLabel)
        
        // Bottom row: checkbox on left, button on right
        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 10
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        
        dontShowCheckbox = NSButton(checkboxWithTitle: "Don't show this warning again", target: self, action: nil)
        dontShowCheckbox.translatesAutoresizingMaskIntoConstraints = false
        
        // Set the checkbox text color to match the description (secondary label color)
        let checkboxTitle = NSAttributedString(
            string: "Don't show this warning again",
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ]
        )
        dontShowCheckbox.attributedTitle = checkboxTitle
        
        bottomRow.addArrangedSubview(dontShowCheckbox)
        
        // Spacer to push button to the right
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.addArrangedSubview(spacer)
        
        confirmButton = NSButton(title: "I Understand", target: self, action: #selector(confirmButtonClicked))
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.bezelStyle = .rounded
        bottomRow.addArrangedSubview(confirmButton)
        
        warningStackView.addArrangedSubview(bottomRow)
        
        // Loading section (now at the top)
        loadingStackView = NSStackView()
        loadingStackView.orientation = .vertical
        loadingStackView.alignment = .centerX
        loadingStackView.spacing = 15
        loadingStackView.translatesAutoresizingMaskIntoConstraints = false
        
        spinnerView = NSProgressIndicator()
        spinnerView.style = .spinning
        spinnerView.controlSize = .regular
        spinnerView.translatesAutoresizingMaskIntoConstraints = false
        spinnerView.startAnimation(nil)
        loadingStackView.addArrangedSubview(spinnerView)
        
        messageLabel = NSTextField(labelWithString: message)
        messageLabel.isEditable = false
        messageLabel.isBordered = false
        messageLabel.backgroundColor = .clear
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = 400
        loadingStackView.addArrangedSubview(messageLabel)
        
        containerStack.addArrangedSubview(loadingStackView)
        
        containerStack.addArrangedSubview(warningStackView)
        
        // Set visibility based on whether warning should be shown
        // (Do this after both stack views are created)
        warningStackView.isHidden = !shouldShowWarning
        loadingStackView.isHidden = shouldShowWarning  // Hide loading if warning is shown
        
        // If loading is visible (no warning), start the timer
        // Otherwise timer will start when warning is confirmed
        if !shouldShowWarning {
            // Defer timer start slightly to ensure UI is ready
            DispatchQueue.main.async { [weak self] in
                self?.startLoadingTimer()
            }
        }
        
        // Layout
        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            containerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            containerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            containerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            
            messageLabel.widthAnchor.constraint(equalToConstant: 400),
            warningLabel.widthAnchor.constraint(equalToConstant: 400),
            descriptionLabel.widthAnchor.constraint(equalToConstant: 400),
            bottomRow.widthAnchor.constraint(equalToConstant: 400)
        ])
        
        // If warning is not shown, close window immediately
        if !shouldShowWarning {
            // Window will be closed when game loads via the normal path
        }
    }
    
    func hideWarning() {
        warningStackView.isHidden = true
        loadingStackView.isHidden = false  // Show the loading message
        resizeToFitContent()
        // Start timer since loading begins immediately without warning
        startLoadingTimer()
    }
    
    private func startLoadingTimer() {
        // Start timer to show "taking longer" message after a short amount of time seconds
        slowLoadingTimer?.invalidate()
        slowLoadingTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
            self?.showSlowLoadingMessage()
        }
    }
    
    private func resizeToFitContent() {
        guard let window = window, let contentView = window.contentView else { return }
        
        // Force layout pass
        contentView.layoutSubtreeIfNeeded()
        
        // Get the fitting size for the content
        let fittingSize = contentView.fittingSize
        
        // Calculate new window frame with title bar height
        let titleBarHeight = window.frame.height - contentView.frame.height
        let newHeight = fittingSize.height + titleBarHeight
        
        var newFrame = window.frame
        newFrame.size.height = newHeight
        
        // Adjust origin to keep window centered
        newFrame.origin.y -= (newHeight - window.frame.height) / 2
        
        window.setFrame(newFrame, display: true, animate: false)
    }
    
    @objc private func confirmButtonClicked() {
        userHasConfirmed = true
        
        // Save preference if checkbox is checked
        if dontShowCheckbox.state == .on {
            saveDontShowSaveWarning()
        }
        
        // Hide warning, show loading
        warningStackView.isHidden = true
        loadingStackView.isHidden = false
        
        // Resize window to fit loading content
        resizeToFitContent()
        
        // Start the slow loading timer now that loading is beginning
        startLoadingTimer()
        
        // Notify that warning was confirmed (to trigger game launch)
        onWarningConfirmed?()
    }
    
    private func showSlowLoadingMessage() {
        DispatchQueue.main.async {
            guard !self.gameHasLoaded else { return }
            
            let currentMessage = self.messageLabel?.stringValue ?? ""
            self.messageLabel?.stringValue = currentMessage + "\n\nThis is taking longer than expected. Please be patient..."
            self.resizeToFitContent()
        }
    }
    
    func show() {
        window?.makeKeyAndOrderFront(nil)
    }
    
    func updateMessage(_ message: String) {
        DispatchQueue.main.async {
            self.messageLabel?.stringValue = message
        }
    }
    
    func notifyGameLoaded() {
        DispatchQueue.main.async {
            self.gameHasLoaded = true
            self.close()
            
            // Don't quit automatically - let the termination handler ask the user
            // when the game exits
        }
    }
    
    private func hasUserDismissedSaveWarning() -> Bool {
        let prefFile = appSupportPath.appendingPathComponent("dont-show-save-warning")
        return FileManager.default.fileExists(atPath: prefFile.path)
    }
    
    private func saveDontShowSaveWarning() {
        let prefFile = appSupportPath.appendingPathComponent("dont-show-save-warning")
        try? "true".write(to: prefFile, atomically: true, encoding: .utf8)
    }
    
    override func close() {
        slowLoadingTimer?.invalidate()
        slowLoadingTimer = nil
        spinnerView?.stopAnimation(nil)
        window?.close()
    }
}

// MARK: - Alert Display

func showAlert(message: String, informativeText: String) {
    // Initialize NSApplication if not already done
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = informativeText
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
