//
//  MacScreenWindow.swift
//  WrappTemplate
//
//  Basilisk II's Mac, shown in a window of the wrapp's own rather than in
//  Basilisk II's: the window is the game's app's, with its menu bar, its
//  Dock icon and its fullscreen. The picture comes from the in-process
//  helper (basilisk_display.m) through MacScreenServer, and the keys and the
//  mouse go back the same way, to the Mac's ADB
//  (docs/modules.md#the-mac-in-the-wrapps-window).

import AppKit
import Logging
import QuartzCore
import SecondChanceKit
import Synchronization

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.MacScreen")

/// The window, and what reads the helper for it.
final class MacScreenWindowController: NSObject, NSWindowDelegate {
    private let server: MacScreenServer
    private let title: String
    private var window: NSWindow?
    private var screenView: MacScreenView?
    /// The picture's latest frame, handed from the reading thread to the main one.
    private let pending = Mutex<PendingFrame>(PendingFrame())
    /// Whether it showed the Mac, once known: what `waitUntilShown` waits on.
    private var shown: Bool?
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    private struct PendingFrame {
        var buffer: MacScreenBuffer?
        var image: CGImage?
        var covered = false
        var scheduled = false
        var framesTold = 0
    }

    init(server: MacScreenServer, title: String) {
        self.server = server
        self.title = title
        super.init()
    }

    /// Reads the helper from now on.
    func start() {
        server.start { [weak self] event in self?.handle(event) }
    }

    /// Until the Mac is first shown (true), or won't be here: the helper left
    /// it to Basilisk II's own window, or went first (false).
    func waitUntilShown() async -> Bool {
        if let shown { return shown }
        return await withCheckedContinuation { waiting.append($0) }
    }

    private func settle(_ value: Bool) {
        guard shown == nil else { return }
        shown = value
        let continuations = waiting
        waiting = []
        continuations.forEach { $0.resume(returning: value) }
    }

    // MARK: - The helper's events (its reading thread)

