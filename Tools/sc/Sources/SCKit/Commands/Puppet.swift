import ArgumentParser
import Foundation
import WineKit

struct PuppetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "puppet",
        abstract: "Drive a program by hand: start a wrapp, then look, click and type, each reply saying what changed.",
        discussion: """
        A session runs a wrapp in this user's GUI session with WrappPuppeteer's \
        in-process helper armed, holding the screen lease until it's stopped or \
        idle. Every action replies with what it did to the picture (measured, \
        not looked at), new windows, and whether the program is still there; \
        `shot` and `text` look when that's not enough. Run one in a test \
        session (sc --on <user>@<host> puppet …) to leave the screen free. \
        See docs/dev-cli.md#puppet-sessions.
        """,
        subcommands: [
            PuppetStartCommand.self, PuppetStopCommand.self, PuppetListCommand.self, PuppetStatusCommand.self,
            PuppetActionCommand.self, PuppetShotCommand.self, PuppetTextCommand.self, PuppetWindowsCommand.self,
            PuppetLogCommand.self, PuppetSavesCommand.self, PuppetServeCommand.self,
        ]
    )
}

// MARK: Starting and stopping

struct PuppetStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a wrapp to drive: past its save warning, until the game's window answers."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "A name for the session: lower-case letters, digits and dashes.")
    var name: String

    @Option(help: ArgumentHelp("The wrapp to run.", valueName: "app"))
    var wrapp: String

    @Option(help: ArgumentHelp("Stop it after this long with no command: 10m, 30m, 1h.", valueName: "time"))
    var idle: String = "10m"

    @Option(help: ArgumentHelp("Stop it after this long whatever happens.", valueName: "time"))
    var max: String = "2h"

    func validate() throws {
        guard PuppetSession.validName(name) else { throw ValidationError("A session's name is lower-case letters, digits and dashes.") }
        guard ScreenLease.parseDuration(idle) != nil, ScreenLease.parseDuration(max) != nil else {
            throw ValidationError("--idle and --max take a time such as 10m or 2h, of at most 8 hours.")
        }
    }

    func run() async throws {
        let session = try Session.start(global)
        let app = URL(fileURLWithPath: (wrapp as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/WrappTemplate").path) else {
            throw SCError("\(app.path) isn't a wrapp (no Contents/MacOS/WrappTemplate).")
        }
        if let existing = try? PuppetSession.load(name), existing.isRunning {
            throw SCError("\(name) is already running \(existing.app).", hints: ["Stop it first: sc puppet stop \(name)"])
        }
        try? FileManager.default.removeItem(at: PuppetSession.folder(name))
        var puppet = PuppetSession(name: name, app: app.path, purpose: global.purpose, started: Date(),
                                   idleMinutes: (ScreenLease.parseDuration(idle) ?? 600) / 60,
                                   maxMinutes: (ScreenLease.parseDuration(max) ?? 7200) / 60)
        try FileManager.default.createDirectory(at: puppet.shots, withIntermediateDirectories: true)
        try puppet.save()
        puppet.touch()

        let label = PuppetSession.label + name
        let plist = puppet.folder.appendingPathComponent("\(label).plist")
        let holder = ScreenLease.currentHolder(repoRoot: session.repo.root, branch: await ScreenLease.branch(of: session.repo.root))
        var arguments = [Bundle.main.executablePath ?? CommandLine.arguments[0], "puppet", "serve", name, "--logs", "raw"]
        if let purpose = global.purpose { arguments += ["--purpose", purpose] }
        if global.ignoreScreenLease { arguments.append("--ignore-screen-lease") }
        if global.breakScreenLease { arguments.append("--break-screen-lease") }
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "WorkingDirectory": session.repo.root.path,
            "EnvironmentVariables": [ScreenLease.holderVariable: ScreenLease.encodeHolder(holder)],
            "StandardOutPath": puppet.serverLog.path,
            "StandardErrorPath": puppet.serverLog.path,
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: plist)
        let domain = "gui/\(getuid())"
        _ = try await Proc.collect("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let result = try await Proc.collect("/bin/launchctl", ["bootstrap", domain, plist.path])
        guard result.succeeded else {
            throw SCError("Couldn't start the session's server: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))",
                          hints: ["Someone must be logged in to this user's GUI session (a test session: sc session list)."])
        }

        // Until the game's helper answers with a window, or the server gives up.
        let deadline = Date().addingTimeInterval(300)
        var state = ""
        while Date() < deadline {
            try await Task.sleep(for: .seconds(1))
            let current = (try? PuppetSession.load(name)) ?? puppet
            if current.stopped != nil || (current.serverPID != nil && !current.isRunning) {
                let log = (try? String(contentsOf: puppet.serverLog, encoding: .utf8)) ?? ""
                throw SCError("\(name) stopped before its game answered: \(current.stopReason ?? "the server ended").\n"
                              + log.split(separator: "\n").suffix(8).joined(separator: "\n"),
                              exitCode: log.contains("screen is in use") ? ScreenLease.heldExitCode : 1)
            }
            if let socket = try? current.gameSocket(), let reply = try? HelperSocket.ask(socket, "state", timeout: 10),
               reply.hasPrefix("ok window=") {
                state = reply
                break
            }
        }
        guard !state.isEmpty else {
            throw SCError("\(name)'s game hasn't answered in 5 minutes.", hints: ["Its log: sc puppet log \(name)", "Stop it: sc puppet stop \(name)"])
        }
        let current = (try? PuppetSession.load(name)) ?? puppet
        let hello = (try? current.ask("hello")) ?? "error (an older helper: version 1)"
        session.ui.line("\(name): \(app.lastPathComponent), wrapp pid \(current.wrappPID.map(String.init) ?? "?"), "
                        + "screen \(SessionPool.screenName()) leased; stops after \(idle) idle or \(max)")
        session.ui.line("helper: \(hello.replacingOccurrences(of: "ok ", with: ""))")
        session.ui.line("state: \(state.replacingOccurrences(of: "ok ", with: ""))")
        if state.contains("native=0"), state.contains("fullscreen=1") {
            session.ui.line("waiting: native fullscreen is still settling; shots work once state says native=1")
        }
    }
}

