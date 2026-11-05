import Foundation
import Logging
import ProcessKit
import WineKit

/// A puppet session that runs a Windows program in a Wine prefix, for an
/// installer or any other program a port needs to drive by hand
/// (`sc puppet start <name> --wine <wrapp> -- <program>`): the wrapp's Wine,
/// a prefix (by default a clone of the wrapp's, in the session's folder),
/// AutoIt laid into it for `controls` and acting on a control by its handle,
/// and a disc shown as D: when one is given. Kept beside the session's own
/// file, so the session's file needn't know about Wine.
/// See docs/dev-cli.md#wine-dialogs-and-installers.
struct PuppetWineSetup: Codable, Equatable {
    /// The wrapp whose Wine runs the program.
    var wrapp: String
    /// The prefix it runs in.
    var prefix: String
    /// Whether the prefix is the session's own clone, which `start` made and
    /// the next `start` of the same name removes; otherwise the tools laid
    /// into it are taken out again when the session stops.
    var ownsPrefix: Bool
    /// The program and its arguments, as given after `--`: a Windows path
    /// (`D:\SETUP.EXE`), or a Mac one.
    var command: [String]
    /// AutoIt's folder on this Mac, copied into the prefix.
    var autoIt: String
    /// A disc image or folder shown as D:, a CD-ROM drive.
    var disc: String?
    /// Where a disc image was mounted, and its device, to detach when the
    /// session stops.
    var discMount: String?
    var discDevice: String?

    static func file(_ folder: URL) -> URL { folder.appendingPathComponent("wine.json") }

    static func load(_ puppet: PuppetSession) -> PuppetWineSetup? {
        guard let data = try? Data(contentsOf: file(puppet.folder)) else { return nil }
        return try? JSONDecoder().decode(PuppetWineSetup.self, from: data)
    }

