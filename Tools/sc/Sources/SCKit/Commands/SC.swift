import ArgumentParser

/// The root command. Nouns first, then verbs: the two things you build and
/// run (`app`, `wrapp`), then single-purpose commands.
public struct SC: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sc",
        abstract: "Build, run, test and release Second Chance.",
        discussion: """
        Commands that need the app build it first (incrementally); --skip-app-build \
        uses the existing build instead. Over SSH, commands that open windows re-run \
        themselves in the logged-in user's GUI session. See docs/dev-cli.md.
        """,
        subcommands: [
            AppCommand.self,
            WrappCommand.self,
            TestCommand.self,
            ReleaseCommand.self,
            SetupCommand.self,
            CleanCommand.self,
            InGUISessionCommand.self,
            AttachCommand.self,
        ]
    )

    public init() {}
}
