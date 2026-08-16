//
//  LogWindow.swift
//  Shared
//
//  Floating log window backed by LogStore. Showing the window subscribes to
//  the store: the ring snapshot arrives instantly as history, then live
//  batches stream in from the serial drain queue. Appends are batched (one
//  flush per 100 ms deadline) so a Wine output burst can't flood the main
//  thread with one update per line.
//
//  Rendering is SwiftUI (`LogWindowView`): a Console-style table with
//  Time/Level/Category/Message columns, level-tinted rows, and an options
//  bar (level filter, compact two-column mode). The display state lives in
//  `LogDisplayModel` so the hosted view can observe it without a reference
//  cycle back through the window controller.
//
//  The window controller survives close/reopen (`isReleasedWhenClosed =
//  false`), so each open resets the display before replaying the ring
//  snapshot — otherwise history would duplicate on every reopen.

import Foundation
import AppKit
import SwiftUI
import Combine

public class LogWindow: ObservableObject {
    public static let shared = LogWindow()

    @Published public var isVisible = false

    /// View-bound display state observed by the hosted `LogWindowView`.
    let display = LogDisplayModel()

    private var logWindow: LogWindowController?
    private var cancelSubscription: (@Sendable () -> Void)?

    // Main-confined batching state (all mutation happens on the main actor).
    private var pendingEntries: [Entry] = []
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

    private var cancellables: Set<AnyCancellable> = []

    init() {
        // Compact mode swaps the whole table (SwiftUI's column builder can't
        // build columns conditionally), and filtering changes the row count —
        // both reset the scroll position, so re-follow the tail afterwards
        // for users who were pinned to the bottom.
        display.$compactMode
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refollowTail() }
            .store(in: &cancellables)
        display.$levelFilter
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refollowTail() }
            .store(in: &cancellables)

        // Import must stop live delivery synchronously, before the file's
        // rows replace the display — otherwise a flush racing the import
        // would interleave store lines into the file view.
        display.onImportWillBegin = { [weak self] in
            self?.cancelLogStoreSubscription()
        }
        // Live/file transitions: file mode cancels the LogStore subscription
        // (nothing live is shown); returning to live replays the snapshot —
        // which includes everything emitted while the file was open — and
        // resumes streaming.
        display.$source
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] source in self?.sourceDidChange(source) }
            .store(in: &cancellables)
    }

    private func sourceDidChange(_ source: LogSource) {
        switch source {
        case .importedFile:
            cancelLogStoreSubscription()
            logWindow?.scrollToTop()
        case .live:
            guard isVisible else { return }
            subscribeToLogStore()
            refollowTail()
        }
    }

    /// Give SwiftUI a beat to lay out the rebuilt table, then apply the usual
    /// follow-the-tail scroll (a no-op when the user has scrolled up).
    private func refollowTail() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.logWindow?.scrollToBottomIfPinned()
        }
    }

    // MARK: - Public API

    public func showLogWindow(title: String = "Application Log",
                              relativeTo referenceWindow: NSWindow? = nil) {
        if logWindow == nil {
            logWindow = LogWindowController(title: title, owner: self)
        }
        logWindow?.show(relativeTo: referenceWindow)
        // An imported file stays on display across close/reopen; the live
        // subscription is (re)made only in live mode.
        if case .live = display.source {
            subscribeToLogStore()
        }
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
            // (The @Sendable here is load-bearing: without it this closure
            // would be inferred @MainActor under the project's default
            // isolation, and the drain queue would touch main-actor state.)
            Task { @MainActor [weak self] in
                self?.receive(entries: entries, generation: generation)
            }
        }
        cancelSubscription = cancel

        // The display state persists across close/reopen, so start each
        // session from clean rows: the snapshot replays the full history, and
        // anything still pending from the previous session (or in flight from
        // its cancelled subscription) must not survive.
        display.rows.removeAll()
        display.hiddenLineCount = 0

        // History first, instantly, from the ring snapshot.
        receive(entries: snapshot, generation: generation)
    }

    private func cancelLogStoreSubscription() {
        subscriptionGeneration += 1
        cancelSubscription?()
        cancelSubscription = nil
        pendingEntries.removeAll()
        flushArmed = false
    }

    /// Accumulate a batch of entries and arm a single coalesced flush.
    /// Main-actor confined.
    private func receive(entries: [Entry], generation: Int) {
        guard generation == subscriptionGeneration else { return }
        guard !entries.isEmpty else { return }
        pendingEntries.append(contentsOf: entries)

        for entry in entries {
            onLine?(LogFormatter.compact(entry: entry))
        }

        guard !flushArmed else { return }
        flushArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            self?.flush()
        }
    }

    /// Swap the pending buffer out wholesale and publish the new rows in one
    /// update. Main-actor confined.
    private func flush() {
        flushArmed = false
        guard !pendingEntries.isEmpty else { return }

        var entries = pendingEntries
        pendingEntries.removeAll()

        // Drop the head of a burst that outgrew the view bound between
        // flushes; the store (and Save Logs) still holds everything.
        if entries.count > Self.maxViewLines {
            display.hiddenLineCount += entries.count - Self.maxViewLines
            entries = Array(entries.suffix(Self.maxViewLines))
        }

        display.rows.append(contentsOf: entries.map(LogRow.init(entry:)))

        // Bound the view independently of the store: trim in bulk, not per
        // line, once well past the bound.
        let slack = Self.maxViewLines / 2
        if display.rows.count > Self.maxViewLines + slack {
            let dropped = display.rows.count - Self.maxViewLines
            display.rows.removeFirst(dropped)
            display.hiddenLineCount += dropped
        }

        logWindow?.scrollToBottomIfPinned()
    }

    // MARK: - Window lifecycle

    func windowDidClose() {
        isVisible = false
        cancelLogStoreSubscription()
    }

    // MARK: - Test support

    /// The currently displayed lines, one per row. Test-facing (tests assert
    /// on rendered content rather than `onLine`, which fires per delivery —
    /// including history replays on reopen).
    var displayedTextForTesting: String {
        display.rows.map(\.compactLine).joined(separator: "\n")
    }
}

