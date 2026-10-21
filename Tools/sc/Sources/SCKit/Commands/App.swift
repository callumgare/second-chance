import ArgumentParser
import Foundation

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Build or run Second Chance.app.",
        subcommands: [AppBuildCommand.self, AppRunCommand.self, AppScreenshotCommand.self]
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

struct AppScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Take the README's screenshots of Second Chance's window, light and dark, into docs/.",
        discussion: "The app captures its own window (SECOND_CHANCE_SCREENSHOT), so this needs no Screen Recording permission."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var appBuild: AppBuildOptions

    func run() async throws {
        let session = try Session.start(global)
        try await GUISession.ensure(session, need: .windows)
        try await Xcode(session: session).ensureAppBuild(appBuild)
        let repo = session.repo
        for appearance in ["light", "dark"] {
            let file = repo.root.appendingPathComponent("docs/main-screen-\(appearance).png")
            // Gone first, so an old screenshot can't pass for a new one.
            try? FileManager.default.removeItem(at: file)
            try await session.ui.logStep(
                "Screenshot (\(appearance))", log: "screenshot-\(appearance)", success: "Wrote \(repo.display(file))"
            ) { sink in
                try await Proc.stream(repo.appExecutable.path, [], env: [
                    "SECOND_CHANCE_SCREENSHOT": file.path,
                    "SECOND_CHANCE_SCREENSHOT_APPEARANCE": appearance,
                    "SECOND_CHANCE_LOG_STDERR": "1",
                ], cwd: repo.root) { await sink.line($0) }
            }
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw SCError("Second Chance quit without writing \(repo.display(file)).")
            }
        }
    }
}
