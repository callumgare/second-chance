//
//  LogManager.swift
//  Shared
//
//  Centralized logging management with visual log window

import Foundation
import AppKit

// MARK: - Log Manager

/// Singleton manager for application logging with visual output
public class LogManager {
    public static let shared = LogManager()
    
    private var logWindow: LogWindowController?
    private var stdoutRedirectPipe: Pipe?
    private var originalStdoutFD: Int32 = -1
    private var logFileHandle: FileHandle?
    
    private init() {}
    
    // MARK: - Public API
    
    /// Configure and show the log window
    /// - Parameters:
    ///   - title: Window title (default: "Application Log")
    ///   - relativeTo: Optional reference window for positioning
    ///   - logFilePath: Optional file path for writing logs to disk
    public func showLogWindow(title: String = "Application Log", 
                             relativeTo referenceWindow: NSWindow? = nil,
                             logFilePath: String? = nil) {
        // Create log window if needed
        if logWindow == nil {
            logWindow = LogWindowController(title: title)
        }
        
        // Show the window
        logWindow?.show(relativeTo: referenceWindow)
        
        // Set up log file if provided
        if let path = logFilePath {
            setupLogFile(path: path)
        }
    }
    
    /// Start redirecting stdout/stderr to the log window and optionally to file
    /// Call this after showLogWindow() if you want visual output, or call it standalone for file-only logging
    public func startRedirectingOutput(toFile filePath: String? = nil) {
        if let path = filePath {
            setupLogFile(path: path)
        }
        redirectStdoutToLogWindow()
    }
    
    /// Manually append a log message (useful before stdout redirection is set up)
    public func log(_ message: String) {
        DispatchQueue.main.async {
            self.logWindow?.appendLog(message)
        }
        
        // Also write to file if configured
        if let fileHandle = logFileHandle, let data = (message + "\n").data(using: .utf8) {
            try? fileHandle.write(contentsOf: data)
        }
    }
    
    /// Get the log window (if it exists) for custom positioning or manipulation
    public var window: NSWindow? {
        return logWindow?.window
    }
    
    // MARK: - Private Implementation
    
    private func setupLogFile(path: String) {
        guard logFileHandle == nil else { return }
        
        let fileURL = URL(fileURLWithPath: path)
        
        // Create directory if needed
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        // Create or open log file
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        
        logFileHandle = try? FileHandle(forWritingTo: fileURL)
        try? logFileHandle?.seekToEnd()
    }
    
    private func redirectStdoutToLogWindow() {
        let pipe = Pipe()
        stdoutRedirectPipe = pipe  // Keep pipe alive
        
        // Check if stdout is connected to a terminal (only if not already saved)
        if originalStdoutFD < 0 {
            let stdoutIsTerminal = isatty(STDOUT_FILENO) != 0
            
            if stdoutIsTerminal {
                // Save original stdout so we can write to both console and window
                originalStdoutFD = dup(STDOUT_FILENO)
            }
        }
        
        // Redirect stdout and stderr to the pipe
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        
        // Disable buffering on stdout and stderr so output appears immediately
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        
        // Set up notification-based reading
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            forName: .NSFileHandleDataAvailable,
            object: pipe.fileHandleForReading,
            queue: nil
        ) { [weak self] _ in
            let data = pipe.fileHandleForReading.availableData
            
            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                // Write to original console if it's a valid terminal
                if let originalFD = self?.originalStdoutFD, originalFD >= 0 {
                    if let outputData = output.data(using: .utf8) {
                        _ = write(originalFD, (outputData as NSData).bytes, outputData.count)
                    }
                }
                
                // Write to log file if configured
                if let fileHandle = self?.logFileHandle, let outputData = output.data(using: .utf8) {
                    try? fileHandle.write(contentsOf: outputData)
                }
                
                // Send to log window
                let trimmed = output.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty {
                    DispatchQueue.main.async {
                        self?.logWindow?.appendLog(trimmed)
                    }
                }
            }
            