    private nonisolated func handle(_ event: MacScreenEvent) {
        switch event {
        case .hello(let pid, let armed):
            logger.notice("[MacScreen] Basilisk II (PID \(pid)) \(armed ? "shows the Mac here" : "shows the Mac in its own window")")
            if !armed { DispatchQueue.main.async { MainActor.assumeIsolated { self.settle(false) } } }
        case .screen(let buffer):
            logger.notice("[MacScreen] The Mac's screen is \(buffer.width)x\(buffer.height)")
            pending.withLock { $0.buffer = buffer }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.showScreen(width: buffer.width, height: buffer.height) } }
        case .frame(let changed, let covered):
            frame(changed: changed, covered: covered)
        case .focus:
            DispatchQueue.main.async { MainActor.assumeIsolated { self.focus() } }
        case .yield(let pid):
            DispatchQueue.main.async { MainActor.assumeIsolated { self.yield(to: pid) } }
        case .ended(let why):
            logger.notice("[MacScreen] The Mac's screen has ended: \(why)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.settle(false)
                    self.window?.orderOut(nil)
                }
            }
        }
    }

    /// A picture of the screen is made here, off the main thread, and the
    /// main thread shows only the latest: a busy main thread skips frames
    /// rather than queueing them.
    private nonisolated func frame(changed: CGRect?, covered: Bool) {
        let schedule = pending.withLock { state -> Bool in
            let first = state.framesTold == 0
            state.framesTold += 1
            guard changed != nil || covered != state.covered || first else { return false }
            state.covered = covered
            state.image = covered ? nil : state.buffer?.image()
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.showLatestFrame() } }
    }

    private func showLatestFrame() {
        let (image, covered) = pending.withLock { state -> (CGImage?, Bool) in
            state.scheduled = false
            return (state.image, state.covered)
        }
        screenView?.show(image)
        if image != nil || covered, window?.isVisible == false { window?.makeKeyAndOrderFront(nil) }
        if image != nil || covered { settle(true) }
    }

    // MARK: - The window

    private func showScreen(width: Int, height: Int) {
        let size = NSSize(width: width, height: height)
        if let window, let screenView {
            guard screenView.macSize != size else {
                server.redraw()
                return
            }
            screenView.macSize = size
            window.contentAspectRatio = size
            window.setContentSize(Self.initialSize(for: size, on: window.screen))
            server.redraw()
            return
        }
        let view = MacScreenView(server: server, macSize: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.initialSize(for: size, on: NSScreen.main)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = view
        window.contentAspectRatio = size
        window.contentMinSize = size
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        screenView = view
        window.makeFirstResponder(view)
        installWindowMenu()
        // Shown at the first frame, so it never opens empty.
        server.redraw()
        observeActivation()
    }

    /// The Mac's screen at the biggest whole multiple that fits the screen
    /// it opens on: whole Mac pixels stay square, as the Mac drew them.
    private static func initialSize(for size: NSSize, on screen: NSScreen?) -> NSSize {
        let room = screen?.visibleFrame.size ?? size
        let titleBar: CGFloat = 32
        let scale = max(1, min(floor(room.width / size.width), floor((room.height - titleBar) / size.height)))
        return NSSize(width: size.width * scale, height: size.height * scale)
    }

    /// Window ▸ Minimize, Zoom and Enter Full Screen, as a Mac app has.
    private func installWindowMenu() {
        guard let mainMenu = NSApp.mainMenu, NSApp.windowsMenu == nil else { return }
        let menu = NSMenu(title: String(localized: "Window"))
        menu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let fullScreen = menu.addItem(withTitle: String(localized: "Enter Full Screen"),
                                      action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        let item = NSMenuItem()
        item.submenu = menu
        mainMenu.addItem(item)
        NSApp.windowsMenu = menu
    }

    private func observeActivation() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tellWindowState() }
            }
        }
    }

    /// The window's state, for puppet control's `state`.
    private func tellWindowState() {
        guard let window else { return }
        let size = window.contentLayoutRect.size
        server.windowState(fullscreen: window.styleMask.contains(.fullScreen), key: window.isKeyWindow, active: NSApp.isActive,
                           width: Int(size.width), height: Int(size.height))
    }

    private func focus() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func yield(to pid: Int32) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.yieldActivation(to: app)
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { tellWindowState() }

    func windowDidResignKey(_ notification: Notification) {
        // Keys and buttons held as the window lost them would stay down on
        // the Mac: their releases go elsewhere.
        screenView?.releaseEverything()
        tellWindowState()
    }

    func windowDidResize(_ notification: Notification) { tellWindowState() }
    func windowDidEnterFullScreen(_ notification: Notification) { tellWindowState() }
    func windowDidExitFullScreen(_ notification: Notification) { tellWindowState() }

    /// Closing the Mac's window is quitting the game, as closing Basilisk
    /// II's was: the app quits, shutting the Mac down.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}

/// The Mac's screen, scaled to fit, and what the Mac's keyboard and mouse
/// are while it's key.
final class MacScreenView: NSView {
    private let server: MacScreenServer
    var macSize: NSSize {
        didSet { needsLayout = true }
    }
    /// The picture, in a layer of its own placed where `pictureRect` says:
    /// AppKit sets the gravity of a view's own layer from its
    /// `layerContentsPlacement`, which stretched the picture to the view, so
    /// fullscreen showed the Mac out of shape, its clicks off where it was.
    private let pictureLayer = CALayer()
    private var heldKeys: Set<UInt16> = []
    private var heldButtons: Set<Int> = []
    private var trackingArea: NSTrackingArea?

    /// The pointer hidden over the picture: the Mac draws its own.
    private static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    /// The keys the wrapp's menus keep, rather than the Mac getting them:
    /// Quit, Hide, Hide Others, Minimize, Full Screen.
    private static let keptKeys: [(key: String, modifiers: NSEvent.ModifierFlags)] = [
        ("q", [.command]), ("h", [.command]), ("h", [.command, .option]), ("m", [.command]), ("f", [.command, .control]),
    ]

