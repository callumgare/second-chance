import ArgumentParser
import Foundation

/// Running in the logged-in user's GUI (Aqua) session.
///
/// A shell started over SSH lives in launchd's Background session, which has
/// no WindowServer connection: Wine's graphics driver can't load there, so
/// installers exit 1 and games never appear. Commands that open windows call
/// `ensure`, which — outside Aqua — re-runs the same sc command as a one-off
/// LaunchAgent in `gui/<uid>`, under a pty (so TTY-gated output still shows),
/// streams its output back, forwards keystrokes, and exits with its status.
enum GUISession {
    /// Whether the command needs to *see or click* the screen
    /// (WrappPuppeteer), or only to open windows.
    enum Need {
        case windows
        case screen
    }

    static func managerName() async -> String {
        (try? await Proc.collect("/bin/launchctl", ["managername"]).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }

    static func isScreenLocked() async -> Bool {
        guard let result = try? await Proc.collect("/usr/sbin/ioreg", ["-n", "Root", "-d1", "-a"]) else { return false }
        return result.output.contains("<key>CGSSessionScreenIsLocked</key>")
    }

    /// Return when this process can open windows; otherwise re-run the
    /// command in the GUI session and finish with its exit status (by
    /// throwing `ExitCode`).
    static func ensure(_ session: Session, need: Need) async throws {
        try await checkLock(session, need: need)
        guard await managerName() != "Aqua" else { return }
        guard let executable = Bundle.main.executablePath else {
            throw SCError("Couldn't find sc's own executable to re-run it in the GUI session.")
        }
        let status = try await run(
            command: [executable] + Invocation.forwarding(logs: session.mode),
            session: session
        )
        throw ExitCode(status)
    }

    /// A locked screen still has a GUI session, so Wine runs — but synthetic
    /// clicks land on the lock screen and screenshots don't show the game.
    /// Commands that drive the screen fail up front; the rest warn.
    static func checkLock(_ session: Session, need: Need) async throws {
        guard await isScreenLocked() else { return }
        let user = NSUserName()
        switch need {
        case .screen:
            throw SCError("\(user)'s screen is locked, and this command needs to see and click the game.",
                          hints: ["Unlock it (at the Mac or via Screen Sharing), then run it again."])
        case .windows:
            session.ui.warning("\(user)'s screen is locked. Windows will open, but you won't see them until it's unlocked.")
        }
    }

    /// Run `command` in the GUI session and return its exit status.
    static func run(command: [String], session: Session) async throws -> Int32 {
        let user = NSUserName()
        let consoleUser = (try? FileManager.default.attributesOfItem(atPath: "/dev/console")[.ownerAccountName] as? String) ?? ""
        guard consoleUser == user else {
            throw SCError("There's no GUI session for \(user) — the console belongs to '\(consoleUser)'.",
                          hints: ["Log in at the Mac (or via Screen Sharing) as \(user) first."])
        }
        if await managerName() == "Aqua" {
            // Already there (e.g. `sc in-gui-session` from a local terminal).
            return try await Proc.inheritingTerminal(command[0], Array(command.dropFirst()), cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        }

        let job = try LaunchAgentJob(command: command)
        defer { job.cleanUp() }
        session.ui.detail("Running in \(user)'s GUI session…")
        try job.start()

        // A dropped SSH connection without a pty sends no signal: sshd just
        // exits and the shells in between are reparented to launchd. So note
        // every ancestor now and treat any of them disappearing as the caller
        // being gone.
        let ancestors = Ancestors.current()
        let forwarder = session.terminal.canReadKeys ? KeyForwarder(fifo: job.inputFIFO) : nil
        forwarder?.start()
        defer { forwarder?.stop() }

        let output = LogFollower(url: job.logFile, crlfToLF: !session.terminal.isInteractive)
        while true {
            output.drain()
            if let status = job.exitStatus() {
                try await Task.sleep(for: .milliseconds(200))
                output.drain()
                return status
            }
            if !ancestors.allAlive() { return 129 }
            if !job.isRunning() {
                try await Task.sleep(for: .seconds(1))
                output.drain()
                if let status = job.exitStatus() { return status }
                session.ui.error(SCError("The command exited without reporting an exit status."))
                return 1
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// The one-off LaunchAgent the command runs as.
private final class LaunchAgentJob: @unchecked Sendable {
    let label = "au.gare.callum.second-chance.in-gui-session.\(getpid())"
    let domain = "gui/\(getuid())"
    let workDir: URL
    let logFile: URL
    let exitFile: URL
    let inputFIFO: URL
    private let plist: URL
    private var fifoHolder: FileHandle?

    init(command: [String]) throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-gui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        logFile = workDir.appendingPathComponent("output.log")
        exitFile = workDir.appendingPathComponent("exit-code")
        inputFIFO = workDir.appendingPathComponent("input")
        plist = workDir.appendingPathComponent("\(label).plist")
        guard mkfifo(inputFIFO.path, 0o600) == 0 else {
            throw SCError("Couldn't create the input pipe for the GUI session.")
        }

        // The job script recreates this process's environment and directory,
        // then runs the command and records its exit status.
        var script = "#!/bin/bash\n"
        for (key, value) in ProcessInfo.processInfo.environment.sorted(by: { $0.key < $1.key })
        where key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil {
            script += "export \(key)=\(Self.quote(value))\n"
        }
        script += "cd \(Self.quote(FileManager.default.currentDirectoryPath)) || exit 1\n"
        script += command.map(Self.quote).joined(separator: " ") + "\n"
        script += "echo $? > \(Self.quote(exitFile.path))\n"
        let jobScript = workDir.appendingPathComponent("job.sh")
        try script.write(to: jobScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: jobScript.path)

        // `script` gives the command a pty. Its stdin comes from the FIFO,
        // which sc holds open (and writes keystrokes into) — it must never
        // see EOF, or `script` forwards it into the pty as a stray ^D. The
        // FIFO goes through `cat` because `script` rejects a FIFO as stdin
        // ("tcgetattr/ioctl: Operation not supported on socket") but accepts
        // a pipe.
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/bash", "-c", "/bin/cat \"$1\" | exec /usr/bin/script -q /dev/null \"$0\"", jobScript.path, inputFIFO.path],
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path,
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
        try data.write(to: plist)
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
    }

    func start() throws {
        // Open the FIFO read-write so this doesn't block waiting for the job
        // to open its end, and so it stays open for as long as sc runs.
        let fd = open(inputFIFO.path, O_RDWR)
        guard fd >= 0 else { throw SCError("Couldn't open the GUI session's input pipe.") }
        fifoHolder = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", domain, plist.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SCError("launchctl couldn't start the job in \(domain) (exit \(process.terminationStatus)).")
        }
    }

    func exitStatus() -> Int32? {
        guard let text = try? String(contentsOf: exitFile, encoding: .utf8),
              let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return code
    }

    func isRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "\(domain)/\(label)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("pid = ")
    }

    /// Booting out the job kills its whole process group, which stops the
    /// command if sc is leaving early (Ctrl-C, dropped connection).
    func cleanUp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "\(domain)/\(label)"]
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil { process.waitUntilExit() }
        try? fifoHolder?.close()
        try? FileManager.default.removeItem(at: workDir)
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Copies new output from the job's log file to stdout as it appears.
private final class LogFollower {
    private let handle: FileHandle?
    private let crlfToLF: Bool

    init(url: URL, crlfToLF: Bool) {
        handle = try? FileHandle(forReadingFrom: url)
        self.crlfToLF = crlfToLF
    }

    func drain() {
        guard let handle, let data = try? handle.readToEnd(), !data.isEmpty else { return }
        if crlfToLF {
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            FileHandle.standardOutput.write(Data(text.utf8))
        } else {
            FileHandle.standardOutput.write(data)
        }
    }
}

/// Forwards this terminal's keystrokes into the job's pty, so interactive
/// keys (like `l` during a wrapp build) work in the re-run too.
private final class KeyForwarder: @unchecked Sendable {
    private let fifo: URL
    private var thread: Thread?
    private let lock = NSLock()
    private var stopped = false

    init(fifo: URL) { self.fifo = fifo }

    func start() {
        guard TTY.enterKeyMode() else { return }
        let fd = open(fifo.path, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { TTY.leaveKeyMode(); return }
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 64)
            while let self, !self.isStopped {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count > 0 { _ = write(fd, buffer, count) }
            }
            close(fd)
        }
        self.thread = thread
        thread.start()
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    func stop() {
        lock.withLock { stopped = true }
        TTY.leaveKeyMode()
    }
}

/// The chain of parent processes, to notice when the caller has gone.
private struct Ancestors {
    let pids: [pid_t]

    static func current() -> Ancestors {
        var pids: [pid_t] = []
        var pid = getppid()
        while pid > 1 {
            pids.append(pid)
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
            pid = info.kp_eproc.e_ppid
        }
        return Ancestors(pids: pids)
    }

    /// `kill(pid, 0)` fails with EPERM for a live process sc may not signal
    /// (sshd's privileged half is root's), so only ESRCH means gone.
    func allAlive() -> Bool {
        pids.allSatisfy { kill($0, 0) == 0 || errno != ESRCH }
    }
}
