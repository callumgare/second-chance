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
/// The job outlives a dropped connection; `sc attach` follows it again.
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

        let job = try LaunchAgentJob(command: command, in: session.repo.scJobs)
        session.ui.detail("Running in \(user)'s GUI session (job \(job.id))…")
        try job.start()
        return try await follow(job, session: session)
    }

    /// The exit status `follow` returns when its caller has gone and the job
    /// is left running: 128 + SIGHUP, as for a hung-up shell.
    static let detachedStatus: Int32 = 129

    /// Stream a job's output (from the start) and forward keystrokes until it
    /// exits, then return its status.
    ///
    /// Stopping and losing the caller are different things. Ctrl-C stops the
    /// job. A dropped connection only stops following it: the job carries on,
    /// and `sc attach` picks it up again.
    static func follow(_ job: LaunchAgentJob, session: Session) async throws -> Int32 {
        // A dropped SSH connection without a pty sends no signal: sshd just
        // exits and the shells in between are reparented to launchd. So note
        // every ancestor now and treat any of them disappearing as the caller
        // being gone. (With a pty it sends SIGHUP; see the catch below.)
        let ancestors = Ancestors.current()
        let forwarder = session.terminal.canReadKeys ? KeyForwarder(fifo: job.inputFIFO) : nil
        forwarder?.start()
        defer { forwarder?.stop() }

        let output = LogFollower(url: job.logFile, crlfToLF: !session.terminal.isInteractive)
        do {
            while true {
                output.drain()
                if let status = job.exitStatus() {
                    try await Task.sleep(for: .milliseconds(200))
                    output.drain()
                    job.unload()
                    return status
                }
                if !ancestors.allAlive() { return detachedStatus }
                if !job.isRunning() {
                    try await Task.sleep(for: .seconds(1))
                    output.drain()
                    job.unload()
                    if let status = job.exitStatus() { return status }
                    session.ui.error(SCError("The command exited without reporting an exit status."))
                    return 1
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch is CancellationError {
            if !Interrupts.hungUp { job.stop() }
            throw CancellationError()
        }
    }
}

/// A one-off LaunchAgent a command runs as, kept in its own directory under
/// `DerivedData/sc-jobs/` so it outlives the sc that started it: a later
/// `sc attach` finds it there, replays its output and waits for its exit.
final class LaunchAgentJob: @unchecked Sendable {
    static let labelPrefix = "au.gare.callum.second-chance.sc-job."
    /// Finished jobs kept for `sc attach` to replay; older ones are removed.
    static let keptFinished = 10

    let id: String
    let workDir: URL
    var label: String { Self.labelPrefix + id }
    let domain = "gui/\(getuid())"
    var logFile: URL { workDir.appendingPathComponent("output.log") }
    var exitFile: URL { workDir.appendingPathComponent("exit-code") }
    var inputFIFO: URL { workDir.appendingPathComponent("input") }
    /// The command line, for `sc attach --list`.
    var commandFile: URL { workDir.appendingPathComponent("command") }
    private var plist: URL { workDir.appendingPathComponent("\(label).plist") }
    private var fifoHolder: FileHandle?

    /// An existing job, found by `all(in:)`.
    private init(workDir: URL) {
        self.workDir = workDir
        id = workDir.lastPathComponent
    }

    /// A new job for `command`, not yet started.
    convenience init(command: [String], in jobsDir: URL, now: Date = Date()) throws {
        Self.prune(in: jobsDir)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        self.init(workDir: jobsDir.appendingPathComponent("\(stamp.string(from: now))-\(getpid())"))
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        guard mkfifo(inputFIFO.path, 0o600) == 0 else {
            throw SCError("Couldn't create the input pipe for the GUI session.")
        }
        try command.joined(separator: " ").write(to: commandFile, atomically: true, encoding: .utf8)

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
        // which must never see EOF, or `script` forwards it into the pty as a
        // stray ^D. The job's own bash holds it open (fd 3) for as long as the
        // job runs, so it outlives whichever sc is following — keystrokes from
        // that sc, or a later `sc attach`, are written into it. The FIFO goes
        // through `cat` because `script` rejects a FIFO as stdin
        // ("tcgetattr/ioctl: Operation not supported on socket") but accepts
        // a pipe. A process substitution rather than a pipeline, so bash
        // waits only for `script`: `cat` never sees EOF and would hold the job
        // open for ever; launchd ends it with the job's process group.
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                "/bin/bash", "-c",
                "exec 3<>\"$1\"; /usr/bin/script -q /dev/null \"$0\" 3>&- < <(exec /bin/cat \"$1\" 3>&-)",
                jobScript.path, inputFIFO.path,
            ],
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

    /// Loaded in launchd with a live process, and no exit recorded yet.
    func isRunning() -> Bool {
        guard exitStatus() == nil else { return false }
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

    /// Remove the finished job from launchd. Its directory stays, for
    /// `sc attach` to replay until `prune` removes it.
    func unload() {
        bootout()
        try? fifoHolder?.close()
        fifoHolder = nil
    }

    /// Stop the job. Booting it out kills its whole process group.
    func stop() {
        unload()
        if exitStatus() == nil {
            try? "130\n".write(to: exitFile, atomically: true, encoding: .utf8)
        }
    }

    private func bootout() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "\(domain)/\(label)"]
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil { process.waitUntilExit() }
    }

    var command: String {
        (try? String(contentsOf: commandFile, encoding: .utf8)) ?? "?"
    }

    /// Every job in `jobsDir`, oldest first (ids start with the time).
    static func all(in jobsDir: URL) -> [LaunchAgentJob] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: jobsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { LaunchAgentJob(workDir: $0) }
    }

    /// Remove all but the newest `keptFinished` jobs that aren't running.
    /// One that never recorded an exit (its Mac restarted under it) counts
    /// as finished.
    static func prune(in jobsDir: URL) {
        let finished = all(in: jobsDir).filter { !$0.isRunning() }
        for job in finished.dropLast(keptFinished) {
            job.bootout()
            try? FileManager.default.removeItem(at: job.workDir)
        }
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
            TTY.write(Data(text.utf8), to: STDOUT_FILENO)
        } else {
            TTY.write(data, to: STDOUT_FILENO)
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
