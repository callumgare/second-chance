import ArgumentParser
import Foundation
import WrappBuilder

/// A Mac's whole screen, or a test session's, through Peekaboo there: what
/// no game window shows (a system prompt, an installer, the Finder).
struct SessionScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Picture a Mac's whole screen, or a test session's, through Peekaboo, and bring it back here.",
        discussion: """
        Takes it with that user's Peekaboo (`session setup` gives a test \
        session its grants), shrinks it to --max pixels across, and saves it here. \
        With --on, of that Mac; without, of this one. No user: the Mac's own \
        logged-in user's screen.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "A test user whose session to picture. Default: the user sc logs in as.")
    var user: String?

    @Option(help: ArgumentHelp("Where to save it here.", valueName: "png")) var out: String?
    @Option(help: "Its longest side, in pixels (cheap to look at).") var max: Int = 1600

    func run() async throws {
        let session = try Session.start(global)
        let mac = Invocation.remote.map { Remote.parse($0, localRoot: session.repo.root).host }
        let host = mac ?? ScreenLease.shortHostName()
        let name = user.map { "\(host)/\($0)" } ?? host
        let destination = user.map { "\($0)@\(mac ?? "localhost")" } ?? mac
        let remote = "/tmp/sc-screen-\(UUID().uuidString).png"
        let output = URL(fileURLWithPath: out ?? "screen-\(name.replacingOccurrences(of: "/", with: "-")).png")
        let command = "cli=; for c in /opt/homebrew/bin/peekaboo /usr/local/bin/peekaboo \(PeekabooSetup.sharedCLI); "
            + "do [ -x $c ] && cli=$c && break; done; [ -n \"$cli\" ] || { echo 'Peekaboo is not installed' >&2; exit 3; }; "
            + "PEEKABOO_BRIDGE_SOCKET=\"$HOME/Library/Application Support/Peekaboo/bridge.sock\" $cli see --mode screen --no-elements "
            + "--path \(remote) >/dev/null && sips -Z \(max) \(remote) >/dev/null"
        try await session.ui.progressStep("Picturing \(name)'s screen with Peekaboo", success: "Saved \(name)'s screen to \(output.path)") { _ in
            let shell = destination.map { ["/usr/bin/ssh", "-o", "BatchMode=yes", $0, "bash -c \(Remote.quote(command))"] }
                ?? ["/bin/bash", "-c", command]
            let taken = try await Proc.collect(shell[0], Array(shell.dropFirst()))
            guard taken.succeeded else {
                throw SCError("Peekaboo couldn't picture \(name)'s screen: \(taken.error.trimmingCharacters(in: .whitespacesAndNewlines))",
                              hints: ["Give it Peekaboo and its grants: sc session setup --task peekaboo" + (user.map { " \($0)" } ?? "")
                                      + (mac.map { " --on \($0)" } ?? ""),
                                      "Is someone logged in there, and is the screen unlocked? sc" + (mac.map { " --on \($0)" } ?? "") + " session list"])
            }
            if let destination {
                let copied = try await Proc.collect("/usr/bin/scp", ["-q", "-o", "BatchMode=yes", "\(destination):\(remote)", output.path])
                _ = try? await Proc.collect("/usr/bin/ssh", ["-o", "BatchMode=yes", destination, "rm -f \(remote)"])
                guard copied.succeeded else { throw SCError("Couldn't copy the picture back: \(copied.error)") }
            } else {
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: URL(fileURLWithPath: remote), to: output)
            }
        }
    }
}
