import ArgumentParser
import Foundation

/// Clicks, keys and text in a test session, sent over Screen Sharing: the one
/// way to move a test session's pointer, so it reaches any program there (an
/// installer a build runs, a dialog, the Finder), not only a game `sc puppet`
/// started. See docs/dev-cli.md#test-sessions.
struct SessionDoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "do",
        abstract: "Click, press keys or type in a test session, over Screen Sharing.",
        discussion: """
        sc session do <user> click <x> <y> [--button right] [--count 2] · move <x> <y> · \
        drag <x> <y> <x2> <y2> · key <keys> (return, escape, tab, f5, left, a, \
        cmd+q, shift+tab; several in turn, down down return; repeated, down*3) · \
        type "<text>". Points are in a `session screenshot` picture --width pixels \
        across (1600, its default size). --then runs more actions after it \
        (sc session do <user> click 920 594 --then "key return"). With --on, in \
        that Mac's test session. A session someone else has leased is left alone.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The test user whose session to act in.") var user: String
    @Argument(help: "The action and its arguments.") var action: [String]

    @Option(help: "right or middle, for that button.") var button: String?
    @Option(help: "Clicks: 2 for a double click.") var count: Int = 1
    @Option(help: "How wide, in pixels, the picture the points were read from is (a session screenshot's --max).")
    var width: Int = 1600
    @Option(name: .customLong("then"), help: ArgumentHelp(
        "Another action to do once this one's done, in quotes; repeat for more. --button and --count are the first's alone.",
        valueName: "action")) var then: [String] = []

    func run() async throws {
        let session = try Session.start(global)
        let mac = Invocation.remote.map { Remote.parse($0, localRoot: session.repo.root).host }
        let host = mac ?? ScreenLease.shortHostName()
        guard !action.isEmpty else { throw ValidationError("Say what to do: \(SessionInput.verbs.joined(separator: ", ")).") }
        var steps = [try SessionInput.parse(action, button: button, count: count)]
        for more in then { steps.append(try SessionInput.parse(SessionInput.words(more), button: nil, count: 1)) }

        let holder = ScreenLease.currentHolder(repoRoot: session.repo.root, branch: await ScreenLease.branch(of: session.repo.root))
        if let lease = try await SessionSetupCommand.othersLeases([user], on: mac, holder: holder).first?.lease {
            throw SCError("\(user)@\(host) is leased to \(lease.who)" + (lease.purpose.map { " for \"\($0)\"" } ?? "")
                          + (lease.expires.map { " until \(ScreenLease.clock($0))" } ?? "") + ": leaving it alone.",
                          hints: ["Claim a free one: sc" + (mac.map { " --on \($0)" } ?? "") + " session claim --purpose \"…\""])
        }
        // Through the keep-alive's connection into the session when it takes
        // input; otherwise a connection of this run's own.
        if try await throughKeepAlive(steps, on: mac, host: host, ui: session.ui) { return }
        session.ui.detail("The keep-alive on \(host) doesn't take input (an older one?): logging in to Screen Sharing directly.")
        try await directly(steps, on: mac, host: host, ui: session.ui)
    }

    /// Sends `steps` to the keep-alive's socket for the user (`SessionInputServer`),
    /// over SSH for another Mac. False when there's no socket to reach.
    private func throughKeepAlive(_ steps: [SessionInput], on mac: String?, host: String, ui: UI) async throws -> Bool {
        let encoder = JSONEncoder()
        var input = ""
        for step in steps {
            input += String(decoding: try encoder.encode(SessionInputRequest(input: step, width: width)), as: UTF8.self) + "\n"
        }
        input += "\n"
        let path = SessionInputServer.socketPath(for: user)
        let result = try await TestSessionAccess.asConsoleUser(mac, "[ -S \(Remote.quote(path)) ] || exit 3; exec /usr/bin/nc -U \(Remote.quote(path))",
                                                              input: input)
        if result.status == 3 { return false }
        let replies = result.output.split(whereSeparator: \.isNewline).map {
            (try? JSONDecoder().decode(SessionInputReply.self, from: Data($0.utf8))) ?? SessionInputReply(error: String($0))
        }
        // Nothing answered: nobody listening (a keep-alive that's stopped).
        if replies.isEmpty { return false }
        for (step, reply) in zip(steps, replies) {
            if let error = reply.error { throw SCError("\(user)@\(host): couldn't do \"\(step.description)\": \(error).") }
            ui.line("\(user)@\(host): \(step.description)")
        }
        guard replies.count == steps.count else {
            throw SCError("\(user)@\(host): the keep-alive answered \(replies.count) of \(steps.count) actions."
                          + (result.error.isEmpty ? "" : " \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
        return true
    }

    /// Logs in to the session's Screen Sharing for this run alone. Logged in
    /// from the Mac's own localhost, as the keep-alive is: from the network,
    /// Screen Sharing turns the test user's login down. On another Mac that's
    /// through an SSH tunnel; here, straight there (the Screen Sharing app
    /// won't connect a Mac to itself, but this isn't it). Leaves a "Viewer has
    /// disconnected" notification on the session's screen.
    private func directly(_ steps: [SessionInput], on mac: String?, host: String, ui: UI) async throws {
        let password = try await TestSessionAccess.password(of: user, on: mac)
        var port: UInt16 = 5900
        var tunnel: Process?
        defer { tunnel?.terminate() }
        if let mac {
            port = UInt16(try Network.freePort())
            let ssh = Process()
            ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            ssh.arguments = ["-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "LogLevel=ERROR",
                             "-L", "\(port):localhost:5900", "-N", mac]
            ssh.standardInput = FileHandle.nullDevice
            try ssh.run()
            tunnel = ssh
            try await TestSessionAccess.untilListening(port: Int(port), while: ssh)
        }
        let connection = try ScreenSharingConnection(user: user, password: password, host: "127.0.0.1", port: port)
        let scale = Double(connection.width) / Double(max(1, width))
        for step in steps {
            try await SessionInput.perform(step, on: connection, scale: scale)
            ui.line("\(user)@\(host): \(step.description)")
        }
        // Let the server deliver the last events before the connection goes.
        try await Task.sleep(for: .milliseconds(300))
    }
}

/// What `session do` sends, and how it's read from the command line.
enum SessionInput: Codable, Equatable {
    case click(x: Double, y: Double, buttons: UInt8, count: Int)
    case move(x: Double, y: Double)
    case drag(x: Double, y: Double, toX: Double, toY: Double)
    /// Chords pressed in turn, each its keysyms held together.
    case keys([[UInt32]])
    case type(String)

    static let verbs = ["click", "move", "drag", "key", "type"]

    var description: String {
        switch self {
        case let .click(x, y, buttons, count):
            let which = buttons == 4 ? "right-" : buttons == 2 ? "middle-" : ""
            return "\(count > 1 ? "double-" : "")\(which)clicked at \(Int(x)),\(Int(y))"
        case let .move(x, y): return "moved to \(Int(x)),\(Int(y))"
        case let .drag(x, y, toX, toY): return "dragged from \(Int(x)),\(Int(y)) to \(Int(toX)),\(Int(toY))"
        case let .keys(chords): return "pressed \(chords.count) key\(chords.count == 1 ? "" : "s")"
        case let .type(text): return "typed \(text.count) characters"
        }
    }

    /// An action's words, split at spaces outside quotes, as a shell would.
    static func words(_ text: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func parse(_ words: [String], button: String?, count: Int) throws -> SessionInput {
        guard let verb = words.first else { throw ValidationError("Say what to do: \(verbs.joined(separator: ", ")).") }
        let rest = Array(words.dropFirst())
        func numbers(_ needed: Int) throws -> [Double] {
            let values = rest.compactMap(Double.init)
            guard rest.count == needed, values.count == needed else {
                throw ValidationError("\(verb) takes \(needed) numbers, the points in the screenshot: got \(rest.joined(separator: " ")).")
            }
            return values
        }
        switch verb {
        case "click":
            let point = try numbers(2)
            let buttons: UInt8
            switch button {
            case nil, "left": buttons = 1
            case "middle": buttons = 2
            case "right": buttons = 4
            case let other?: throw ValidationError("--button is left, middle or right, not \(other).")
            }
            return .click(x: point[0], y: point[1], buttons: buttons, count: max(1, count))
        case "move":
            let point = try numbers(2)
            return .move(x: point[0], y: point[1])
        case "drag":
            let points = try numbers(4)
            return .drag(x: points[0], y: points[1], toX: points[2], toY: points[3])
        case "key":
            guard !rest.isEmpty else { throw ValidationError("key takes the keys to press: return, cmd+q, down*3…") }
            return .keys(try rest.flatMap(chords))
        case "type":
            guard !rest.isEmpty else { throw ValidationError("type takes the text to type, in quotes.") }
            return .type(rest.joined(separator: " "))
        default:
            throw ValidationError("\(verb) isn't something sc session do does: \(verbs.joined(separator: ", ")).")
        }
    }

    /// One word of `key`: a chord, `cmd+shift+z`, repeated by `*n`.
    static func chords(_ word: String) throws -> [[UInt32]] {
        var chord = Substring(word), times = 1
        if let star = word.lastIndex(of: "*"), let n = Int(word[word.index(after: star)...]), n > 0 {
            chord = word[..<star]
            times = n
        }
        let keysyms = try chord.split(separator: "+", omittingEmptySubsequences: false).map { name -> UInt32 in
            guard let keysym = keysym(String(name)) else { throw ValidationError("\(name) isn't a key sc knows (in \(word)).") }
            return keysym
        }
        return Array(repeating: keysyms, count: times)
    }

    /// The X11 keysym Screen Sharing takes for a key's name: a modifier, a
    /// named key, or a single character.
    static func keysym(_ name: String) -> UInt32? {
        let named: [String: UInt32] = [
            "shift": 0xFFE1, "ctrl": 0xFFE3, "control": 0xFFE3, "alt": 0xFFE9, "option": 0xFFE9, "opt": 0xFFE9,
            "cmd": 0xFFEB, "command": 0xFFEB,
            "return": 0xFF0D, "enter": 0xFF0D, "escape": 0xFF1B, "esc": 0xFF1B, "tab": 0xFF09, "space": 0x20,
            "backspace": 0xFF08, "delete": 0xFF08, "forwarddelete": 0xFFFF,
            "left": 0xFF51, "up": 0xFF52, "right": 0xFF53, "down": 0xFF54,
            "home": 0xFF50, "end": 0xFF57, "pageup": 0xFF55, "pagedown": 0xFF56,
        ]
        let lower = name.lowercased()
        if let keysym = named[lower] { return keysym }
        if lower.count >= 2, lower.first == "f", let n = Int(lower.dropFirst()), (1...20).contains(n) { return 0xFFBE + UInt32(n - 1) }
        guard name.unicodeScalars.count == 1, let scalar = name.unicodeScalars.first else { return nil }
        return character(scalar)
    }

    /// A character's keysym: Latin-1 as itself, anything else as Unicode.
    static func character(_ scalar: Unicode.Scalar) -> UInt32 {
        if scalar == "\n" { return 0xFF0D }
        if scalar == "\t" { return 0xFF09 }
        return scalar.value < 0x100 ? scalar.value : 0x0100_0000 | scalar.value
    }

    static func perform(_ input: SessionInput, on connection: ScreenSharingConnection, scale: Double) async throws {
        func pixels(_ x: Double, _ y: Double) -> (Int, Int) { (Int((x * scale).rounded()), Int((y * scale).rounded())) }
        func pause(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }
        switch input {
        case let .click(x, y, buttons, count):
            let (px, py) = pixels(x, y)
            try connection.pointer(x: px, y: py)
            try await pause(100)
            for _ in 0..<count {
                try connection.pointer(x: px, y: py, buttons: buttons)
                try await pause(60)
                try connection.pointer(x: px, y: py)
                try await pause(60)
            }
        case let .move(x, y):
            let (px, py) = pixels(x, y)
            try connection.pointer(x: px, y: py)
        case let .drag(x, y, toX, toY):
            let (fromX, fromY) = pixels(x, y), (endX, endY) = pixels(toX, toY)
            try connection.pointer(x: fromX, y: fromY)
            try await pause(100)
            try connection.pointer(x: fromX, y: fromY, buttons: 1)
            for step in 1...10 {
                try await pause(30)
                try connection.pointer(x: fromX + (endX - fromX) * step / 10, y: fromY + (endY - fromY) * step / 10, buttons: 1)
            }
            try await pause(60)
            try connection.pointer(x: endX, y: endY)
        case let .keys(chords):
            for (index, chord) in chords.enumerated() {
                if index > 0 { try await pause(300) }
                for keysym in chord { try connection.key(keysym, down: true) }
                try await pause(60)
                for keysym in chord.reversed() { try connection.key(keysym, down: false) }
            }
        case let .type(text):
            for scalar in text.unicodeScalars {
                let keysym = character(scalar)
                try connection.key(keysym, down: true)
                try connection.key(keysym, down: false)
                try await pause(20)
            }
        }
    }
}