            // Continue listening for more data
            pipe.fileHandleForReading.waitForDataInBackgroundAndNotify()
        }
        
        // Start listening
        pipe.fileHandleForReading.waitForDataInBackgroundAndNotify()
    }
}

// MARK: - Log Window Controller

private class LogWindowController: NSWindowController {
    private var logTextView: NSTextView!
    private var logScrollView: NSScrollView!
    
    init(title: String = "Application Log") {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 200)
        
        // Keep window visible even when app is in accessory mode (dock hidden)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        super.init(window: window)
        
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        
        // Log scroll view
        logScrollView = NSScrollView()
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        logScrollView.hasVerticalScroller = true
        logScrollView.hasHorizontalScroller = false
        logScrollView.autohidesScrollers = false
        logScrollView.borderType = .noBorder
        contentView.addSubview(logScrollView)
        
        // Create text container with proper width tracking
        let textContainer = NSTextContainer()
        textContainer.containerSize = NSSize(width: 680, height: CGFloat.greatestFiniteMagnitude)
        textContainer.widthTracksTextView = true
        
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)
        
        // Log text view with proper configuration
        logTextView = NSTextView(frame: .zero, textContainer: textContainer)
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.textColor = NSColor.labelColor
        logTextView.textContainerInset = NSSize(width: 10, height: 10)
        logTextView.backgroundColor = NSColor.textBackgroundColor
        logTextView.autoresizingMask = [.width]
        logTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        
        logScrollView.documentView = logTextView
        
        // Layout
        NSLayoutConstraint.activate([
            logScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            logScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            logScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            logScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }
    
    func show(relativeTo referenceWindow: NSWindow? = nil) {
        guard let logWindow = window else { return }
        
        // Check if there are multiple displays
        let screens = NSScreen.screens
        
        if screens.count > 1, let referenceWindow = referenceWindow {
            // Multiple displays: place log window on a different screen
            let referenceScreen = referenceWindow.screen ?? NSScreen.main
            
            // Find a different screen
            if let differentScreen = screens.first(where: { $0 != referenceScreen }) {
                // Center on the different screen
                let screenFrame = differentScreen.visibleFrame
                let windowFrame = logWindow.frame
                let newOrigin = NSPoint(
                    x: screenFrame.origin.x + (screenFrame.width - windowFrame.width) / 2,
                    y: screenFrame.origin.y + (screenFrame.height - windowFrame.height) / 2
                )
                logWindow.setFrameOrigin(newOrigin)
            }
        } else if let referenceWindow = referenceWindow {
            // Single display: position to the right of the reference window
            let referenceFrame = referenceWindow.frame
            let newOrigin = NSPoint(
                x: referenceFrame.maxX + 10,
                y: referenceFrame.origin.y
            )
            logWindow.setFrameOrigin(newOrigin)
        }
        
        logWindow.makeKeyAndOrderFront(nil)
    }
    
    func appendLog(_ text: String) {
        DispatchQueue.main.async {
            // Check if we're currently scrolled to the bottom before adding new content
            let shouldAutoScroll = self.isScrolledToBottom()
            
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            ]
            let attributedString = NSAttributedString(string: text + "\n", attributes: attributes)
            self.logTextView.textStorage?.append(attributedString)
            
            // Only auto-scroll to bottom if we were already at the bottom
            if shouldAutoScroll {
                // Force layout update before scrolling
                if let textContainer = self.logTextView?.textContainer {
                    self.logTextView?.layoutManager?.ensureLayout(for: textContainer)
                }
                
                // Scroll to the very end
                self.logTextView?.scrollToEndOfDocument(nil)
            }
        }
    }
    
    private func isScrolledToBottom() -> Bool {
        guard let scrollView = self.logScrollView else { return true }
        guard let documentView = scrollView.documentView else { return true }
        
        // Force layout to get accurate measurements
        documentView.layoutSubtreeIfNeeded()
        
        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.bounds.height
        
        // Consider "at bottom" if we're within 50 points of the bottom
        // Increased tolerance to handle layout variations more reliably
        let distanceFromBottom = documentHeight - (visibleRect.origin.y + visibleRect.height)
        return distanceFromBottom < 50
    }
}
