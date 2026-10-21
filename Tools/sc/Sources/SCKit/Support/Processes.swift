import Foundation
import Subprocess
#if canImport(System)
import System
#else
import SystemPackage
#endif

/// Running other programs. Everything goes through here so every child gets
/// the same teardown on Ctrl-C (SIGINT, then SIGTERM, then SIGKILL) and every
/// exit status is reported the same way (128 + signal for a signalled child,
/// as shells do).
enum Proc {
    struct Collected: Sendable {
        let status: Int32
        let output: String
        let error: String
        var succeeded: Bool { status == 0 }
    }

    static func executable(_ nameOrPath: String) -> Executable {
        nameOrPath.contains("/") ? .path(FilePath(nameOrPath)) : .name(nameOrPath)
    }

    static func environment(_ overrides: [String: String?]) -> Subprocess.Environment {
        var keyed: [Subprocess.Environment.Key: String?] = [:]
        for (key, value) in overrides {
            if let k = Subprocess.Environment.Key(rawValue: key) { keyed[k] = value }
        }
        return .inherit.updating(keyed)
    }

    static var platformOptions: PlatformOptions {
        var options = PlatformOptions()
        options.teardownSequence = [
            .send(signal: .interrupt, allowedDurationToNextStep: .seconds(3)),
            .gracefulShutDown(allowedDurationToNextStep: .seconds(3)),
        ]
        return options
    }

    /// `platformOptions`, with the child its own "responsible process": macOS
    /// asks about privacy access (microphone, local network…) on behalf of the
    /// responsible process, which for anything sc starts is sc — a bare
    /// command-line tool, so macOS prompts, and Steam inside a build waits on
    /// those prompts. Started like this, the Second Chance app answers for
    /// itself, as an app bundle with no usage descriptions, which macOS
    /// quietly declines. `responsibility_spawnattrs_setdisclaim` is private
    /// API, looked up at run time; without it the child is started as before.
    static var disclaimingPlatformOptions: PlatformOptions {
        var options = platformOptions
        options.preSpawnProcessConfigurator = { attributes, _ in
            typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return }
            _ = unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1)
        }
        return options
    }

    static func code(_ status: TerminationStatus) -> Int32 {
        switch status {
        case .exited(let code): return code
        case .signaled(let signal): return 128 + signal
        }
    }

    /// Run to completion and collect stdout and stderr separately.
    static func collect(
        _ exe: String,
        _ args: [String],
        env: [String: String?] = [:],
        cwd: URL? = nil,
        input: String? = nil
    ) async throws -> Collected {
        let limit = 64 * 1024 * 1024
        let result: ExecutionResult<Void, StringOutput<UTF8>, StringOutput<UTF8>>
        if let input {
            result = try await run(
                executable(exe), arguments: Arguments(args), environment: environment(env),
                workingDirectory: cwd.map { FilePath($0.path) }, platformOptions: platformOptions,
                input: .string(input), output: .string(limit: limit), error: .string(limit: limit)
            )
        } else {
            result = try await run(
                executable(exe), arguments: Arguments(args), environment: environment(env),
                workingDirectory: cwd.map { FilePath($0.path) }, platformOptions: platformOptions,
                input: .none, output: .string(limit: limit), error: .string(limit: limit)
            )
        }
        return Collected(
            status: code(result.terminationStatus),
            output: result.standardOutput,
            error: result.standardError
        )
    }

    /// Run with stdout and stderr merged, handing over each line as it
    /// arrives. stdin is `input`, or /dev/null without one, so a child can
    /// never swallow keystrokes meant for sc. Returns the exit status.
    static func stream(
        _ exe: String,
        _ args: [String],
        env: [String: String?] = [:],
        cwd: URL? = nil,
        input: String? = nil,
        disclaimResponsibility: Bool = false,
        onLine: @escaping @Sendable (String) async -> Void
    ) async throws -> Int32 {
        let options = disclaimResponsibility ? disclaimingPlatformOptions : platformOptions
        let read = { (lines: SubprocessOutputSequence) async throws in
            for try await line in lines.strings(bufferingPolicy: .unbounded) {
                await onLine(line)
            }
        }
        let status: TerminationStatus
        if let input {
            status = try await run(
                executable(exe), arguments: Arguments(args), environment: environment(env),
                workingDirectory: cwd.map { FilePath($0.path) }, platformOptions: options,
                input: .string(input), output: .sequence, error: .combinedWithOutput
            ) { try await read($0.standardOutput) }.terminationStatus
        } else {
            status = try await run(
                executable(exe), arguments: Arguments(args), environment: environment(env),
                workingDirectory: cwd.map { FilePath($0.path) }, platformOptions: options,
                input: .none, output: .sequence, error: .combinedWithOutput
            ) { try await read($0.standardOutput) }.terminationStatus
        }
        return code(status)
    }

    /// Run with the terminal handed straight through (stdin, stdout and
    /// stderr inherited) and wait for it. For children that talk to the user
    /// themselves, like `ssh -t` or `open`.
    static func inheritingTerminal(
        _ exe: String,
        _ args: [String],
        env: [String: String?] = [:],
        cwd: URL? = nil
    ) async throws -> Int32 {
        let result = try await run(
            executable(exe), arguments: Arguments(args), environment: environment(env),
            workingDirectory: cwd.map { FilePath($0.path) }, platformOptions: platformOptions,
            input: .currentStandardInput, output: .currentStandardOutput, error: .currentStandardError
        )
        return code(result.terminationStatus)
    }

    /// Replace this process with another, keeping the terminal. Used to run
    /// the app or a wrapp, so it owns the TTY and gets Ctrl-C directly — sc
    /// has nothing left to do afterwards.
    static func exec(_ path: String, _ args: [String], env: [String: String?] = [:]) -> Never {
        TTY.restoreForExit()
        // Handlers reset to default across exec, but an *ignored* signal stays
        // ignored — and sc ignores SIGINT to handle it through a dispatch
        // source. Put everything back so the new program behaves normally.
        // A blocked signal also stays blocked across exec.
        var unblock = sigset_t()
        sigemptyset(&unblock)
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGWINCH, SIGPIPE] {
            signal(sig, SIG_DFL)
            sigaddset(&unblock, sig)
        }
        pthread_sigmask(SIG_UNBLOCK, &unblock, nil)
        for (key, value) in env {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        fflush(stdout)
        fflush(stderr)
        let argv = ([path] + args).map { strdup($0) } + [nil]
        execv(path, argv)
        let reason = String(cString: strerror(errno))
        TTY.write(Data("sc: couldn't run \(path): \(reason)\n".utf8), to: STDERR_FILENO)
        exit(127)
    }

    /// The full path of a program on `PATH`, or nil.
    static func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Fail with an install hint when a required tool is missing.
    static func require(_ name: String, brew formula: String) throws {
        guard which(name) != nil else {
            throw SCError("'\(name)' isn't installed.", hints: ["Install it with: brew install \(formula)"])
        }
    }
}