    init(server: MacScreenServer, macSize: NSSize) {
        self.server = server
        self.macSize = macSize
        super.init(frame: NSRect(origin: .zero, size: macSize))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        pictureLayer.contentsGravity = .resize
        pictureLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(pictureLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A picture of the screen, or black (nil) while the Mac is covered.
    func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.contents = image
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.frame = pictureRect
        pictureLayer.contentsScale = window?.backingScaleFactor ?? 1
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
        // Whole Mac pixels stay sharp at a whole multiple, and are smoothed
        // between, where some would be drawn wider than others.
        let backing = window?.backingScaleFactor ?? 1
        let across = pictureRect.width * backing / max(macSize.width, 1)
        let down = pictureRect.height * backing / max(macSize.height, 1)
        let whole = abs(across - across.rounded()) < 0.01 && abs(down - down.rounded()) < 0.01
        pictureLayer.magnificationFilter = whole ? .nearest : .linear
    }

    /// Where the picture is in the view: the Mac's screen fitted, centred,
    /// black around it (a fullscreen window on a wider screen).
    private var pictureRect: NSRect {
        guard macSize.width > 0, macSize.height > 0 else { return bounds }
        let scale = min(bounds.width / macSize.width, bounds.height / macSize.height)
        let size = NSSize(width: macSize.width * scale, height: macSize.height * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    // MARK: - The mouse

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(pictureRect, cursor: Self.hiddenCursor)
    }

    /// The event's place on the Mac's screen, top-left origin, kept on it.
    private func macPoint(_ event: NSEvent) -> (x: Int, y: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let picture = pictureRect
        let x = (point.x - picture.minX) / picture.width * macSize.width
        let y = (picture.maxY - point.y) / picture.height * macSize.height
        return (Int(min(max(x, 0), macSize.width - 1)), Int(min(max(y, 0), macSize.height - 1)))
    }

    private func move(_ event: NSEvent) {
        let point = macPoint(event)
        server.mouseMoved(x: point.x, y: point.y)
    }

    private func press(_ event: NSEvent, button: Int, down: Bool) {
        move(event)
        if down {
            heldButtons.insert(button)
        } else {
            guard heldButtons.remove(button) != nil else { return }
        }
        server.button(button, down: down)
    }

    override func mouseEntered(with event: NSEvent) { move(event) }
    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { move(event) }
    override func otherMouseDragged(with event: NSEvent) { move(event) }
    override func mouseDown(with event: NSEvent) { press(event, button: 0, down: true) }
    override func mouseUp(with event: NSEvent) { press(event, button: 0, down: false) }
    override func rightMouseDown(with event: NSEvent) { press(event, button: 1, down: true) }
    override func rightMouseUp(with event: NSEvent) { press(event, button: 1, down: false) }
    override func otherMouseDown(with event: NSEvent) { press(event, button: 2, down: true) }
    override func otherMouseUp(with event: NSEvent) { press(event, button: 2, down: false) }

    // MARK: - The keyboard

    private func key(_ code: UInt16, down: Bool) {
        if down {
            heldKeys.insert(code)
        } else {
            guard heldKeys.remove(code) != nil else { return }
        }
        server.key(code, down: down)
    }

    /// The Mac repeats a held key itself, as it did with its own keyboard.
    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        key(event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) { key(event.keyCode, down: false) }

    /// A modifier's own key, down or up by its flag; Caps Lock is down while
    /// it's on, as the Mac's locking key was.
    override func flagsChanged(with event: NSEvent) {
        let flag: NSEvent.ModifierFlags? = switch event.keyCode {
        case 0x38, 0x3C: .shift
        case 0x3B, 0x3E: .control
        case 0x3A, 0x3D: .option
        case 0x37, 0x36: .command
        case 0x39: .capsLock
        default: nil
        }
        guard let flag else { return }
        key(event.keyCode, down: event.modifierFlags.contains(flag))
    }

    /// A Command key combination: the menus' own (`keptKeys`) stay theirs,
    /// and any other is the Mac's. macOS sends no release for a key pressed
    /// with Command, so it's released here, held as long as a quick press.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, event.type == .keyDown, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if Self.keptKeys.contains(where: { $0.key == character && $0.modifiers == modifiers }) {
            return super.performKeyEquivalent(with: event)
        }
        guard !event.isARepeat else { return true }
        let code = event.keyCode
        key(code, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            MainActor.assumeIsolated { self?.key(code, down: false) }
        }
        return true
    }

    /// Everything held let go, for the window losing the keyboard and mouse.
    func releaseEverything() {
        for code in heldKeys { server.key(code, down: false) }
        heldKeys.removeAll()
        for button in heldButtons { server.button(button, down: false) }
        heldButtons.removeAll()
    }
}
