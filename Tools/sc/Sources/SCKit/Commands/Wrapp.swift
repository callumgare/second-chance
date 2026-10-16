import ArgumentParser
import Foundation
import GameCatalog

struct WrappCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wrapp",
        abstract: "Build, update, run or poke at a game's wrapp.",
        discussion: "A wrapp is the .app Second Chance produces: one game plus the engine to run it.",
        subcommands: [WrappBuildCommand.self, WrappUpdateCommand.self, WrappRunCommand.self, WrappWineCommand.self]
    )
}

struct WrappBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build a game's wrapp headlessly, replacing any existing one.",
        discussion: """
        Prints the wrapp's path on stdout. In an interactive terminal, press l \
        during the build to launch the wrapp when it finishes.
        """
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var appBuild: AppBuildOptions
    @OptionGroup var source: WrappSourceOptions
    @OptionGroup var debug: WrappBuildDebugOptions
    @OptionGroup var wrapps: WrappsDirOptions

    @Argument(help: "The game's slug, e.g. haunted-carousel. Asked for when omitted in a terminal.")
    var game: String?

    func run() async throws {
        let session = try Session.start(global)
        try await GUISession.ensure(session, need: .windows)
        let game = try Games.resolve(
            game, candidates: source.input.availableGames(repo: session.repo),
            candidateKind: source.input.availabilityDescription, command: "wrapp build", ui: session.ui
        )
        try await Xcode(session: session).ensureAppBuild(appBuild)
        let builder = WrappBuilder(session: session)
        let toggle = LaunchToggle(initiallyOn: false, note: "default options", ui: session.ui)
        let wrapp = try await builder.build(
            game, source: source, debug: try debug.effect(), wrappsDir: wrapps.resolve(session.repo), toggle: toggle
        )
        session.ui.result(wrapp.path)
        if toggle.isOn {
            builder.launch(wrapp, debug: DebugEffect(), arguments: [])
        }
        session.ui.success("Built \(game.wrappName)", takeaways: ["Run it with: sc wrapp run \(game.slug)"])
    }
}

struct WrappUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Put the app build's WrappTemplate into an existing wrapp, without reinstalling the game.",
        discussion: "The fast loop for WrappTemplate changes. Prints the wrapp's path on stdout."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var appBuild: AppBuildOptions
    @OptionGroup var wrapps: WrappsDirOptions

    @Argument(help: "The game's slug. Asked for when omitted in a terminal.")
    var game: String?

    func run() async throws {
        let session = try Session.start(global)
        let wrappsDir = wrapps.resolve(session.repo)
        let game = try Games.resolve(
            game, candidates: Games.withWrapps(in: wrappsDir, repo: session.repo),
            candidateKind: "a wrapp", command: "wrapp update", ui: session.ui
        )
        let builder = WrappBuilder(session: session)
        let wrapp = try builder.existingWrapp(game, in: wrappsDir)
        try await Xcode(session: session).ensureAppBuild(appBuild)
        try await builder.updateTemplate(of: wrapp)
        session.ui.result(wrapp.path)
    }
}

struct WrappRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Launch a game's wrapp with its logs in this terminal.",
        discussion: """
        Uses the existing wrapp; builds one first only if there is none. \
        --refresh-wrapp template puts the latest WrappTemplate into it first, and \
        full rebuilds it. While a build runs in a terminal, press l to change \
        your mind about launching. Arguments after -- go to the wrapp.
        """
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var appBuild: AppBuildOptions

    @Option(help: "How to bring the wrapp up to date first: skip, template or full.")
    var refreshWrapp: WrappRefresh = .skip

    @OptionGroup var debug: WrappDebugOptions
    @OptionGroup(title: "When a build is needed") var source: WrappSourceOptions
    @OptionGroup var wrapps: WrappsDirOptions

    @Argument(help: "The game's slug. Asked for when omitted in a terminal.")
    var game: String?

    @Argument(parsing: .postTerminator, help: "Arguments for the wrapp.")
    var wrappArguments: [String] = []

    func run() async throws {
        let session = try Session.start(global)
        try await GUISession.ensure(session, need: .windows)
        let repo = session.repo
        let wrappsDir = wrapps.resolve(repo)
        let builder = WrappBuilder(session: session)
        let candidates = refreshWrapp == .full
            ? source.input.availableGames(repo: repo)
            : Games.withWrapps(in: wrappsDir, repo: repo)
        let game = try Games.resolve(
            game, candidates: candidates,
            candidateKind: refreshWrapp == .full ? source.input.availabilityDescription : "a wrapp",
            command: "wrapp run", ui: session.ui
        )
        let effect = try debug.effect()
        let wrapp = repo.wrapp(for: game, in: wrappsDir)
        let exists = FileManager.default.fileExists(atPath: wrapp.appendingPathComponent("Contents/Info.plist").path)

        if refreshWrapp == .template, !exists {
            throw SCError("There's no wrapp for \(game.slug) to update.",
                          hints: ["Build it with --refresh-wrapp full, or drop --refresh-wrapp."])
        }

        // Only the refreshing paths need the app; launching an existing wrapp as-is doesn't.
        if refreshWrapp == .full || !exists {
            try await Xcode(session: session).ensureAppBuild(appBuild)
            let toggle = LaunchToggle(initiallyOn: true, note: "", ui: session.ui)
            _ = try await builder.build(game, source: source, debug: DebugEffect(), wrappsDir: wrappsDir, toggle: toggle)
            guard toggle.isOn else {
                session.ui.success("Built \(game.wrappName) (not launching)")
                return
            }
        } else if refreshWrapp == .template {
            try await Xcode(session: session).ensureAppBuild(appBuild)
            try await builder.updateTemplate(of: wrapp)
        }
        builder.launch(wrapp, debug: effect, arguments: wrappArguments)
    }
}

struct WrappWineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wine",
        abstract: "Run Wine inside a wrapp's prefix.",
        discussion: """
        Everything after -- goes to the wrapp's bundled Wine, e.g. \
        `sc wrapp wine stay-tuned -- regedit` or `-- cmd`.
        """
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var wrapps: WrappsDirOptions

    @Argument(help: "The game's slug. Asked for when omitted in a terminal.")
    var game: String?

    @Argument(parsing: .postTerminator, help: "Arguments for wine.")
    var wineArguments: [String] = []

    func run() async throws {
        let session = try Session.start(global)
        try await GUISession.ensure(session, need: .windows)
        let wrappsDir = wrapps.resolve(session.repo)
        let game = try Games.resolve(
            game, candidates: Games.withWrapps(in: wrappsDir, repo: session.repo),
            candidateKind: "a wrapp", command: "wrapp wine", ui: session.ui
        )
        let wrapp = try WrappBuilder(session: session).existingWrapp(game, in: wrappsDir)
        Proc.exec(wrapp.appendingPathComponent("Contents/MacOS/WrappTemplate").path, ["wine"] + wineArguments)
    }
}