    func save(in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.file(folder), options: .atomic)
    }

    var wine: Wine { Wine(wrapp: URL(fileURLWithPath: wrapp), prefix: URL(fileURLWithPath: prefix)) }

    /// Where AutoIt, the scripts and their answers go in the prefix.
    var tools: URL { URL(fileURLWithPath: prefix).appendingPathComponent("drive_c/\(Self.toolsFolder)") }
    static let toolsFolder = "sc-puppet"

    /// The Windows name of a file in `tools`.
    static func windowsPath(ofTool name: String) -> String { #"C:\"# + toolsFolder + #"\"# + name }

    /// The letter a disc is shown as.
    static let discLetter: Character = "d"

    // MARK: Working out what to run

    /// The setup `start --wine` asks for, checked and saved in the
    /// session's `folder`, which it makes.
    static func make(wine: String, prefix: String?, disc: String?, autoIt: String?, command: [String],
                     folder: URL, repo: URL) throws -> PuppetWineSetup {
        let found = try resolve(wine: wine, prefix: prefix, sessionFolder: folder)
        let disc = disc.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        if let disc, !FileManager.default.fileExists(atPath: disc) { throw SCError("There's no \(disc).") }
        let program = command[0]
        if !isWindowsPath(program), !FileManager.default.fileExists(atPath: (program as NSString).expandingTildeInPath) {
            throw SCError("There's no \(program).", hints: ["A program on the disc or in the prefix: its Windows path, D:\\SETUP.EXE"])
        }
        let setup = PuppetWineSetup(wrapp: found.wrapp.path, prefix: found.prefix.path, ownsPrefix: found.owns, command: command,
                                    autoIt: try Self.autoIt(autoIt, repo: repo).path, disc: disc)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try setup.save(in: folder)
        return setup
    }

    /// The wrapp and prefix `--wine` names, with `--prefix` when given:
    /// a wrapp runs in a clone of its prefix in the session's folder (or in
    /// `--prefix`, cloned from the wrapp's when it isn't there yet); a
    /// wrapp's prefix itself runs in place.
    static func resolve(wine given: String, prefix: String?, sessionFolder: URL) throws -> (wrapp: URL, prefix: URL, owns: Bool) {
        let path = URL(fileURLWithPath: (given as NSString).expandingTildeInPath).standardizedFileURL
        let wineIn: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/SharedSupport/wine/bin/wine").path) }
        if wineIn(path) {
            if let prefix {
                return (path, URL(fileURLWithPath: (prefix as NSString).expandingTildeInPath).standardizedFileURL, false)
            }
            return (path, sessionFolder.appendingPathComponent("prefix"), true)
        }
        // A wrapp's own prefix: <app>/Contents/SharedSupport/prefix.
        let app = path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if path.lastPathComponent == "prefix", wineIn(app) {
            guard prefix == nil else { throw SCError("--wine names a prefix already; --prefix is for a wrapp.") }
            return (app, path, false)
        }
        throw SCError("\(path.path) isn't a wrapp with Wine in it, or a wrapp's prefix.",
                      hints: ["A wrapp: --wine <app>, with --prefix <dir> to run in a prefix of its own",
                              "Any Wine wrapp will do for its Wine: sc wrapp build freeware/skifree"])
    }

    /// AutoIt's folder: the one given, this checkout's build of the app's, or
    /// the build's download of it.
    static func autoIt(_ given: String?, repo: URL) throws -> URL {
        let candidates: [String?] = [
            given.map { ($0 as NSString).expandingTildeInPath },
            repo.appendingPathComponent("DerivedData/Build/Products/Debug/Second Chance.app/Contents/Resources/autoit").path,
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SecondChance/autoit-3.3.18.0").path,
        ]
        guard let found = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("AutoIt3.exe").path)
        }) else {
            throw SCError("No AutoIt to list a dialog's controls with: this checkout hasn't built the app.",
                          hints: ["Build it: sc app build", "Or name one: --autoit <folder with AutoIt3.exe>"])
        }
        return URL(fileURLWithPath: found)
    }

    /// Whether `argument` names a Windows file (`D:\SETUP.EXE`, `C:/x.exe`)
    /// rather than a Mac one.
    static func isWindowsPath(_ argument: String) -> Bool {
        argument.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    }

    /// The Wine command that runs `command`: `start /wait`, from the
    /// program's own folder, as an installer needs to find its files. A Mac
    /// path on the disc is named by its D: path; any other Mac path's folder
    /// is lent as Y: (`WineDrives.lend`), and `lend` is that folder.
    static func wineCommand(for command: [String], discMount: String?) -> (command: WineCommand, lend: URL?) {
        let program = command[0], arguments = Array(command.dropFirst())
        if isWindowsPath(program) {
            let windows = program.replacingOccurrences(of: "/", with: #"\"#)
            let folder = windows.split(separator: #"\"#, omittingEmptySubsequences: false).dropLast().joined(separator: #"\"#)
            return (.wine(["start", "/wait", "/d", folder.hasSuffix(":") ? folder + #"\"# : folder, windows] + arguments), nil)
        }
        let file = URL(fileURLWithPath: (program as NSString).expandingTildeInPath).standardizedFileURL
        if let discMount, file.path.hasPrefix(discMount + "/") {
            let relative = String(file.path.dropFirst(discMount.count + 1)).replacingOccurrences(of: "/", with: #"\"#)
            let windows = "\(Character(discLetter.uppercased())):\\" + relative
            return wineCommand(for: [windows] + arguments, discMount: nil)
        }
        let folder = file.deletingLastPathComponent()
        return (.start(file.path, arguments, unixPath: true, in: folder), folder)
    }

    /// Wine's own programs, which run in every session: they don't keep a
    /// session's program alive.
    static let sessionPrograms: Set<String> = [
        "explorer.exe", "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe",
        "start.exe", "conhost.exe", "wineboot.exe", "tabtip.exe", "autoit3.exe", "wineserver", "wine", "wine64",
        "wine-preloader", "wine64-preloader", "reg.exe", "rundll32.exe",
    ]

    /// Whether a running process named `name` (a path, Windows or Mac) is a
    /// program of the session's rather than Wine's own.
    static func isSessionsOwn(_ name: String) -> Bool {
        let last = name.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? name
        return !sessionPrograms.contains(last.lowercased())
    }
}

/// A request from a client for the server to run an AutoIt script in the
/// session's prefix. Wine's programs need the GUI session to start (its
/// display driver doesn't load in an SSH shell's), and the server is in it,
/// so clients hand it the script, by files in the session's folder.
struct PuppetWineRequest: Codable {
    /// The script's file in the prefix's tools folder.
    var script: String
    var arguments: [String]
}

struct PuppetWineReply: Codable {
    var error: String?
}

enum PuppetWineChannel {
    static func folder(_ puppet: PuppetSession) -> URL { puppet.folder.appendingPathComponent("autoit-requests") }

    /// Run AutoIt with `script` in the session's prefix, through its server,
    /// and return what the script wrote to the file it's given as its first
    /// argument, before `arguments`.
    static func runAutoIt(_ puppet: PuppetSession, setup: PuppetWineSetup, script: String, arguments: [String],
                          timeout: TimeInterval = 90) async throws -> String {
        let id = UUID().uuidString.prefix(8).lowercased()
        let scriptFile = setup.tools.appendingPathComponent("\(id).au3")
        let answerFile = setup.tools.appendingPathComponent("\(id).txt")
        try FileManager.default.createDirectory(at: setup.tools, withIntermediateDirectories: true)
        // UTF-8 with its mark, which AutoIt reads a script's text by.
        try (Data([0xEF, 0xBB, 0xBF]) + Data(script.utf8)).write(to: scriptFile)
        defer {
            try? FileManager.default.removeItem(at: scriptFile)
            try? FileManager.default.removeItem(at: answerFile)
        }
        let requests = folder(puppet)
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let request = PuppetWineRequest(script: scriptFile.lastPathComponent,
                                        arguments: [PuppetWineSetup.windowsPath(ofTool: answerFile.lastPathComponent)] + arguments)
        let requestFile = requests.appendingPathComponent("\(id).request")
        let replyFile = requests.appendingPathComponent("\(id).reply")
        try JSONEncoder().encode(request).write(to: requestFile, options: .atomic)
        defer { try? FileManager.default.removeItem(at: replyFile) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: replyFile), let reply = try? JSONDecoder().decode(PuppetWineReply.self, from: data) {
                if let error = reply.error { throw SCError("AutoIt couldn't run in \(puppet.name)'s prefix: \(error)") }
                return Self.decode((try? Data(contentsOf: answerFile)) ?? Data())
            }
            guard puppet.isRunning || (try? PuppetSession.load(puppet.name))?.isRunning == true else {
                throw SCError("\(puppet.name) has stopped.", exitCode: 4)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try? FileManager.default.removeItem(at: requestFile)
        throw SCError("\(puppet.name)'s server didn't run AutoIt within \(Int(timeout)) s.", hints: ["Its log: sc puppet log \(puppet.name) --server"])
    }

    /// AutoIt's answer: UTF-8, without a byte-order mark.
    static func decode(_ data: Data) -> String {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Answer the requests waiting, one at a time, in the order they came.
    static func answer(in puppet: PuppetSession, setup: PuppetWineSetup, log: (String) -> Void) async {
        let requests = folder(puppet)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: requests.path)) ?? []).filter { $0.hasSuffix(".request") }.sorted()
        for name in names {
            let file = requests.appendingPathComponent(name)
            let reply = requests.appendingPathComponent(name.replacingOccurrences(of: ".request", with: ".reply"))
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file), let request = try? JSONDecoder().decode(PuppetWineRequest.self, from: data) else { continue }
            var answer = PuppetWineReply()
            do {
                _ = try await setup.wine.output(of: .program(PuppetWineSetup.windowsPath(ofTool: "autoit\\AutoIt3.exe"),
                                                             ["/ErrorStdOut", PuppetWineSetup.windowsPath(ofTool: request.script)] + request.arguments),
                                                timeout: 60)
            } catch {
                answer.error = "\(error)"
                log("AutoIt \(request.script): \(error)")
            }
            if let encoded = try? JSONEncoder().encode(answer) { try? encoded.write(to: reply, options: .atomic) }
        }
    }
}

/// The server's half of a Wine session: lays in the prefix, the tools and
/// the disc, brings Wine's desktop up, starts the program with the helper
/// armed in every process, answers AutoIt requests, and ends the session.
enum PuppetWineServer {
    static func run(_ puppet: inout PuppetSession, setup initial: PuppetWineSetup, log: (String) -> Void) async throws -> String {
        var setup = initial
        let logFile = puppet.wrappLog
        let logger = Logger(label: "sc.puppet.wine") { _ in FileLogHandler(file: logFile) }
        let files = FileManager.default
        let wrapp = URL(fileURLWithPath: setup.wrapp), prefix = URL(fileURLWithPath: setup.prefix)

        if !files.fileExists(atPath: prefix.path) {
            log("cloning \(wrapp.lastPathComponent)'s prefix into \(prefix.path)")
            try files.createDirectory(at: prefix.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A clone on APFS: instant, and the wrapp's own stays as it is.
            try files.copyItem(at: wrapp.appendingPathComponent("Contents/SharedSupport/prefix"), to: prefix)
        }
        let autoItCopy = setup.tools.appendingPathComponent("autoit")
        if !files.fileExists(atPath: autoItCopy.appendingPathComponent("AutoIt3.exe").path) {
            try files.createDirectory(at: setup.tools, withIntermediateDirectories: true)
            try files.copyItem(at: URL(fileURLWithPath: setup.autoIt), to: autoItCopy)
        }
        let wine = setup.wine
        if let disc = setup.disc {
            let mount: String
            if disc.lowercased().hasSuffix(".iso") || disc.lowercased().hasSuffix(".dmg") || disc.lowercased().hasSuffix(".cdr") {
                let attached = try await attach(disc)
                (setup.discMount, setup.discDevice) = (attached.mount, attached.device)
                try setup.save(in: puppet.folder)
                mount = attached.mount
                log("mounted \(URL(fileURLWithPath: disc).lastPathComponent) read-only at \(mount)")
            } else {
                mount = disc
                setup.discMount = disc
                try setup.save(in: puppet.folder)
            }
            try wine.drives.mount(URL(fileURLWithPath: mount), as: PuppetWineSetup.discLetter)
            try await wine.drives.setKind(.cdrom, of: PuppetWineSetup.discLetter)
        }

        let desktop = await WineDesktop.start(wine, logger: logger, outputLogger: logger)
        let (command, lend) = PuppetWineSetup.wineCommand(for: setup.command, discMount: setup.discMount)
        if let lend { try wine.drives.lend(lend) }
        var armed = [
            "SECOND_CHANCE_PUPPET_DIR": puppet.sockets.path,
            "PUPPET_CONTROL_EXE": "*",
            "IN_PROCESS_HELPERS_LOG": puppet.helpersLog.path,
        ]
        if let winedebug = ProcessInfo.processInfo.environment["SECOND_CHANCE_WINEDEBUG"] { armed["WINEDEBUG"] = winedebug }
        let launcher = try wine.start(command, environment: armed, output: .log(logger))
        puppet.wrappPID = launcher.pid
        try puppet.save()
        log("started \(setup.command.joined(separator: " ")) in \(prefix.path) (launcher pid \(launcher.pid))")

        var reason = ""
        var quietChecks = 0
        var lastCheck = Date.distantPast
        while reason.isEmpty {
            await PuppetWineChannel.answer(in: puppet, setup: setup, log: log)
            try await Task.sleep(for: .milliseconds(200))
            guard Date().timeIntervalSince(lastCheck) >= 2 else { continue }
            lastCheck = Date()
            let idleFor = Date().timeIntervalSince(puppet.idleSince)
            if files.fileExists(atPath: puppet.stopFile.path) {
                reason = "asked to stop"
            } else if idleFor >= puppet.idleMinutes * 60 {
                reason = "idle for \(ScreenLease.duration(idleFor))"
            } else if Date().timeIntervalSince(puppet.started) >= puppet.maxMinutes * 60 {
                reason = "ran for its --max"
            } else if !(puppet.wrappPID.map { kill($0, 0) == 0 } ?? false) {
                // The launcher waits only for the program it started: an
                // installer's bootstrap often hands over to another and exits.
                let own = wine.server.programs().filter { PuppetWineSetup.isSessionsOwn($0.name) }
                if let newest = own.max(by: { $0.pid < $1.pid }) {
                    quietChecks = 0
                    puppet.wrappPID = newest.pid
                    try? puppet.save()
                    log("now following \(newest.name) (pid \(newest.pid))")
                } else {
                    quietChecks += 1
                    if quietChecks >= 2 { reason = "the program ended (no programs left in the prefix)" }
                }
            }
        }
        log("stopping: \(reason)")
        desktop?.release()
        if launcher.isRunning || !wine.server.programs().isEmpty {
            await wine.server.stop()
            if await !wine.server.waitUntilStopped(timeout: 15) {
                log("Wine still running 15 s after wineserver -k: killing it")
                await wine.server.kill()
            }
        }
        let left = wine.server.programs()
        if !left.isEmpty { log("left running: \(left.map { "\($0.name) (\($0.pid))" }.joined(separator: ", "))") }
        if lend != nil { wine.drives.takeBack() }
        if setup.disc != nil { wine.drives.block(String(PuppetWineSetup.discLetter)) }
        if let device = setup.discDevice {
            let detached = try? await Proc.collect("/usr/bin/hdiutil", ["detach", device])
            log(detached?.succeeded == true ? "detached \(device)" : "couldn't detach \(device): \(detached?.error ?? "?")")
        }
        if !setup.ownsPrefix { try? files.removeItem(at: setup.tools) }
        return reason
    }

    /// Mount a disc image read-only, out of Finder's sight: its mount point
    /// and device.
    static func attach(_ image: String) async throws -> (mount: String, device: String) {
        let result = try await Proc.collect("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noverify", "-plist", image])
        guard result.succeeded else { throw SCError("Couldn't mount \(image): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))") }
        guard let found = mountPoint(plist: Data(result.output.utf8)) else { throw SCError("hdiutil mounted \(image) but named no mount point.") }
        return found
    }

    /// The mount point and its device from `hdiutil attach -plist`.
    static func mountPoint(plist data: Data) -> (mount: String, device: String)? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let mount = entity["mount-point"] as? String, let device = entity["dev-entry"] as? String { return (mount, device) }
        }
        return nil
    }
}

/// Swift-log lines into a session's log file, for Wine's output and what
/// WineKit says about running it.
struct FileLogHandler: LogHandler {
    let file: URL
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .notice

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(stamp) \(event.message)\n".utf8))
    }
}