struct PuppetServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "The session's server (started by `start`, as a LaunchAgent).",
        shouldDisplay: false
    )

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    func run() async throws {
        let session = try Session.start(global)
        var puppet = try PuppetSession.load(name)
        puppet.serverPID = getpid()
        try puppet.save()
        func finish(_ reason: String) {
            puppet.stopped = Date()
            puppet.stopReason = reason
            try? puppet.save()
            try? FileManager.default.removeItem(at: puppet.sockets)
            log("stopped: \(reason)")
        }
        do {
            try await ScreenLease.acquire(session, policy: global.leasePolicy, purpose: puppet.purpose)
        } catch {
            log("\(error)")
            finish("the screen is in use")
            throw ExitCode(ScreenLease.heldExitCode)
        }

        try? FileManager.default.removeItem(at: puppet.sockets)
        try FileManager.default.createDirectory(at: puppet.sockets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: puppet.appSupport, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: puppet.wrappLog.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: puppet.app).appendingPathComponent("Contents/MacOS/WrappTemplate")
        var environment = ProcessInfo.processInfo.environment
        environment["SECOND_CHANCE_PUPPET_DIR"] = puppet.sockets.path
        environment["SECOND_CHANCE_APP_SUPPORT_DIR"] = puppet.appSupport.path
        environment["IN_PROCESS_HELPERS_LOG"] = puppet.helpersLog.path
        environment[ScreenLease.holderVariable] = nil
        process.environment = environment
        let output = try FileHandle(forWritingTo: puppet.wrappLog)
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        puppet.wrappPID = process.processIdentifier
        try puppet.save()
        log("started \(puppet.app), pid \(process.processIdentifier)")

        // Past the save warning, which a Wine wrapp waits on.
        for _ in 0..<60 where process.isRunning {
            if let info = try? HelperSocket.ask(puppet.wrappSocket, "info", timeout: 5) {
                if info.contains("warning=1") { log("save warning: \((try? HelperSocket.ask(puppet.wrappSocket, "confirm")) ?? "?")") }
                if info.contains("warning=") { break }
            }
            try await Task.sleep(for: .seconds(1))
        }

        var reason = ""
        while reason.isEmpty {
            try await Task.sleep(for: .seconds(2))
            let idleFor = Date().timeIntervalSince(puppet.idleSince)
            if FileManager.default.fileExists(atPath: puppet.stopFile.path) {
                reason = "asked to stop"
            } else if !process.isRunning {
                reason = "the program ended (exit \(process.terminationStatus))"
            } else if idleFor >= puppet.idleMinutes * 60 {
                reason = "idle for \(ScreenLease.duration(idleFor))"
            } else if Date().timeIntervalSince(puppet.started) >= puppet.maxMinutes * 60 {
                reason = "ran for its --max"
            }
        }
        log("stopping: \(reason)")
        if process.isRunning {
            _ = try? puppet.ask("quit", timeout: 10)
            for _ in 0..<20 where process.isRunning { try await Task.sleep(for: .seconds(1)) }
        }
        if process.isRunning {
            log("still running 20 s after quit: SIGTERM")
            process.terminate()
            for _ in 0..<10 where process.isRunning { try await Task.sleep(for: .seconds(1)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let app = URL(fileURLWithPath: puppet.app)
        if FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/SharedSupport/wine").path) {
            let server = Wine(wrapp: app).server
            let left = server.programs()
            if !left.isEmpty {
                log("Wine programs left in its prefix: \(left.map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")); killing them")
                await server.kill()
            }
        }
        finish(reason)
    }

    private func log(_ text: String) {
        let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        FileHandle.standardOutput.write(Data("\(stamp) \(text)\n".utf8))
    }
}

