import ArgumentParser
import CoreGraphics
import Foundation
import PuppetProtocol

// `sc puppet` senses beyond a single picture: a stretch of play as a movie
// (`record`) or one picture of what changed in it (`sheet`), and how loud
// the program is (`audio`). See docs/dev-cli.md#puppet-sessions.

struct PuppetRecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record the game window into a movie, a chapter at each `do`, for a person to watch or `sheet` to sum up.",
        discussion: """
        Frames come from the game's own helper, as `shot`'s do (no Screen Recording), \
        as fast as it gives them (about 60 a second on a test Mac), timed as taken. Run it in the \
        background and act meanwhile: each `do` becomes a chapter.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    @Option(help: "How long to record, in seconds (at most 600).") var seconds: Double = 10
    @Option(help: "The movie's long edge, in pixels (never above the window's own).") var width: Double = 960

    func validate() throws {
        guard seconds > 0, seconds <= 600 else { throw ValidationError("--seconds is between 0 and 600.") }
        guard width >= 64 else { throw ValidationError("--width is at least 64.") }
    }

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        guard puppet.isRunning else { throw SCError("\(name) has stopped: \(puppet.stopReason ?? "?").", exitCode: 4) }
        puppet.touch()
        let scale = PuppetMovie.scale(window: PuppetShotCommand.windowSize(puppet), longEdge: width)
        try FileManager.default.createDirectory(at: puppet.recordings, withIntermediateDirectories: true)
        let stamp = PuppetSheet.clock(Date()).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: ".", with: "-")
        let movie = puppet.recordings.appendingPathComponent("\(name)-\(stamp).mov")
        let frames = puppet.recordings.appendingPathComponent(".frames-\(stamp)")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: frames) }

        let seconds = seconds
        let started = Date()
        let taken = try await session.ui.progressStep("Recording \(name) for \(Int(seconds)) s",
                                                      success: "Recorded \(name)") { update in
            try await Self.capture(puppet, into: frames, scale: scale, until: started.addingTimeInterval(seconds), update: update)
        }
        let ended = Date()
        guard !taken.isEmpty else {
            throw SCError("No frames came back from \(name)'s helper.", hints: ["Its state: sc puppet status \(name)", "A single picture: sc puppet shot \(name)"])
        }
        let duration = ended.timeIntervalSince(started)
        let actions = puppet.actions(from: started, to: ended)
        let chapters = PuppetMovie.chapters(actions, started: started, duration: duration)
        let size = try await session.ui.progressStep("Writing the movie", success: "Wrote the movie") { _ in
            try await PuppetMovie.write(to: movie, frames: taken.map { ($0.time.timeIntervalSince(started), $0.file) },
                                        chapters: chapters, duration: duration)
        }
        try PuppetRecording(movie: movie.path, started: started, ended: ended, frames: taken.count, width: size.width,
                            height: size.height, actions: actions).save()
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: movie.path))?[.size] as? Int) ?? 0
        session.ui.line("\(movie.path)  \(size.width)x\(size.height), \(taken.count) frames in \(String(format: "%.1f", duration)) s "
                        + "(\(String(format: "%.1f", Double(taken.count) / max(duration, 0.1))) a second), "
                        + "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), "
                        + (actions.isEmpty ? "no actions" : "\(actions.count) action\(actions.count == 1 ? "" : "s") as chapters"))
        session.ui.line("see it in one picture: sc puppet sheet \(name)")
        session.ui.line("fetch: " + PuppetShotCommand.fetchLine(movie))
    }

    /// Frames until `deadline`, two requests in flight so the helper's
    /// capture time overlaps: each saved as a PNG, with when it came back.
    static func capture(_ puppet: PuppetSession, into folder: URL, scale: Double, until deadline: Date,
                        update: @escaping @Sendable (String) -> Void) async throws -> [(time: Date, file: URL)] {
        let counter = Counter()
        let socket = try puppet.gameSocket()
        let results = await withTaskGroup(of: [(time: Date, file: URL)].self) { group in
            for worker in 0..<2 {
                group.addTask {
                    var mine: [(time: Date, file: URL)] = []
                    var failures = 0
                    while Date() < deadline, failures < 5 {
                        let file = folder.appendingPathComponent(String(format: "%d-%05d.png", worker, mine.count + failures))
                        let asked = Date()
                        let reply = try? HelperSocket.ask(socket, .capture(path: file.path, scale: scale), timeout: 20)
                        guard reply?.isOK == true else {
                            failures += 1
                            continue
                        }
                        // The picture is from between asking and the reply.
                        mine.append((asked.addingTimeInterval(Date().timeIntervalSince(asked) / 2), file))
                        let total = counter.add()
                        if total % 10 == 0 {
                            puppet.touch()
                            update("Recording \(puppet.name): \(total) frames, \(max(0, Int(deadline.timeIntervalSinceNow))) s to go")
                        }
                    }
                    return mine
                }
            }
            var all: [(time: Date, file: URL)] = []
            for await part in group { all += part }
            return all
        }
        return results.sorted { $0.time < $1.time }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() -> Int { lock.withLock { count += 1; return count } }
    }
}

struct PuppetSheetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sheet",
        abstract: "One picture of a recording's frames that changed, a grid with their times and the actions before them.",
        discussion: "Made from `record`'s movies: the last one, or every frame since --since. Says what it costs to look at, as `shot` does."
    )

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    @Option(help: ArgumentHelp("Frames since this time of day (14:05, 14:05:30) or this long ago (90s, 2m). Default: the last recording.",
                               valueName: "time")) var since: String?
    @Option(help: "The share of the picture (%) that must change for a frame to be shown.") var threshold: Int = 5
    @Option(help: "At most this many frames, spread evenly when more changed.") var max: Int = 16
    @Option(help: "Frames a row.") var columns: Int = 4
    @Option(help: "Each frame's width, in pixels.") var tile: Int = 320

    func validate() throws {
        guard max >= 1, columns >= 1, tile >= 64, (0...100).contains(threshold) else {
            throw ValidationError("--max and --columns are at least 1, --tile at least 64, --threshold 0 to 100.")
        }
        if let since { guard PuppetSheet.since(since) != nil else { throw ValidationError("--since is a time of day (14:05) or a while ago (90s, 2m).") } }
    }

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        let recordings = PuppetRecording.all(in: puppet.recordings)
        guard let last = recordings.last else {
            throw SCError("\(name) has no recordings yet.", hints: ["Record some play first: sc puppet record \(name) --seconds 20"])
        }
        let from = since.flatMap { PuppetSheet.since($0) } ?? last.started
        let chosen = recordings.filter { $0.ended >= from }
        guard !chosen.isEmpty else {
            throw SCError("No recording of \(name) since \(PuppetSheet.clock(from)); the last ended \(PuppetSheet.clock(last.ended)).")
        }

        var times: [Date] = [], thumbnails: [[UInt8]] = [], images: [CGImage] = []
        var frames = 0
        let tileWidth = tile
        for recording in chosen {
            try await PuppetMovie.frames(of: URL(fileURLWithPath: recording.movie)) { seconds, image in
                let time = recording.started.addingTimeInterval(seconds)
                guard time >= from, let thumbnail = Frames.thumbnail(image) else { return }
                frames += 1
                // Only frames that changed from the last one kept, kept
                // small: a long recording's frames would fill memory.
                guard PuppetSheet.shows(thumbnail, after: thumbnails.last, threshold: threshold) else { return }
                times.append(time)
                thumbnails.append(thumbnail)
                images.append(Self.shrunk(image, width: tileWidth) ?? image)
            }
        }
        let kept = PuppetSheet.spread(Array(times.indices), count: max)
        guard !kept.isEmpty else { throw SCError("No frames since \(PuppetSheet.clock(from)).") }
        let actions = chosen.flatMap(\.actions).sorted { $0.time < $1.time }
        var tiles: [PuppetSheet.Tile] = []
        var previous = from
        for index in kept {
            let after = actions.filter { $0.time > previous && $0.time <= times[index] }.map(\.action)
            tiles.append(.init(time: times[index], image: images[index], after: after))
            previous = times[index]
        }
        guard let sheet = PuppetSheet.draw(tiles, columns: columns, tileWidth: tile, started: chosen[0].started) else {
            throw SCError("Couldn't draw the sheet.")
        }
        try FileManager.default.createDirectory(at: puppet.shots, withIntermediateDirectories: true)
        let number = ((try? FileManager.default.contentsOfDirectory(atPath: puppet.shots.path))?.filter { $0.contains("-sheet-") }.count ?? 0) + 1
        let path = puppet.shots.appendingPathComponent(String(format: "%@-sheet-%03d.png", name, number))
        try PuppetSheet.writePNG(sheet, to: path)
        let changedCount = times.count
        session.ui.line("\(path.path)  \(sheet.width)x\(sheet.height), ~\(Frames.tokens(width: sheet.width, height: sheet.height)) tokens to look at")
        session.ui.line("\(tiles.count) of \(frames) frames since \(PuppetSheet.clock(from))"
                        + (changedCount > tiles.count ? ": \(changedCount) changed by over \(threshold)%, spread to --max \(max)" : ", each changed by over \(threshold)%"))
        session.ui.line("fetch: " + PuppetShotCommand.fetchLine(path))
    }

    static func shrunk(_ image: CGImage, width: Int) -> CGImage? {
        guard image.width > width else { return image }
        let height = Swift.max(1, Int((Double(width) * Double(image.height) / Double(image.width)).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

struct PuppetAudioCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "How loud the program is over a few seconds, from its samples: silent, sound or clipping.",
        discussion: """
        Taps the sound of the session's processes (a Core Audio process tap, \
        macOS 14.2) and measures peak and RMS every 0.1 s: a stream left open \
        playing silence reads as silent. The tap is a small app of its own, \
        SC Audio Tap, built on first use, which needs macOS's "System Audio \
        Recording Only" permission for this user (exit 6 until it has it).
        """
    )

    static let needsPermissionExitCode: Int32 = 6

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    @Option(help: "How long to listen, in seconds (at most 120).") var seconds: Double = 5
    @Flag(help: "Every 0.1 s window, not a row a second.") var raw = false

    func validate() throws {
        guard seconds > 0, seconds <= 120 else { throw ValidationError("--seconds is between 0 and 120.") }
    }

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        guard puppet.isRunning, let root = puppet.wrappPID else { throw SCError("\(name) has stopped: \(puppet.stopReason ?? "?").", exitCode: 4) }
        puppet.touch()
        let signer = try await AudioTapApp.ensure(repo: session.repo.root, ui: session.ui)
        var permission = try await AudioTapApp.run(["check"]).lines.first ?? ""
        if permission == "permission unknown" {
            session.ui.detail("Asking macOS for \(AudioTapApp.name)'s permission (a prompt on this session's screen)…")
            permission = try await AudioTapApp.run(["request"]).lines.last ?? ""
        }
        guard permission == "permission authorized" else { throw Self.needsPermission(permission, signer: signer) }

        // The wrapp and what it started, and whichever process answers as
        // the game (a Wine game's needn't be the wrapp's child).
        let listing = try await Proc.collect("/bin/ps", ["-axo", "pid=,ppid="]).output
        var pids = ProcessTree.descendants(of: root, in: ProcessTree.parse(listing))
        let sockets = (try? FileManager.default.contentsOfDirectory(atPath: puppet.sockets.path)) ?? []
        pids += sockets.compactMap { name in name.hasPrefix("game-") ? pid_t(name.dropFirst(5).dropLast(5)) : nil }.filter { !pids.contains($0) }

        let tapped = try await session.ui.progressStep("Listening to \(name) for \(Int(seconds)) s", success: "Listened to \(name)") { _ in
            try await AudioTapApp.run(["tap", pids.map(String.init).joined(separator: ","), String(seconds)])
        }
        if tapped.lines.contains(where: { $0.hasPrefix("permission ") }) {
            throw Self.needsPermission(tapped.lines.first { $0.hasPrefix("permission ") } ?? "", signer: signer)
        }
        if tapped.status == 3 {
            session.ui.line("audio: silent: none of \(name)'s \(pids.count) processes has opened sound output")
            return
        }
        guard tapped.status == 0 else {
            throw SCError("The audio tap failed: \(tapped.lines.last { $0.hasPrefix("error") } ?? "exit \(tapped.status)")")
        }
        let levels = tapped.lines.compactMap(AudioLevel.init(line:))
        let processes = tapped.lines.filter { $0.hasPrefix("process ") }
        let format = tapped.lines.first { $0.hasPrefix("format ") }?.replacingOccurrences(of: "format ", with: "") ?? "?"
        let playing = processes.filter { $0.hasSuffix("output=1") }.count
        session.ui.line("audio: " + AudioLevel.summary(levels))
        session.ui.line("from \(processes.count) process\(processes.count == 1 ? "" : "es") with sound (\(playing) playing), \(format)")
        if raw {
            for level in levels {
                session.ui.line(String(format: "%6.1fs  ", level.time) + "peak \(AudioLevel.decibels(level.peak)), rms \(AudioLevel.decibels(level.rms))")
            }
        } else {
            AudioLevel.rows(levels).forEach { session.ui.line($0) }
        }
    }

    static func needsPermission(_ state: String, signer: String) -> SCError {
        let user = NSUserName(), host = ScreenLease.shortHostName()
        return SCError(
            "\(AudioTapApp.name) hasn't been allowed to record system audio for \(user) on \(host) (\(state.isEmpty ? "no answer" : state)).",
            hints: [
                "For a test session, from the Mac you're at: sc session setup --task audio \(user) --on \(host)",
                "Logged in as \(user) on \(host) (Screen Sharing for a test session): answer its prompt with Allow, or in System Settings › "
                    + "Privacy & Security › Screen & System Audio Recording, under \"System Audio Recording Only\", turn \(AudioTapApp.name) on "
                    + "(+ adds it: \(AudioTapApp.app.path)).",
                signer == "ad hoc"
                    ? "It's signed ad hoc, so the permission lasts only until it's rebuilt (when Tools/sc/AudioTap/main.swift changes)."
                    : "It's signed as \(signer), so the permission outlasts rebuilds.",
            ],
            exitCode: needsPermissionExitCode
        )
    }
}
