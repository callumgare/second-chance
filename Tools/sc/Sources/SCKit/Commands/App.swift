import ArgumentParser
import Foundation

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Build or run Second Chance.app.",
        subcommands: [AppBuildCommand.self, AppRunCommand.self, AppScreenshotCommand.self, AppStatesCommand.self]
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

struct AppStatesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "states",
        abstract: "Draw catalogued states of Second Chance's window and a wrapp's loading window, light and dark, for review.",
        discussion: """
        Each app draws the states in its UIStateCatalog (SECOND_CHANCE_UI_STATES) in windows it never shows, \
        so nothing comes on screen and no permission is needed. Writes PNGs and an index.html to look through.
        """
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var appBuild: AppBuildOptions

    @Option(name: .customLong("only"), help: "Only the states whose names start with these, comma-separated (e.g. steam-,error-).")
    var only: String?

    @Option(name: .customLong("out"), help: "Where to write them. Default: DerivedData/ui-states.")
    var out: String?

    func run() async throws {
        let session = try Session.start(global)
        try await GUISession.ensure(session, need: .windows)
        try await Xcode(session: session).ensureAppBuild(appBuild)
        let repo = session.repo
        let folder = out.map { URL(fileURLWithPath: $0, relativeTo: repo.root).standardizedFileURL }
            ?? repo.derivedData.appendingPathComponent("ui-states")
        // Gone first, so an old picture can't pass for a new one.
        try? FileManager.default.removeItem(at: folder)
        let apps = [
            ("Second Chance", repo.appExecutable),
            ("wrapp", repo.app.appendingPathComponent("Contents/Resources/WrappTemplate.app/Contents/MacOS/WrappTemplate")),
        ]
        for (name, executable) in apps {
            var env = ["SECOND_CHANCE_UI_STATES": folder.path, "SECOND_CHANCE_LOG_STDERR": "1"]
            if let only { env["SECOND_CHANCE_UI_STATES_ONLY"] = only }
            try await session.ui.logStep("Draw \(name)'s states", log: "states-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                                         success: "Drew \(name)'s states") { sink in
                try await Proc.stream(executable.path, [], env: env, cwd: repo.root) { await sink.line($0) }
            }
        }
        let pictures = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
        guard !pictures.isEmpty else { throw SCError("Nothing was drawn into \(repo.display(folder)).") }
        let index = folder.appendingPathComponent("index.html")
        try Self.index(of: pictures).write(to: index, atomically: true, encoding: .utf8)
        session.ui.success("\(pictures.count) pictures in \(repo.display(folder)); open \(repo.display(index)) to look through them")
    }

    /// A page showing each state's light and dark pictures side by side,
    /// from names like `wrapp-steam-stuck-light.png`.
    static func index(of pictures: [String]) -> String {
        var states: [String] = []
        for picture in pictures {
            let state = picture.replacingOccurrences(of: #"-(light|dark)\.png$"#, with: "", options: .regularExpression)
            if !states.contains(state) { states.append(state) }
        }
        let rows = states.map { state in
            let images = ["light", "dark"].filter { pictures.contains("\(state)-\($0).png") }
                .map { #"<img src="\#(state)-\#($0).png" alt="\#(state), \#($0)">"# }.joined()
            return "<section><h2>\(state)</h2><div>\(images)</div></section>"
        }.joined(separator: "\n")
        return """
        <!doctype html><meta charset="utf-8"><title>UI states</title>
        <style>
        body { font: 14px -apple-system, sans-serif; margin: 24px; background: #f4f4f4; }
        section { margin-bottom: 32px; } h2 { font-size: 15px; font-family: ui-monospace, monospace; }
        div { display: flex; gap: 16px; flex-wrap: wrap; align-items: flex-start; }
        img { max-width: 48%; width: auto; height: auto; zoom: 0.5; box-shadow: 0 1px 6px rgba(0,0,0,.25); }
        </style>
        \(rows)
        """
    }
}
