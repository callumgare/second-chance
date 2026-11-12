//
//  ExternalTool.swift
//  ProgramImages
//
//  The programs that unpack what isn't worth reading natively — 7-Zip for
//  cabinets, NSIS and disk images, innoextract, unshield, unar, deark,
//  ffmpeg, upx — run on untrusted input, so each runs:
//
//  - under sandbox-exec, with a profile that lets it read its own files,
//    the system's libraries and its input, write only a fresh folder, and
//    nothing else: no network, no other programs;
//  - through `/bin/sh` setting `ulimit` caps on file size and CPU time, so
//    a bomb can't fill the disk;
//  - in a process group of its own, killed whole when it overruns its time;
//  - with what it wrote checked afterwards: links (symbolic or hard) and
//    anything but plain files and folders are deleted, permissions reset.
//
//  A tool that isn't installed isn't an error: the crawl says it skipped
//  what needed it.

import Darwin
import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.ProgramImages")

nonisolated public struct ExternalTool: Sendable, Hashable {
    public let name: String
    /// Where it is, symbolic links resolved: the sandbox allows exactly this.
    public let executable: URL

    public static let knownTools = ["7zz", "innoextract", "unshield", "unar", "deark", "ffmpeg", "upx"]

    /// Where tools are looked for: PATH, then Homebrew's folders.
    public static func find(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> ExternalTool? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in path + ["/opt/homebrew/bin", "/usr/local/bin"] where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                guard let resolved = realpath(candidate.path, nil) else { continue }
                defer { free(resolved) }
                return ExternalTool(name: name, executable: URL(fileURLWithPath: String(cString: resolved)))
            }
        }
        return nil
    }

    /// The tools found, by name.
    public static func findAll() -> [String: ExternalTool] {
        Dictionary(uniqueKeysWithValues: knownTools.compactMap { name in find(name).map { (name, $0) } })
    }
}

nonisolated public struct ToolRun: Sendable {
    public let status: Int32
    public let timedOut: Bool
    /// Stopped because the crawl was cancelled.
    public let cancelled: Bool
    /// The end of what it wrote to stderr (and stdout), for the log.
    public let messages: String
    /// Bytes it left in its output folder, after the checks.
    public let bytesWritten: Int
    public var succeeded: Bool { status == 0 && !timedOut && !cancelled }
}

