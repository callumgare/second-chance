import ArgumentParser
import Foundation

/// The `sc` executable's entry point.
public enum Entry {
    public static func main() async -> Never {
        let (remote, arguments) = Remote.extractTarget(from: Array(CommandLine.arguments.dropFirst()))
        Invocation.arguments = arguments

        do {
            if let remote {
                // Validate here, so a typo fails before anything is synced.
                _ = try SC.parseAsRoot(arguments)
                let status = try await Interrupts.run { try await Remote.run(on: remote, arguments: arguments) }
                finish(status)
            }
            var command = try SC.parseAsRoot(arguments)
            if let asyncCommand = command as? AsyncParsableCommand {
                let box = CommandBox(command: asyncCommand)
                try await Interrupts.run { try await box.run() }
            } else {
                try command.run()
            }
            finish(0)
        } catch let error as SCError {
            if !error.alreadyReported { report(error) }
            finish(error.exitCode)
        } catch is CancellationError {
            if let ui = Session.active?.ui { ui.line(ui.format("\(.accent("Stopped."))")) } else { TTY.write("Stopped.\n") }
            finish(130)
        } catch let error as ExitCode {
            finish(error.rawValue)
        } catch {
            TTY.restoreForExit()
            SC.exit(withError: error)
        }
    }

    private static func report(_ error: SCError) {
        if let ui = Session.active?.ui {
            ui.error(error)
        } else {
            TTY.write("Error: \(error.description)\n")
        }
    }

    private static func finish(_ status: Int32) -> Never {
        TTY.restoreForExit()
        fflush(stdout)
        exit(status)
    }
}

/// Ctrl-C (and SIGTERM/SIGHUP): the first one cancels the running command,
/// which tears down its children (SIGINT → SIGTERM → SIGKILL), removes temp
/// files and LaunchAgents, and puts the terminal back. A second one exits
/// straight away.
enum Interrupts {
    static func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await body() }
        let sources = [SIGINT, SIGTERM, SIGHUP].map { sig -> DispatchSourceSignal in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                if Counter.increment() == 1 {
                    // Through the UI, so a live region is erased and redrawn
                    // below the message rather than torn.
                    let message = "Stopping — letting running tools clean up (Ctrl-C again to quit immediately)…"
                    if let ui = Session.active?.ui {
                        ui.line(ui.format("\(.accent(message))"))
                    } else {
                        TTY.write("\n\(message)\n")
                    }
                    task.cancel()
                } else {
                    TTY.restoreForExit()
                    exit(130)
                }
            }
            source.resume()
            return source
        }
        defer { sources.forEach { $0.cancel() } }
        return try await task.value
    }

    private enum Counter {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var count = 0
        static func increment() -> Int { lock.withLock { count += 1; return count } }
    }
}

/// Carries the parsed command into the interruptible task. Commands are
/// plain value types holding parsed arguments; only the task touches it.
private final class CommandBox: @unchecked Sendable {
    var command: AsyncParsableCommand
    init(command: AsyncParsableCommand) { self.command = command }
    func run() async throws { try await command.run() }
}
