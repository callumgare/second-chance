//
//  LogWindow.swift
//  Shared
//
//  Manages the floating log window. Combines `log show` (history since app start) with
//  `log stream` (real-time). History is delivered first; the stream then takes over with
//  no polling delay. Hash dedup handles any overlap at the junction.

import Foundation
import AppKit
import Combine

public class LogWindow: ObservableObject {
    public static let shared = LogWindow()

    @Published public var isVisible = false

    private var logWindow: LogWindowController?
    private var streamProcess: Process?
    private var streamReadHandle: FileHandle?
    private var seenLineHashes = Set<Int>()
    private var streamLineBuffer = Data()
    // Serial queue: runLogShow executes first (submitted first), then buffered stream blocks follow.
    private let deliveryQueue = DispatchQueue(label: "com.secondchance.logwindow")

    /// Called for every line received from the log stream. Useful for testing.
    var onLine: ((String) -> Void)?

    init() {}

    // MARK: - Public API

    public func showLogWindow(title: String = "Application Log",
                              relativeTo referenceWindow: NSWindow? = nil) {
        if logWindow == nil {
            logWindow = LogWindowController(title: title)
        }
        logWindow?.show(relativeTo: referenceWindow)
        isVisible = true
    }

    public func hideLogWindow() {
        logWindow?.close()
        isVisible = false
    }

    /// Fetch history via `log show` then hand off to `log stream` for real-time delivery.
    /// `log show` is submitted to `deliveryQueue` first, so history always appears before
    /// buffered stream lines. Hash dedup handles the overlap at the junction.
    public func startStreaming(pid: Int32, since startTime: Date) {
        stopStreaming()
        seenLineHashes.removeAll()
        streamLineBuffer.removeAll()

        startLogStream(pid: pid)

        let since = startTime.addingTimeInterval(-5)
        deliveryQueue.async { [weak self] in
            self?.runLogShow(pid: pid, since: since)
        }
    }

    public func stopStreaming() {
        streamReadHandle?.readabilityHandler = nil
        streamReadHandle = nil
        streamProcess?.terminate()
        streamProcess = nil
    }

    private func startLogStream(pid: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--predicate", "processIdentifier == \(pid) AND subsystem BEGINSWITH 'com.secondchance'",
            "--style", "syslog",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        let readHandle = pipe.fileHandleForReading
        readHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            // Dispatch to deliveryQueue so stream lines are serialised with runLogShow.
            self.deliveryQueue.async { [weak self] in
                guard let self else { return }
                self.streamLineBuffer.append(chunk)
                // Flush complete lines from the buffer.
                while let newlineIdx = self.streamLineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = self.streamLineBuffer[self.streamLineBuffer.startIndex..<newlineIdx]
                    self.streamLineBuffer.removeSubrange(self.streamLineBuffer.startIndex...newlineIdx)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        self.deliver(line)
                    }
                }
            }
        }

        guard (try? process.run()) != nil else { return }
        streamProcess = process
        streamReadHandle = readHandle
    }

    private func runLogShow(pid: Int32, since: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let startStr = formatter.string(from: since)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--start", startStr,
            "--predicate", "processIdentifier == \(pid) AND subsystem BEGINSWITH 'com.secondchance'",
            "--style", "syslog",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            deliver(line)
        }
    }

    /// Must be called on `deliveryQueue`.
    private func deliver(_ line: String) {
        let hash = line.hashValue
        guard !seenLineHashes.contains(hash) else { return }
        seenLineHashes.insert(hash)
        logWindow?.appendLog(line)
        onLine?(line)
    }

    public var window: NSWindow? { logWindow?.window }
}

// MARK: - Log Window Controller

private class LogWindowController: NSWindowController, NSWindowDelegate {
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
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init(window: window)
        window.delegate = self
        setupUI()
    }

    func windowWillClose(_ notification: Notification) {
        LogWindow.shared.isVisible = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        logScrollView = NSScrollView()
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        logScrollView.hasVerticalScroller = true
        logScrollView.hasHorizontalScroller = false
        logScrollView.autohidesScrollers = false
        logScrollView.borderType = .noBorder
        contentView.addSubview(logScrollView)

        let textContainer = NSTextContainer()
        textContainer.containerSize = NSSize(width: 680, height: CGFloat.greatestFiniteMagnitude)
        textContainer.widthTracksTextView = true

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

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

        NSLayoutConstraint.activate([
            logScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            logScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            logScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            logScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    func show(relativeTo referenceWindow: NSWindow? = nil) {
        guard let logWindow = window else { return }
        let screens = NSScreen.screens
        if screens.count > 1, let ref = referenceWindow {
            let refScreen = ref.screen ?? NSScreen.main
            if let other = screens.first(where: { $0 != refScreen }) {
                let f = other.visibleFrame
                logWindow.setFrameOrigin(NSPoint(
                    x: f.origin.x + (f.width - logWindow.frame.width) / 2,
                    y: f.origin.y + (f.height - logWindow.frame.height) / 2
                ))
            }
        } else if let ref = referenceWindow {
            logWindow.setFrameOrigin(NSPoint(x: ref.frame.maxX + 10, y: ref.frame.origin.y))
        }
        logWindow.makeKeyAndOrderFront(nil)
    }

    func appendLog(_ text: String) {
        DispatchQueue.main.async {
            let atBottom = self.isScrolledToBottom()
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            ]
            self.logTextView.textStorage?.append(NSAttributedString(string: text + "\n", attributes: attrs))
            if atBottom {
                if let tc = self.logTextView?.textContainer {
                    self.logTextView?.layoutManager?.ensureLayout(for: tc)
                }
                self.logTextView?.scrollToEndOfDocument(nil)
            }
        }
    }

    private func isScrolledToBottom() -> Bool {
        guard let sv = logScrollView, let dv = sv.documentView else { return true }
        dv.layoutSubtreeIfNeeded()
        let visible = sv.contentView.documentVisibleRect
        return dv.bounds.height - (visible.origin.y + visible.height) < 50
    }
}
