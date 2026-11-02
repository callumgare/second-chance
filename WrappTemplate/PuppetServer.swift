//
//  PuppetServer.swift
//  WrappTemplate
//
//  When WrappPuppeteer starts the wrapp, it drives the wrapp's own info
//  window through this rather than through Accessibility: a process may read
//  and click its own windows with no permission. WrappPuppeteer passes
//  SECOND_CHANCE_PUPPET_DIR, and this answers on wrapp.sock there; the game's
//  window is served separately, from inside the game's process, on game.sock
//  (InProcessHelpers/puppet_control.m). A player's launch never sets the
//  variable, so nothing listens. See docs/wine-in-process-helpers.md.
//
//  One request per connection, one line each way:
//
//    info      -> ok open=0|1 warning=0|1
//    confirm   -> ok clicked | ok pressed   (I Understand, on the save warning)

import AppKit
import Foundation
import Logging
import SecondChanceKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.PuppetServer")

/// On a thread of its own, reaching the windows on the main thread through
/// `onMain`.
nonisolated enum PuppetServer {
    /// Start serving if WrappPuppeteer started the wrapp.
    static func startIfRequested() {
        guard let directory = Wine.puppetDirectory() else { return }
        let path = (directory as NSString).appendingPathComponent("wrapp.sock")
        let thread = Thread { serve(path: path) }
        thread.name = "PuppetServer"
        thread.start()
    }

    private static func serve(path: String) {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            logger.error("[Puppet] Can't listen on \(path): too long for a Unix socket")
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard server >= 0, bound == 0, listen(server, 4) == 0 else {
            logger.error("[Puppet] Can't listen on \(path): \(String(cString: strerror(errno)))")
            return
        }
        logger.notice("[Puppet] Listening on \(path)")
        while true {
            let client = accept(server, nil, nil)
            guard client >= 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = read(client, &buffer, buffer.count - 1)
            if count > 0 {
                let request = String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let reply = handle(request)
                logger.debug("[Puppet] \(request) -> \(reply)")
                _ = (reply + "\n").withCString { write(client, $0, strlen($0)) }
            }
            close(client)
        }
    }

    private static func handle(_ request: String) -> String {
        switch request {
        case "info": return info()
        case "confirm": return confirm()
        default: return "error unknown request: \(request)"
        }
    }

    /// Run `work` on the main thread, and wait for it.
    private static func onMain<T: Sendable>(_ work: @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
    }

    private static func info() -> String {
        onMain {
            let open = globalInfoWindow?.window?.isVisible == true
            let warning = open && globalInfoWindow?.isShowingWarning == true
            return "ok open=\(open ? 1 : 0) warning=\(warning ? 1 : 0)"
        }
    }

    /// Click I Understand where it is drawn, as a player would, holding the
    /// button for 100 ms. If the warning is still up two seconds later — a
    /// click can be lost on a loaded Mac — do what the button does instead.
    private static func confirm() -> String {
        let target: (windowNumber: Int, point: NSPoint)? = onMain {
            guard let window = globalInfoWindow?.window, window.isVisible,
                  let point = globalInfoWindow?.confirmButtonLocation else { return nil }
            // As it is for a player: a click on a window that isn't key only
            // brings it forward.
            if !window.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            return (window.windowNumber, point)
        }
        guard let target else { return "error the save warning isn't showing" }

        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            onMain {
                if let event = NSEvent.mouseEvent(with: type, location: target.point, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: target.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            if type == .leftMouseDown { usleep(100_000) }
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if !onMain({ globalInfoWindow?.isShowingWarning == true }) { return "ok clicked" }
            usleep(100_000)
        }
        let state = onMain {
            let window = globalInfoWindow?.window
            return "key=\(window?.isKeyWindow == true), active=\(NSApp.isActive), clicked at \(target.point) "
                + "in a \(window?.frame.size ?? .zero) window, \(globalInfoWindow?.confirmButtonGeometry ?? "")"
        }
        logger.warning("[Puppet] Clicking I Understand didn't confirm the save warning (\(state)); confirming it directly")
        onMain { globalInfoWindow?.pressConfirm() }
        return "ok pressed"
    }
}
