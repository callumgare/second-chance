import ArgumentParser
import Foundation

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Build or run Second Chance.app.",
        subcommands: [AppBuildCommand.self, AppRunCommand.self]
    )
}

struct AppBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build Second Chance.app (Debug) into DerivedData.",
        discussion: "Prints the app's path on stdout."
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let session = try Session.start(global)
        try await Xcode(session: session).buildApp()
        session.ui.result(session.repo.app.path)
    }
}

struct AppRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build Second Chance.app if needed, then run it with its logs in this terminal.",
        discussion: "Arguments after -- are passed to the app."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var appBuild: AppBuildOptions
    @OptionGroup var debug: AppDebugOptions

    @Argument(parsing: .postTerminator, help: "Arguments for the app.")
    var appArguments: [String] = []

    func run() async throws {
        let session = try Session.start(global)
        try await GUISession.ensure(session, need: .windows)
        try await Xcode(session: session).ensureAppBuild(appBuild)
        let effect = try debug.effect()
        session.ui.line(session.ui.format("\(.primary("▸ Running Second Chance"))"))
        // exec, so the app owns the terminal: its logs stream here from the
        // first line and Ctrl-C goes straight to it.
        Proc.exec(session.repo.appExecutable.path, effect.arguments + appArguments, env: effect.environment)
    }
}