struct PuppetStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Quit the program, end the session and give the screen back.")

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    func run() async throws {
        let session = try Session.start(global)
        var puppet = try PuppetSession.load(name)
        if puppet.isRunning {
            FileManager.default.createFile(atPath: puppet.stopFile.path, contents: nil)
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline, (try? PuppetSession.load(name))?.isRunning == true {
                try await Task.sleep(for: .seconds(1))
            }
            puppet = try PuppetSession.load(name)
        }
        _ = try? await Proc.collect("/bin/launchctl", ["bootout", "gui/\(getuid())/\(PuppetSession.label + name)"])
        guard let stopped = puppet.stopped else {
            throw SCError("\(name)'s server didn't stop within 90 s.", hints: ["Its log: \(puppet.serverLog.path)"])
        }
        session.ui.line("\(name) stopped: \(puppet.stopReason ?? "?"). Screen \(SessionPool.screenName()) held "
                        + "\(ScreenLease.clock(puppet.started))–\(ScreenLease.clock(stopped)).")
    }
}

struct PuppetListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List this user's puppet sessions.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let session = try Session.start(global)
        let all = PuppetSession.all()
        if all.isEmpty { session.ui.detail("No puppet sessions.") }
        for puppet in all {
            let state = puppet.isRunning ? "running since \(ScreenLease.clock(puppet.started))"
                : "stopped \(puppet.stopped.map(ScreenLease.clock) ?? "?") (\(puppet.stopReason ?? "?"))"
            session.ui.line("\(puppet.name): \(URL(fileURLWithPath: puppet.app).lastPathComponent), \(state)")
        }
    }
}

struct PuppetStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "The program's state, and when the session stops if left idle.")

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        guard puppet.isRunning else {
            session.ui.line("\(name) stopped \(puppet.stopped.map(ScreenLease.clock) ?? "?"): \(puppet.stopReason ?? "?")")
            return
        }
        puppet.touch()
        let stopsAt = Date().addingTimeInterval(puppet.idleMinutes * 60)
        session.ui.line("\(name): running since \(ScreenLease.clock(puppet.started)); idle stop at \(ScreenLease.clock(stopsAt))")
        session.ui.line("state: " + ((try? puppet.ask("state")) ?? "no answer").replacingOccurrences(of: "ok ", with: ""))
    }
}

// MARK: Acting

