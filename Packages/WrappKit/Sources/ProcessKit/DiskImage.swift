//
//  DiskImage.swift
//  ProcessKit
//
//  Attaching a disk image, and getting out of an attach that hangs.

import Foundation

/// `hdiutil attach`, bounded in time.
///
/// An attach can hang for good: the image attaches but its volume never
/// mounts, and `hdiutil` waits on it. Seen on a macOS 26 Mac where even a
/// new 5 MB image hung; each stuck attach also wedged the Mac's disk service
/// (`diskutil list` hung) for every user, and later mounts there took
/// minutes or failed, until the `diskimages-helper` serving the stuck image
/// was killed (`hdiutil detach -force` hung too, and a SIGTERM to `hdiutil`
/// was ignored). So an attach that outlasts its time is killed, along with
/// this user's helper for that image, and reported as hung, which leaves
/// the Mac as it was rather than wedged.
nonisolated public enum DiskImage {
    /// How long an attach may take. A disc image attaches in seconds, and
    /// under load in under a minute; nothing signals a hang, so it is timed.
    public static let attachTimeout: Duration = .seconds(180)

    /// An attach that hung, and was cleared up after.
    public struct HungError: LocalizedError, Sendable {
        public let image: URL
        public let timeout: Duration
        public var errorDescription: String? {
            "hdiutil attach of \(image.lastPathComponent) hung (no answer in \(timeout)); it was stopped, and its disk image released. "
                + "If attaches keep hanging, the Mac's disk service is stuck: restarting it clears it."
        }
    }

    /// Run `hdiutil attach <image> <options>`, killing it and releasing the
    /// image if it takes longer than `timeout`. Its output, as
    /// `Process.output` gives it.
    public static func attach(_ image: URL, options: [String], timeout: Duration = attachTimeout) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", image.path] + options
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let finished = OneTimeSignal()
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // What attach says fits a pipe's buffer, so it's read once it's done.
        guard await finished.wait(timeout: timeout) else {
            kill(process.processIdentifier, SIGKILL)
            await release(image)
            throw HungError(image: image, timeout: timeout)
        }
        return ProcessOutput(
            status: process.terminationStatus,
            output: String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            errorOutput: String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    /// Stop the helpers serving this user's attachments of `image`, which
    /// is what lets a stuck one go: their pids from `hdiutil info`, whose
    /// listing still answers when attaching doesn't.
    static func release(_ image: URL) async {
        guard let info = try? await Process.output(of: "/usr/bin/hdiutil", ["info", "-plist"]), info.succeeded else { return }
        for pid in helpers(of: image, infoPlist: Data(info.output.utf8), user: getuid()) {
            kill(pid, SIGKILL)
        }
    }

    /// The `diskimages-helper` pids `hdiutil info -plist` gives for `user`'s
    /// attachments of `image`.
    static func helpers(of image: URL, infoPlist: Data, user: uid_t) -> [pid_t] {
        guard let info = try? PropertyListSerialization.propertyList(from: infoPlist, format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]] else { return [] }
        let wanted = image.resolvingSymlinksInPath().path
        return images.compactMap { entry in
            guard let path = entry["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == wanted,
                  (entry["owner-uid"] as? NSNumber)?.uint32Value == user,
                  let pid = (entry["hdid-pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
            return pid
        }
    }
}
