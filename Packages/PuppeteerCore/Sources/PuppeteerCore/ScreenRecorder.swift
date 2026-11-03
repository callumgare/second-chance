//
//  ScreenRecorder.swift
//  WrappPuppeteer
//
//  A video of the whole screen while a run starts the game, for working out
//  afterwards what went wrong: what flashed up, what was in front. Only when
//  WrappPuppeteer happens to have Screen Recording, which it otherwise never
//  needs (the game captures its own window, InProcessControl), and for a
//  couple of minutes at most: a launch that takes longer has gone wrong by
//  then, and a long capture wears a test Mac down (docs/testing.md).

import AVFoundation
import CoreGraphics
import Foundation
import Logging
import ScreenCaptureKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.ScreenRecorder")

/// Records the main display to an H.264 `.mp4`, from `start` until `stop` or
/// its time limit, whichever is first. Frames come from ScreenCaptureKit on a
/// queue of the recorder's own and are written there, so starting, stopping
/// and finishing the file never wait on the main thread, which a run blocks.
public nonisolated final class ScreenRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    public let file: URL
    private let queue = DispatchQueue(label: "au.gare.callum.second-chance.WrappPuppeteer.ScreenRecorder")
    // Touched only on `queue`, once `start` has set them up.
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var stopped = false

    private init(file: URL) {
        self.file = file
    }

    /// Start recording the main display to `file` (replacing it), stopping by
    /// itself after `limit` seconds. Nil, with the reason logged, without
    /// Screen Recording or when ScreenCaptureKit won't start.
    public static func start(to file: URL, limit: TimeInterval) -> ScreenRecorder? {
        guard CGPreflightScreenCaptureAccess() else {
            logger.notice("No screen recording: WrappPuppeteer doesn't have Screen Recording")
            return nil
        }
        let recorder = ScreenRecorder(file: file)
        do {
            try recorder.begin()
        } catch {
            logger.warning("No screen recording: \(error)")
            return nil
        }
        recorder.queue.asyncAfter(deadline: .now() + limit) { [weak recorder] in
            guard let recorder, !recorder.stopped else { return }
            logger.notice("Screen recording stopped after its \(Int(limit))s limit")
            recorder.finish()
        }
        logger.notice("🎥 Recording the screen to \(file.path), for at most \(Int(limit))s")
        return recorder
    }

    /// Stop recording and finish the file; waits a few seconds at most.
    /// Safe to call when it has already stopped.
    public func stop() {
        queue.sync { finish() }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Wait for a completion handler, but not for ever: a handler that never
    /// comes leaves the recording unfinished rather than the run stuck.
    private static func wait(_ what: String, seconds: Double = 10, _ body: (@escaping @Sendable (Error?) -> Void) -> Void) throws {
        let done = DispatchSemaphore(value: 0)
        let failure = LockedError()
        body { error in
            failure.set(error)
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else { throw Failure(description: "\(what) didn't finish in \(Int(seconds))s") }
        if let error = failure.get() { throw error }
    }

    private func begin() throws {
        let content = SharedContent()
        try Self.wait("Finding the displays") { finished in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { found, error in
                content.set(found)
                finished(error)
            }
        }
        let mainID = CGMainDisplayID()
        guard let display = content.get()?.displays.first(where: { $0.displayID == mainID }) ?? content.get()?.displays.first else {
            throw Failure(description: "no display to record")
        }
        // The display's own pixels, so small text stays readable.
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let width = mode?.pixelWidth ?? display.width
        let height = mode?.pixelHeight ?? display.height

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.queueDepth = 6

        try? FileManager.default.removeItem(at: file)
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw Failure(description: "the video writer won't take a \(width)x\(height) video") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure(description: "the video writer won't start: \(writer.error.map { "\($0)" } ?? "no reason")") }

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            self.stream = stream
            self.writer = writer
            self.input = input
        }
        try Self.wait("Starting the capture") { finished in stream.startCapture(completionHandler: finished) }
    }

    /// Each new frame, written; one that only says nothing changed isn't.
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, let writer, let input, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    /// Stop the capture and finish the file. On `queue`.
    private func finish() {
        guard !stopped else { return }
        stopped = true
        if let stream {
            do {
                try Self.wait("Stopping the capture") { finished in stream.stopCapture(completionHandler: finished) }
            } catch {
                logger.warning("Screen recording: \(error)")
            }
        }
        guard let writer, let input else { return }
        guard sessionStarted else {
            writer.cancelWriting()
            logger.warning("Screen recording: no frames came, so there's no video")
            return
        }
        input.markAsFinished()
        do {
            try Self.wait("Finishing the video") { finished in writer.finishWriting { finished(nil) } }
            if let error = writer.error { throw error }
            logger.notice("🎥 Screen recording saved: \(file.path)")
        } catch {
            logger.warning("Screen recording: \(error)")
        }
    }
}

/// What a completion handler hands back, across the queue it calls on.
private nonisolated final class LockedError: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func set(_ error: Error?) { lock.withLock { self.error = error } }
    func get() -> Error? { lock.withLock { error } }
}

private nonisolated final class SharedContent: @unchecked Sendable {
    private let lock = NSLock()
    private var content: SCShareableContent?
    func set(_ content: SCShareableContent?) { lock.withLock { self.content = content } }
    func get() -> SCShareableContent? { lock.withLock { content } }
}
