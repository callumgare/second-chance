import ArgumentParser
import Foundation

struct AttachCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Follow a GUI-session run again after losing its connection.",
        discussion: """
        A command that re-ran itself in the GUI session (over SSH, or with --on) \
        keeps running when the connection drops. This replays its output from \
        the start, follows it until it finishes and exits with its status; \
        Ctrl-C stops it. A run that has already finished just replays. \
        Usually: sc --on <host>[:<path>] attach.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Flag(help: "List the runs: running, and the last few finished.")
    var list = false

    @Flag(help: "Stop the run instead of following it.")
    var stop = false

    @Argument(help: "The run's id (or the start of it), from --list. Default: the one still running, else the newest.")
    var id: String?

    func validate() throws {
        if list && (stop || id != nil) { throw ValidationError("--list takes no id and can't be combined with --stop.") }
    }

    func run() async throws {
        let session = try Session.start(global)
        let jobs = LaunchAgentJob.all(in: session.repo.scJobs)
        if list {
            if jobs.isEmpty { session.ui.detail("No runs.") }
            for job in jobs {
                let state = job.isRunning() ? "running" : job.exitStatus().map { "exited \($0)" } ?? "ended"
                session.ui.line("\(job.id)  \(state)  \(job.command)")
            }
            return
        }
        let job = try Self.pick(id, from: jobs)
        if stop {
            guard job.isRunning() else { throw SCError("Run \(job.id) has already finished.") }
            job.stop()
            session.ui.line("Stopped run \(job.id).")
            return
        }
        let status = try await GUISession.follow(job, session: session)
        throw ExitCode(status)
    }

    /// The job `id` names. With none, the one still running, or — when the
    /// run finished while nobody was following it — the newest.
    static func pick(_ id: String?, from jobs: [LaunchAgentJob]) throws -> LaunchAgentJob {
        if let id {
            let matches = jobs.filter { $0.id.hasPrefix(id) }
            guard let job = matches.first, matches.count == 1 else {
                throw SCError(matches.isEmpty ? "No run '\(id)'." : "'\(id)' matches more than one run.",
                              hints: ["See them with: sc attach --list"])
            }
            return job
        }
        let running = jobs.filter { $0.isRunning() }
        if running.count > 1 {
            throw SCError("More than one run is going: \(running.map(\.id).joined(separator: ", ")).",
                          hints: ["Name one: sc attach <id>"])
        }
        guard let job = running.first ?? jobs.last else { throw SCError("There are no runs to attach to.") }
        return job
    }
}
