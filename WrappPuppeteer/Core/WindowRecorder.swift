//
//  WindowRecorder.swift
//  WrappPuppeteer
//
//  Captures a controlled window over and over into a directory, on its own
//  thread, for seeing afterwards what the window showed and when — what an
//  app puts up before the screen a scenario is waiting for.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.WindowRecorder")

final class WindowRecorder {
    private let window: WindowControl
    private let directory: URL
    private let interval: TimeInterval
    private let lock = NSLock()
    private var stopped = false
    private let finished = DispatchSemaphore(value: 0)

    /// Frames go in `directory` as `<milliseconds since start>.png`, at most
    /// one every `interval` seconds — fewer when a capture takes longer.
    init(window: WindowControl, directory: URL, interval: TimeInterval = 0.1) {
        self.window = window
        self.directory = directory
        self.interval = interval
    }

    func start() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error("❌ Couldn't create \(directory.path), not recording: \(error.localizedDescription)")
            finished.signal()
            return
        }
        logger.notice("🎥 Recording the window into \(directory.path)")
        let thread = Thread { [self] in
            let start = Date()
            var frames = 0
            while !isStopped {
                let frameStart = Date()
                let milliseconds = Int(frameStart.timeIntervalSince(start) * 1000)
                let path = directory.appendingPathComponent(String(format: "%06d.png", milliseconds)).path
                if window.capture(to: path) != nil { frames += 1 }
                let remaining = interval - Date().timeIntervalSince(frameStart)
                if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            }
            logger.notice("🎥 Recorded \(frames) frames over \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            finished.signal()
        }
        thread.start()
    }

    /// Stop, and wait for the capture in flight to finish.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        finished.wait()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}