struct PuppetActionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "do",
        abstract: "Act on the game and say what changed: click, move, drag, down, up, key, type, focus.",
        discussion: """
        sc puppet do <name> click <x> <y> [--button right] [--count 2] · move <x> <y> · \
        drag <x> <y> <x2> <y2> · down|up <x> <y> · key <key>[+mods] (return, escape, \
        f5, left, a, cmd+s) · type "<text>" · focus. Points are in the game window \
        from its top left: a shot's pixels divided by its scale. The reply measures \
        the picture before and after (--wait after), so it says whether anything \
        happened without a picture.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument var name: String
    @Argument(help: "The action and its arguments.") var action: [String]

    @Option(help: "right, for the right button.") var button: String?
    @Option(help: "Clicks: 2 for a double click.") var count: Int?
    @Option(help: "How long to hold the key or button, in ms.") var hold: Int?
    @Option(help: "Seconds to wait before measuring what changed.") var wait: Double = 0.8

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        guard puppet.isRunning else { throw SCError("\(name) has stopped: \(puppet.stopReason ?? "?").", exitCode: 4) }
        puppet.touch()
        guard let verb = action.first else { throw ValidationError("Say what to do: click, move, drag, down, up, key, type or focus.") }
        let arguments = Array(action.dropFirst())
        var request: String
        switch (verb, arguments.count) {
        case ("click", 2), ("move", 2), ("down", 2), ("up", 2), ("drag", 4):
            guard arguments.allSatisfy({ Double($0) != nil }) else { throw ValidationError("\(verb) takes numbers.") }
            request = ([verb] + arguments).joined(separator: " ")
        case ("key", 1):
            request = "key \(arguments[0])"
        case ("type", 1...):
            let text = arguments.joined(separator: " ")
            request = "type " + (text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text)
        case ("focus", 0):
            request = "focus"
        default:
            throw ValidationError("Unknown action, or the wrong number of arguments: \(action.joined(separator: " ")).")
        }
        if let button { request += " button=\(button)" }
        if let count { request += " count=\(count)" }
        if let hold { request += " hold=\(hold)" }

        let before = Probe(puppet)
        _ = try puppet.ask(request)
        try await Task.sleep(for: .seconds(wait))
        let after = Probe(puppet)
        session.ui.line(PuppetReply.outcome(of: action.joined(separator: " "), before: before, after: after, puppet: puppet))
    }
}

/// What's measured either side of an action.
struct Probe {
    var thumbnail: [UInt8]?
    var windows: [String: String]
    var running: Bool

    init(_ puppet: PuppetSession) {
        let path = puppet.shots.appendingPathComponent(".probe-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: path) }
        if (try? puppet.ask("capture \(path.path) scale=0.1", timeout: 20)) != nil, let image = Frames.image(at: path) {
            thumbnail = Frames.thumbnail(image)
        }
        windows = PuppetReply.windows((try? puppet.ask("windows", timeout: 10)) ?? "")
        running = puppet.wrappPID.map { kill($0, 0) == 0 } ?? false
    }
}

enum PuppetReply {
    /// Visible windows by id, from a `windows` reply, as "title (WxH)".
    static func windows(_ reply: String) -> [String: String] {
        var found: [String: String] = [:]
        for line in reply.split(separator: "\n").dropFirst() {
            let fields = Dictionary(line.split(separator: " ").compactMap { word -> (String, String)? in
                let parts = word.split(separator: "=", maxSplits: 1)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }, uniquingKeysWith: { first, _ in first })
            guard fields["visible"] == "1", let id = fields["id"] else { continue }
            let size = fields["frame"].map { $0.split(separator: ",").suffix(2).joined(separator: "x") } ?? "?"
            let title = fields["title"]?.removingPercentEncoding ?? ""
            found[id] = (title.isEmpty ? "untitled" : "\"\(title)\"") + " (\(size))"
        }
        return found
    }

    static func outcome(of action: String, before: Probe, after: Probe, puppet: PuppetSession) -> String {
        var lines: [String] = []
        let appeared = after.windows.filter { before.windows[$0.key] == nil }.map { "window \($0.value)" }
        let gone = before.windows.filter { after.windows[$0.key] == nil }.map { "window \($0.value)" }
        var news: [String] = appeared.map { "+" + $0 } + gone.map { "-" + $0 }
        if before.running && !after.running { news.append("the program has ended") }
        lines.append("new: " + (news.isEmpty ? "—" : news.joined(separator: ", ")))
        var effect = "\(action) → "
        if let a = before.thumbnail, let b = after.thumbnail {
            effect += "changed \(Frames.changed(a, b))%"
            if Frames.black(b) >= 90 { effect += ", now black" }
        } else {
            effect += "changed ? (no capture)"
        }
        lines.append(effect)
        return lines.joined(separator: "\n")
    }
}

// MARK: Looking

struct PuppetShotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shot",
        abstract: "A picture of the game window (or a part), saved and named, with what it costs to look at."
    )

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    @Option(help: ArgumentHelp("A part of the window, in points: x,y,w,h.", valueName: "x,y,w,h")) var region: String?
    @Option(help: "Pixels a point. Default: the window's own, but no more than 1280 pixels across.") var scale: Double?

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        guard puppet.isRunning else { throw SCError("\(name) has stopped: \(puppet.stopReason ?? "?").", exitCode: 4) }
        puppet.touch()
        let size = PuppetShotCommand.windowSize(puppet)
        let longEdge = region.flatMap { r -> Double? in
            let n = r.split(separator: ",").compactMap { Double($0) }
            return n.count == 4 ? max(n[2], n[3]) : nil
        } ?? max(size.width, size.height)
        let chosen = scale ?? min(size.scale, 1280 / max(longEdge, 1))
        let number = ((try? FileManager.default.contentsOfDirectory(atPath: puppet.shots.path))?.filter { $0.hasSuffix(".png") && !$0.hasPrefix(".") }.count ?? 0) + 1
        let path = puppet.shots.appendingPathComponent(String(format: "%@-%03d.png", name, number))
        var request = "capture \(path.path) scale=\(String(format: "%.3f", chosen))"
        if let region { request += " region=\(region)" }
        let reply = try puppet.ask(request)
        let pixels = reply.replacingOccurrences(of: "ok ", with: "").split(separator: "x").compactMap { Int($0) }
        let tokens = pixels.count == 2 ? Frames.tokens(width: pixels[0], height: pixels[1]) : 0
        session.ui.line("\(path.path)  \(pixels.map(String.init).joined(separator: "x")) at \(String(format: "%.2f", chosen)) px/pt, ~\(tokens) tokens to look at")
        session.ui.line("fetch: " + PuppetShotCommand.fetchLine(path))
    }

    static func windowSize(_ puppet: PuppetSession) -> (width: Double, height: Double, scale: Double) {
        let state = (try? puppet.ask("state", timeout: 10)) ?? ""
        let fields = Dictionary(state.split(separator: " ").compactMap { word -> (String, String)? in
            let parts = word.split(separator: "=", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { first, _ in first })
        let size = (fields["size"] ?? "").split(separator: "x").compactMap { Double($0) }
        return (size.first ?? 1280, size.last ?? 720, Double(fields["scale"] ?? "") ?? 1)
    }

    /// How to copy a file here back to the Mac the agent works on.
    static func fetchLine(_ file: URL) -> String {
        "scp \(NSUserName())@\(ScreenLease.shortHostName()):\(Remote.quote(file.path)) ."
    }
}

struct PuppetTextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text",
        abstract: "The text on the game window (Apple's OCR), with where each line is, in points."
    )

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    @Option(help: ArgumentHelp("A part of the window, in points: x,y,w,h.", valueName: "x,y,w,h")) var region: String?
    @Option(help: "How many lines at most.") var max: Int = 40

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        guard puppet.isRunning else { throw SCError("\(name) has stopped: \(puppet.stopReason ?? "?").", exitCode: 4) }
        puppet.touch()
        let size = PuppetShotCommand.windowSize(puppet)
        // At least 2 pixels a point, so pixel fonts are big enough to read.
        let scale = Swift.max(size.scale, 2)
        let path = puppet.shots.appendingPathComponent(".text-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: path) }
        var request = "capture \(path.path) scale=\(scale)"
        if let region { request += " region=\(region)" }
        _ = try puppet.ask(request)
        guard let image = Frames.image(at: path) else { throw SCError("Couldn't read the capture.") }
        let offset = region.map { $0.split(separator: ",").compactMap { Double($0) } } ?? []
        let lines = try Frames.text(in: image)
        if lines.isEmpty { session.ui.line("text: none found") }
        for (index, line) in lines.prefix(max).enumerated() {
            let x = Int(line.box.minX / scale + (offset.first ?? 0)), y = Int(line.box.minY / scale + (offset.count > 1 ? offset[1] : 0))
            let w = Int(line.box.width / scale), h = Int(line.box.height / scale)
            session.ui.line("t\(index + 1) \"\(line.text)\" at \(x),\(y) \(w)x\(h); centre \(x + w / 2),\(y + h / 2)")
        }
        if lines.count > max { session.ui.line("… \(lines.count - max) more (--max)") }
    }
}

struct PuppetWindowsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "windows", abstract: "The game process's windows; `kind=game` is the one acted on.")

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        puppet.touch()
        session.ui.line(try puppet.ask("windows").replacingOccurrences(of: "ok ", with: ""))
    }
}

struct PuppetLogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "The wrapp's and helpers' log: the last lines, or those matching, or counted."
    )

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    @Option(help: "Only lines matching this regular expression.") var grep: String?
    @Flag(help: "Count identical lines (times and pids aside), most frequent first.") var count = false
    @Option(help: "How many lines.") var lines: Int = 40
    @Flag(help: "The session server's log instead.") var server = false

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        let files = server ? [puppet.serverLog] : [puppet.wrappLog, puppet.helpersLog]
        var all = files.flatMap { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        if let grep {
            let pattern = try Regex(grep)
            all = all.filter { $0.contains(pattern) }
        }
        if count {
            let counted = Dictionary(all.map { (Self.normalised($0), 1) }, uniquingKeysWith: +)
            for (line, times) in counted.sorted(by: { $0.value > $1.value }).prefix(lines) {
                session.ui.line(String(format: "%6d  %@", times, line))
            }
        } else {
            all.suffix(lines).forEach { session.ui.line($0) }
        }
    }

    /// A line without what differs between repeats of it: times and pids.
    static func normalised(_ line: String) -> String {
        line.replacing(/^\d{2}:\d{2}:\d{2}(\.\d+)?\s+/, with: "")
            .replacing(/pid=\d+/, with: "pid=…")
            .replacing(/\b[0-9a-f]{4}:/, with: "…:")
    }
}

struct PuppetSavesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "saves",
        abstract: "Files the program created or changed since the session started: where its saves and settings go."
    )

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    @Option(help: "How many files at most.") var max: Int = 40

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        let app = URL(fileURLWithPath: puppet.app)
        let places = [puppet.appSupport, app.appendingPathComponent("Contents/SharedSupport/prefix/drive_c"),
                      app.appendingPathComponent("Contents/SharedSupport/prefix/user.reg").deletingLastPathComponent()]
        let found = Self.written(in: places, since: puppet.started)
        if found.isEmpty { session.ui.line("Nothing written since \(ScreenLease.clock(puppet.started)).") }
        for (path, modified, size) in found.sorted(by: { $0.1 > $1.1 }).prefix(max) {
            session.ui.line("\(ScreenLease.clock(modified))  \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))  \(path)")
        }
        if found.count > max { session.ui.line("… \(found.count - max) more (--max)") }
    }

    /// Files under `places` modified since `start`: path, time, size. The
    /// prefix's own folder is only looked at for its registry files.
    static func written(in places: [URL], since start: Date) -> [(String, Date, Int)] {
        var found: [(String, Date, Int)] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        for place in places {
            guard let walker = FileManager.default.enumerator(at: place, includingPropertiesForKeys: keys) else { continue }
            while let file = walker.nextObject() as? URL {
                if place.lastPathComponent == "prefix", file.lastPathComponent == "drive_c" {
                    walker.skipDescendants()
                    continue
                }
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= start else { continue }
                found.append((file.path, modified, values.fileSize ?? 0))
            }
        }
        return found
    }
}
