//
//  ShellStep.swift
//  WrappBuilder
//
//  A RUN whose program no module runs: a shell command, run on this Mac in
//  a sandbox that keeps it to the step's tree.

import Foundation
import Logging
import ProcessKit

/// `RUN <command>` where no module's program type takes the command's first
/// word: `/bin/sh -c <command>` in the step's tree (its `Contents/`), with
/// a bare environment and the step's `--env`s, under `sandbox-exec`. It may
/// write only in the tree, its stores' folders and a temporary folder of its
/// own; read only those and the system's own files; and use no network. A
/// bundle's own steps stay inside its build, whatever they run.
nonisolated enum ShellStep {
    static let shell = "/bin/sh"
    static let sandboxExec = "/usr/bin/sandbox-exec"
    /// What every command finds, and nothing of the person's.
    static let path = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The sandbox: nothing but what's allowed, the system's base rules
    /// (`system.sb`) for what any program needs to start.
    static let profile = """
        (version 1)
        (deny default)
        (import "system.sb")
        (allow process-fork process-exec)
        (allow signal (target same-sandbox))
        (allow sysctl-read)
        (allow file-read-metadata)
        (allow file-read*
          (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/System")
          (subpath "/Library/Apple") (subpath "/private/etc") (subpath "/private/var/db/timezone")
          (subpath "/private/var/select") (subpath "/dev"))
        (allow file-write-data
          (literal "/dev/null") (literal "/dev/tty") (literal "/dev/stdout") (literal "/dev/stderr") (regex #"^/dev/fd/"))
        """

    /// The profile with read and write for each folder the step may change.
    static func profile(writable folders: [String]) -> String {
        let quoted = folders.map { "(subpath \"\(escaped($0))\")" }.joined(separator: " ")
        return profile + "\n(allow file-read* file-write* \(quoted))\n"
    }

    /// A path in a profile's string: `\` and `"` escaped.
    static func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// A path with every link followed, as the sandbox matches it
    /// (`/tmp` is `/private/tmp`), which Foundation's
    /// `resolvingSymlinksInPath` isn't: it drops `/private`.
    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The step's environment: the bare minimum, then its `--env`s.
    static func environment(_ step: PlannedStep, temporary: URL) -> [String: String] {
        var environment = ["PATH": path, "HOME": temporary.path, "TMPDIR": temporary.path + "/", "LANG": "en_US.UTF-8"]
        for pair in step.options["env"] ?? [] {
            let parts = pair.split(separator: "=", maxSplits: 1)
            environment[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        return environment
    }

    static func run(_ step: PlannedStep, in context: LocalStepContext) async throws {
        guard step.arguments.count == 1, let command = step.arguments.first, !command.isEmpty else {
            throw StepFailure.recipe("\(step.origin): RUN --shell takes its command as one argument")
        }
        let contents = context.tree.appendingPathComponent("Contents")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString)")
        try await Blocking.run {
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        }
        defer {
            do {
                try FileManager.default.removeItem(at: temporary)
            } catch {
                context.log.warning("Couldn't remove the shell step's temporary folder: \(error.localizedDescription)")
            }
        }
        // A store mount is a link out of the tree, to the store's folder.
        var writable = [realPath(context.tree), realPath(temporary)]
        for mount in step.options["mount"] ?? [] {
            let fields = PlannedStep.fields(ofMount: mount)
            guard fields["type"] == "store", let target = fields["target"], let link = context.location(of: target) else { continue }
            writable.append(realPath(link))
        }
        context.log.notice("Running a shell command in a sandbox: \(command)")
        let code = try await run(command, in: contents, environment: environment(step, temporary: temporary),
                                 profile: profile(writable: writable), context: context)
        context.programExited(code)
        guard code == 0 else { throw StepFailure.failed("\(step.origin): the shell command exited with \(code)") }
    }

    /// Runs the command and answers its exit code once it exits.
    static func run(_ command: String, in folder: URL, environment: [String: String], profile: String,
                    context: LocalStepContext) async throws -> Int32 {
        let process = TaggedProcess(logger: context.log)
        process.executableURL = URL(fileURLWithPath: sandboxExec)
        process.arguments = ["-p", profile, shell, "-c", command]
        process.environment = environment
        process.currentDirectoryURL = folder
        process.process.standardInput = FileHandle.nullDevice
        process.onLine = { line in context.programWrote(line) }
        let exited = OneTimeSignal()
        process.process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // Until it exits, or the build is stopped: then it's stopped too.
        await exited.wait()
        if !exited.isSignalled {
            process.process.terminate()
            if await !exited.wait(timeout: .seconds(10)) { kill(process.processIdentifier, SIGKILL) }
            throw CancellationError()
        }
        return process.process.terminationStatus
    }
}
