import ArgumentParser
import Foundation

/// Everything a test session needs beyond its login, done or put right:
/// the console user's signing certificate in its keychain, and Peekaboo with
/// its grants. `session add` runs it last.
struct SessionSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set test sessions up: your signing certificate, and Peekaboo with its grants (or only those named).",
        discussion: """
        Run it on the Mac you're at. With --on it sets up that Mac's test \
        sessions; without, this Mac's. Each task skips what's done already. \
        signing: gives each test user your Apple Development certificate, so \
        its builds are signed as yours are (done on the test Mac, from your \
        keychain there; macOS may ask on its screen to allow the export). \
        peekaboo: installs Peekaboo if missing, starts it in each session, and \
        for a grant it lacks opens that pane there and Screen Sharing here, for \
        you to turn it on.
        """
    )

    enum Task: String, CaseIterable, ExpressibleByArgument {
        case signing, peekaboo
    }

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Test users. Default: every one in that Mac's pool.")
    var users: [String] = []

    @Option(parsing: .upToNextOption, help: "Only these tasks: signing, peekaboo. Default: every one.")
    var only: [Task] = []

    func run() async throws {
        let session = try Session.start(global)
        let tasks = only.isEmpty ? Task.allCases : Task.allCases.filter(only.contains)
        let mac = Invocation.remote.map { Remote.parse($0, localRoot: session.repo.root).host }
        var failed: [String] = []
        if tasks.contains(.signing) {
            if let remote = Invocation.remote {
                // The certificate is in the console user's keychain on that Mac.
                let status = try await Remote.run(on: remote, arguments: ["session", "setup", "--only", "signing"] + users)
                if status != 0 { failed.append("signing") }
            } else {
                await SessionAddCommand.installSigningIdentities(users.isEmpty ? SessionPool.users() : users, session: session)
            }
        }
        if tasks.contains(.peekaboo) {
            do {
                try await PeekabooSetup.run(users: users.isEmpty ? nil : users, on: mac, session: session)
            } catch {
                failed.append("peekaboo")
                session.ui.warning("Peekaboo's set-up stopped: \(error)")
            }
        }
        if !failed.isEmpty {
            throw SCError("Set-up didn't finish: \(failed.joined(separator: ", ")).",
                          hints: ["Run what's left again: sc session setup --only \(failed.joined(separator: " "))" + (mac.map { " --on \($0)" } ?? "")])
        }
    }
}