nonisolated enum SandboxedRunner {
    /// Run `tool` with `arguments`, able to read `readable` and write only
    /// `output` (which must exist and be empty), for at most `timeout`
    /// seconds, no file it writes larger than `maxFileBytes`. Stopped as
    /// soon as `isCancelled` says so, within a quarter of a second.
    static func run(_ tool: ExternalTool, arguments: [String], readable: [URL], output: URL,
                    timeout: TimeInterval, maxFileBytes: Int, isCancelled: () -> Bool = { false }) -> ToolRun {
        let scratch = output.appendingPathComponent(".sandbox-tmp")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let log = output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)

        let profile = sandboxProfile(tool: tool, readable: readable, writable: output, log: log)
        // ulimit -f counts 512-byte blocks; -t CPU seconds.
        let blocks = max(1, maxFileBytes / 512)
        let cpuSeconds = max(10, Int(timeout * 2))
        let script = "ulimit -f \(blocks); ulimit -t \(cpuSeconds); exec \"$0\" \"$@\""
        let argv = ["/usr/bin/sandbox-exec", "-p", profile, "/bin/sh", "-c", script, tool.executable.path] + arguments
        let environment = [
            "PATH=/usr/bin:/bin",
            "HOME=\(scratch.path)",
            "TMPDIR=\(scratch.path)/",
            "LANG=en_US.UTF-8",
            "LC_ALL=en_US.UTF-8",
        ]

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A process group of its own, to kill whole.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_APPEND, 0o644)
        posix_spawn_file_actions_addopen(&actions, 2, log.path, O_WRONLY | O_APPEND, 0o644)

        var pid: pid_t = 0
        let argvPointers = argv.map { strdup($0) } + [nil]
        let environmentPointers = environment.map { strdup($0) } + [nil]
        defer { (argvPointers + environmentPointers).forEach { free($0) } }
        let spawned = posix_spawn(&pid, argv[0], &actions, &attributes, argvPointers, environmentPointers)
        guard spawned == 0 else {
            logger.error("Couldn't start \(tool.name): \(String(cString: strerror(spawned)))")
            return ToolRun(status: -1, timedOut: false, cancelled: false, messages: "couldn't start", bytesWritten: 0)
        }

        // Its exit, or the time running out, whichever first.
        let exited = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { exited.signal() }
        source.resume()
        // It may have exited before the source was watching.
        var status: Int32 = 0
        var reaped = waitpid(pid, &status, WNOHANG) == pid
        var timedOut = false
        var cancelled = false
        if !reaped {
            let deadline = DispatchTime.now() + timeout
            while exited.wait(timeout: min(deadline, .now() + 0.25)) == .timedOut {
                if isCancelled() {
                    cancelled = true
                    logger.notice("\(tool.name) stopped: the crawl was cancelled")
                } else if DispatchTime.now() >= deadline {
                    timedOut = true
                    logger.warning("\(tool.name) ran past \(Int(timeout)) s; stopping it")
                } else {
                    continue
                }
                kill(-pid, SIGKILL)
                break
            }
            reaped = waitpid(pid, &status, 0) == pid
        }
        source.cancel()
        // Anything it left running in its group goes too.
        kill(-pid, SIGKILL)

        let exitStatus: Int32 = reaped ? ((status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)) : -1
        try? FileManager.default.removeItem(at: scratch)
        let written = sanitise(output)
        let messages = (try? String(contentsOf: log, encoding: .utf8)).map { String($0.suffix(2000)) } ?? ""
        try? FileManager.default.removeItem(at: log)
        return ToolRun(status: exitStatus, timedOut: timedOut, cancelled: cancelled, messages: messages, bytesWritten: written)
    }

    /// Deny everything, then allow: running the shell and the tool, reading
    /// the system's libraries, Homebrew's (where the tools' own live), the
    /// inputs, and reading and writing the output folder.
    static func sandboxProfile(tool: ExternalTool, readable: [URL], writable: URL, log: URL) -> String {
        func quoted(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // realpath, not resolvingSymlinksInPath, which drops /private and
        // so names a path the sandbox (which sees /private/var) never matches.
        let real = { (url: URL) -> String in
            guard let resolved = realpath(url.path, nil) else { return url.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let reads = readable.map { "(subpath \(quoted(real($0))))" }.joined(separator: " ")
        let toolRoot = tool.executable.deletingLastPathComponent().deletingLastPathComponent().path
        return """
        (version 1)
        (deny default)
        (allow process-fork)
        (allow process-exec (literal "/bin/sh") (literal "/bin/bash") (literal \(quoted(tool.executable.path))))
        (allow file-read-metadata)
        (allow file-read* (literal "/"))
        (allow file-read* (subpath "/usr/lib") (subpath "/usr/share") (subpath "/System") (subpath "/Library/Apple")
               (subpath "/private/var/db/dyld") (subpath "/private/var/db/timezone") (literal "/private/etc/localtime")
               (subpath "/opt/homebrew") (subpath "/usr/local") (subpath \(quoted(toolRoot)))
               (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random") (literal "/dev/dtracehelper")
               (literal "/bin/sh") (literal "/bin/bash") \(reads))
        (allow file-read* file-write* (subpath \(quoted(real(writable)))))
        (allow file-write* (literal "/dev/null") (literal "/dev/dtracehelper") (literal \(quoted(real(log)))))
        (allow sysctl-read)
        (deny network*)
        """
    }

    /// Delete links and anything that isn't a plain file or folder, reset
    /// permissions, and say how many bytes are left.
    static func sanitise(_ root: URL) -> Int {
        var total = 0
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else {
            return 0
        }
        for case let url as URL in walker {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFDIR {
                chmod(url.path, 0o755)
            } else if type == S_IFREG, info.st_nlink == 1 {
                chmod(url.path, 0o644)
                total += Int(info.st_size)
            } else {
                // A link (which could point anywhere), a second name for a
                // file, a device or a pipe.
                logger.notice("Removed \(type == S_IFLNK ? "a link" : "a special file") a tool wrote: \(url.lastPathComponent)")
                unlink(url.path)
            }
        }
        return total
    }
}