// MARK: - Log Window Controller

private class LogWindowController: NSWindowController, NSWindowDelegate {
    /// The LogWindow that owns this controller. Window lifecycle callbacks
    /// (windowWillClose) must route through the owner, not a hardcoded
    /// `LogWindow.shared` — non-shared instances (tests) would otherwise
    /// cancel the wrong subscription on close. Named `ownerLogWindow`
    /// because `owner` collides with NSWindowController's own property.
    private weak var ownerLogWindow: LogWindow?

    /// Whether the table is at (or near) the bottom — updated from the clip
    /// view's bounds-change notifications so new batches can follow the tail
    /// (Console.app style) without yanking a user who has scrolled up.
    private var isPinnedToBottom = true
    private var boundsObserver: NSObjectProtocol?
    /// The scroll view currently observed. Compact-mode toggles rebuild the
    /// table (and its scroll view), so the observer must re-attach.
    private weak var observedScrollView: NSScrollView?

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
        setupUI(with: owner.display)
    }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    func windowWillClose(_ notification: Notification) {
        ownerLogWindow?.windowDidClose()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(with model: LogDisplayModel) {
        guard let contentView = window?.contentView else { return }

        let hostingView = NSHostingView(rootView: LogWindowView(model: model))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
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

    /// Follow newly appended rows when the user is at (or near) the bottom,
    /// like Console.app. SwiftUI `Table` exposes no programmatic scrolling,
    /// so this drives its underlying NSScrollView; the lookup degrades to a
    /// no-op if the hosting hierarchy ever changes shape. Runs one runloop
    /// turn after the row publish so the table has laid the new rows out.
    func scrollToBottomIfPinned() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let contentView = self.window?.contentView,
                  let scrollView = Self.firstScrollView(in: contentView),
                  let documentView = scrollView.documentView else { return }

            self.observeBounds(of: scrollView)

            guard self.isPinnedToBottom else { return }
            let clipView = scrollView.contentView
            clipView.scroll(to: NSPoint(x: 0, y: max(0, documentView.bounds.maxY - clipView.bounds.height)))
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    /// Jump to the top after an imported file replaces the rows (files are
    /// naturally read from the start, not the tail).
    func scrollToTop() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let contentView = self.window?.contentView,
                  let scrollView = Self.firstScrollView(in: contentView) else { return }

            self.observeBounds(of: scrollView)
            let clipView = scrollView.contentView
            clipView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    /// Recompute `isPinnedToBottom` whenever the clip view moves (user drag,
    /// wheel, keyboard navigation — programmatic scrolls included, which
    /// leaves it pinned after a follow-the-tail jump). Re-attaches when the
    /// hosting hierarchy swapped in a new scroll view (compact-mode toggle).
    private func observeBounds(of scrollView: NSScrollView) {
        guard observedScrollView !== scrollView else { return }
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSClipView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] notification in
            guard let clipView = notification.object as? NSClipView,
                  let scrollView = clipView.enclosingScrollView else { return }
            MainActor.assumeIsolated {
                self?.updatePinnedState(in: scrollView)
            }
        }
        observedScrollView = scrollView
    }

    private func updatePinnedState(in scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else { return }
        let visible = scrollView.contentView.documentVisibleRect
        isPinnedToBottom = documentView.bounds.maxY - visible.maxY < 60
    }

    /// Depth-first search for the table's scroll view in the hosting hierarchy.
    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) { return scrollView }
        }
        return nil
    }
}
