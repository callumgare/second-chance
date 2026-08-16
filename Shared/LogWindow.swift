//
//  LogWindow.swift
//  Shared
//
//  Floating log window backed by LogStore. Showing the window subscribes to
//  the store: the ring snapshot arrives instantly as history, then live
//  batches stream in from the serial drain queue. Appends are batched (one
//  flush per 100 ms deadline) so a Wine output burst can't flood the main
//  thread with one layout pass per line.
//
//  The window controller (and its text storage) survives close/reopen
//  (`isReleasedWhenClosed = false`), so each open resets the display before
//  replaying the ring snapshot — otherwise history would duplicate on every
//  reopen.

import Foundation
import AppKit
import Combine

public class LogWindow: ObservableObject {
    public static let shared = LogWindow()

    @Published public var isVisible = false

    private var logWindow: LogWindowController?
    private var cancelSubscription: (@Sendable () -> Void)?

    // Main-confined batching state (all mutation happens on the main actor).
    private var pendingLines: [String] = []
    private var flushArmed = false
    /// Bumped whenever the LogStore subscription is cancelled. Deliveries
    /// already in flight (hopping from the drain queue to the main actor)
    /// carry the generation they were sent under and are dropped if stale —
    /// otherwise a batch racing a close/reopen could land after the display
    /// reset and duplicate lines that the snapshot replays.
    private var subscriptionGeneration = 0

    /// Flush window: batches accumulate for at most this long before display.
    static let flushInterval: TimeInterval = 0.1
    /// View-only bound; the store keeps 50k entries for export regardless.
    static let maxViewLines = 5_000

    /// Called for every line delivered to the window. Useful for testing.
    var onLine: ((String) -> Void)?

    init() {}

    // MARK: - Public API

    public func showLogWindow(title: String = "Application Log",
                              relativeTo referenceWindow: NSWindow? = nil) {
        if logWindow == nil {
            logWindow = LogWindowController(title: title, owner: self)
        }
        logWindow?.show(relativeTo: referenceWindow)
        subscribeToLogStore()
        isVisible = true
    }

    public func hideLogWindow() {
        logWindow?.close()
        isVisible = false
    }

    public var window: NSWindow? { logWindow?.window }

    // MARK: - LogStore subscription

    private func subscribeToLogStore() {
        cancelLogStoreSubscription()

        let generation = subscriptionGeneration
        let (snapshot, cancel) = LogStore.shared.subscribe { [weak self] entries in
            // Called on LogStore's serial drain queue — hop to the main actor.
            let lines = entries.map { LogFormatter.compact(entry: $0) }
            Task { @MainActor [weak self] in
                self?.receive(lines: lines, generation: generation)
            }
        }
        cancelSubscription = cancel

        // The controller (and its text storage) persists across close/reopen,
        // so start each session from a clean display: the snapshot replays the
        // full history, and anything still pending from the previous session
        // (or in flight from its cancelled subscription) must not survive.
        logWindow?.resetDisplay()

        // History first, instantly, from the ring snapshot.
        receive(lines: snapshot.map { LogFormatter.compact(entry: $0) }, generation: generation)
    }

    private func cancelLogStoreSubscription() {
        subscriptionGeneration += 1
        cancelSubscription?()
        cancelSubscription = nil
        pendingLines.removeAll()
        flushArmed = false
    }

