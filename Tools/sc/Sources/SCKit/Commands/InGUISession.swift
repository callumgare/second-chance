import ArgumentParser
import Foundation

struct InGUISessionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "in-gui-session",
        abstract: "Run any command in the logged-in user's GUI session.",
        discussion: """
        An SSH shell can't open windows (it lives in launchd's Background \
        session), so Wine fails there. This runs the command in the console \
        user's GUI session under a pty, streams its output back and exits with \
        its status. Combine with --on to do it on a remote Mac. Already in the \
        GUI session, the command just runs.

        Example: sc in-gui-session -- open "built-apps/Nancy Drew - Stay Tuned for Danger.app"
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(parsing: .postTerminator, help: "The command to run, after --.")
    var command: [String] = []

    func validate() throws {
        if command.isEmpty { throw ValidationError("Give the command to run after --.") }
    }

    func run() async throws {
        let session = try Session.start(global)
        try await GUISession.checkLock(session, need: .windows)
        let status = try await GUISession.run(command: command, session: session)
        throw ExitCode(status)
    }
}