    /// Accumulate a batch of lines and arm a single coalesced flush.
    /// Main-actor confined.
    private func receive(lines: [String], generation: Int) {
        guard generation == subscriptionGeneration else { return }
        guard !lines.isEmpty else { return }
        pendingLines.append(contentsOf: lines)

        for line in lines {
            onLine?(line)
        }

        guard !flushArmed else { return }
        flushArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            self?.flush()
        }
    }

    /// Swap the pending buffer out wholesale and hand it to the view in one
    /// attributed-string append. Main-actor confined.
    private func flush() {
        flushArmed = false
        guard !pendingLines.isEmpty else { return }

        var lines = pendingLines
        pendingLines.removeAll()

        // Drop the middle when a burst outgrew the view bound between flushes.
        if lines.count > Self.maxViewLines {
            let omitted = lines.count - Self.maxViewLines
            lines = ["[--- \(omitted) lines omitted from view (still in export) ---]"] + lines.suffix(Self.maxViewLines)
        }

        logWindow?.appendBatch(lines)
    }

    // MARK: - Window lifecycle

    func windowDidClose() {
        isVisible = false
        cancelLogStoreSubscription()
    }

    // MARK: - Test support

    /// The currently displayed text. Test-facing (tests assert on rendered
    /// content rather than `onLine`, which fires per delivery — including
    /// history replays on reopen).
    var displayedTextForTesting: String {
        logWindow?.textStorageString ?? ""
    }
}

// MARK: - Log Window Controller

private class LogWindowController: NSWindowController, NSWindowDelegate {
    private var logTextView: NSTextView!
    private var logScrollView: NSScrollView!
    /// Approximate line count currently held by the text storage.
    private var viewLineCount = 0
    /// The LogWindow that owns this controller. Window lifecycle callbacks
    /// (windowWillClose) must route through the owner, not a hardcoded
    /// `LogWindow.shared` — non-shared instances (tests) would otherwise
    /// cancel the wrong subscription on close. Named `ownerLogWindow`
    /// because `owner` collides with NSWindowController's own property.
    private weak var ownerLogWindow: LogWindow?

    init(title: String = "Application Log", owner: LogWindow) {
        self.ownerLogWindow = owner
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
        ownerLogWindow?.windowDidClose()
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
        layoutManager.allowsNonContiguousLayout = true
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

    /// The log window's current text content.
    var textStorageString: String {
        logTextView.string ?? ""
    }

    /// Clear the display for a fresh session. Called when the owning
    /// LogWindow (re)subscribes, before the history snapshot is delivered —
    /// the text storage persists across close/reopen.
    func resetDisplay() {
        guard let textStorage = logTextView.textStorage else { return }
        guard textStorage.length > 0 else { return }
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: "")
        textStorage.endEditing()
        viewLineCount = 0
    }

    /// Append a whole batch of lines as one attributed string, one layout
    /// pass and one scroll. Trims the view to roughly the last
    /// `LogWindow.maxViewLines` lines.
    func appendBatch(_ lines: [String]) {
        guard let textStorage = logTextView.textStorage, !lines.isEmpty else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        ]

        let atBottom = isScrolledToBottom()
        let text = lines.joined(separator: "\n") + "\n"

        textStorage.beginEditing()
        textStorage.append(NSAttributedString(string: text, attributes: attrs))
        viewLineCount += lines.count
        trimIfNeeded(textStorage: textStorage)
        textStorage.endEditing()

        if atBottom {
            logTextView.scrollToEndOfDocument(nil)
        }
    }

    /// Bound the view independently of the store: trim to the last
    /// ~maxViewLines lines, snapped to a newline boundary.
    private func trimIfNeeded(textStorage: NSTextStorage) {
        let slack = LogWindow.maxViewLines / 2  // trim in bulk, not per line
        guard viewLineCount > LogWindow.maxViewLines + slack else { return }

        let linesToDrop = viewLineCount - LogWindow.maxViewLines
        let string = textStorage.mutableString
        var dropped = 0
        var index = 0
        while dropped < linesToDrop && index < string.length {
            let newlineRange = string.range(of: "\n", options: [], range: NSRange(location: index, length: string.length - index))
            guard newlineRange.location != NSNotFound else { break }
            index = newlineRange.location + 1
            dropped += 1
        }

        if index > 0 {
            textStorage.deleteCharacters(in: NSRange(location: 0, length: index))
            viewLineCount -= dropped
        }
    }

    private func isScrolledToBottom() -> Bool {
        guard let sv = logScrollView, let dv = sv.documentView else { return true }
        let visible = sv.contentView.documentVisibleRect
        return dv.bounds.height - (visible.origin.y + visible.height) < 50
    }
}
