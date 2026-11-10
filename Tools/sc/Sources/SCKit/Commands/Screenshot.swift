import ArgumentParser
import Foundation

struct ScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Picture catalogued states of Second Chance's window and a wrapp's loading window, light and dark.",
        discussion: """
        Each app draws the states in its UIStateCatalog. By default in windows it never shows, so nothing comes \\
        on screen and no permission is needed, into DerivedData/screenshots/ with an index.html to look through. \\
        --on-screen shows each in a real window and captures it with its title bar and shadow, as the README's \\
        pictures are: sc screenshot app --on-screen --state welcome --out docs/. --in-session does the same in one \\
        of this Mac's test sessions, off your screen, at the scale of the session's display rather than your monitor's.
        """
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var appBuild: AppBuildOptions

    @Argument(help: "Whose states: app (Second Chance) or wrapp. Both when left out.")
    var target: Screenshots.Target?

    @Option(name: .customLong("state"), parsing: .singleValue,
            help: "Only these states (repeatable, or comma-separated); one ending in * is a prefix, as in 'steam-*'.")
    var states: [String] = []

    @Option(name: .customLong("out"), help: "Where to write them. Default: DerivedData/screenshots, with an index.html.")
    var out: String?

    @Flag(name: .customLong("on-screen"), help: "Show each in a real window and capture it with its title bar and shadow.")
    var onScreen = false

    @Flag(name: .customLong("in-session"), help: ArgumentHelp(
        "Picture them on screen in one of this Mac's test sessions, not on yours.",
        discussion: "The first free one, or --session's. They take the scale of the session's own display (2×), not your monitor's."
    ))
    var inSession = false

    @Option(name: .customLong("session"), help: ArgumentHelp("The test session to use (implies --in-session).", valueName: "user"))
    var sessionUser: String?

    @Flag(name: .customLong("list"), help: "List the catalogued states' names, without picturing any.")
    var list = false

    func run() async throws {
        let session = try Session.start(global)
        if list {
            try await Xcode(session: session).ensureAppBuild(appBuild)
            for target in target.map({ [$0] }) ?? Screenshots.Target.allCases {
                let names = try await Screenshots(session: session, app: session.repo.app).names(of: target)
                session.ui.line(names.map { "\(target.rawValue)  \($0)" }.joined(separator: "\n"))
            }
            return
        }
        let inTestSession = inSession || sessionUser != nil
        // In a test session nothing comes up on this Mac's screen.
        if !inTestSession { try await GUISession.ensure(session, need: .windows) }
        try await Xcode(session: session).ensureAppBuild(appBuild)
        let repo = session.repo
        let folder = out.map { URL(fileURLWithPath: $0, relativeTo: repo.root).standardizedFileURL }
            ?? repo.derivedData.appendingPathComponent("screenshots")
        if out == nil {
            // Gone first, so an old picture can't pass for a new one.
            try? FileManager.default.removeItem(at: folder)
        }
        let screenshots = Screenshots(session: session, app: repo.app)
        let targets = target.map { [$0] } ?? Screenshots.Target.allCases
        let wanted = states.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let pictures = inTestSession
            ? try await screenshots.takeInTestSession(sessionUser, targets: targets, states: wanted, into: folder)
            : try await screenshots.take(targets: targets, states: wanted, onScreen: onScreen, into: folder)
        guard out == nil else {
            session.ui.success("\(pictures.count) pictures in \(repo.display(folder))")
            return
        }
        let index = folder.appendingPathComponent("index.html")
        try Screenshots.index(of: pictures.map(\.lastPathComponent)).write(to: index, atomically: true, encoding: .utf8)
        session.ui.success("\(pictures.count) pictures in \(repo.display(folder))",
                           takeaways: ["Open \(repo.display(index)) to look through them"])
    }
}

/// Pictures of the apps' catalogued UI states (`UIStateShots` in the apps):
/// for `sc screenshot`, and for `sc release` to retake the README's.
struct Screenshots {
    enum Target: String, CaseIterable, ExpressibleByArgument {
        case app, wrapp
    }

    let session: Session
    /// The Second Chance.app to run: the Debug build, or a release's.
    let app: URL

    /// The names of `target`'s catalogued states.
    func names(of target: Target) async throws -> [String] {
        let result = try await Proc.collect(executable(of: target).path, [], env: ["SECOND_CHANCE_UI_STATES_LIST": "1"])
        guard result.succeeded else { throw SCError("Couldn't list \(target.rawValue)'s states.", hints: [result.error]) }
        return result.output.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func executable(of target: Target) -> URL {
        Self.executable(of: target, in: app)
    }

    /// What draws `target`'s states, in the Second Chance.app at `app`.
    static func executable(of target: Target, in app: URL) -> URL {
        switch target {
        case .app: app.appendingPathComponent("Contents/MacOS/Second Chance")
        case .wrapp: app.appendingPathComponent("Contents/Resources/WrappTemplate.app/Contents/MacOS/WrappTemplate")
        }
    }

    /// Have each target draw `states` (all when empty) into `folder`; the
    /// pictures it drew, as `<target>-<state>-<light|dark>.png`.
    func take(targets: [Target], states: [String], onScreen: Bool, into folder: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var drawn: [URL] = []
        for target in targets {
            let executable = executable(of: target)
            var env = ["SECOND_CHANCE_UI_STATES": folder.path, "SECOND_CHANCE_LOG_STDERR": "1"]
            if !states.isEmpty { env["SECOND_CHANCE_UI_STATES_ONLY"] = states.joined(separator: ",") }
            if onScreen { env["SECOND_CHANCE_UI_STATES_ON_SCREEN"] = "1" }
            let start = Date()
            try await session.ui.logStep("Picture \(target.rawValue) states", log: "screenshot-\(target.rawValue)",
                                         success: "Pictured \(target.rawValue) states") { sink in
                try await Proc.stream(executable.path, [], env: env, cwd: session.repo.root) { await sink.line($0) }
            }
            // What this run wrote, not what was in the folder already.
            drawn += Self.pictures(in: folder).filter {
                let written = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return $0.lastPathComponent.hasPrefix("\(target.rawValue)-") && written >= start.addingTimeInterval(-1)
            }
        }
        guard !drawn.isEmpty else { throw SCError("Nothing was pictured into \(session.repo.display(folder)).") }
        return drawn.sorted { $0.path < $1.path }
    }

    static func pictures(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }
    }

    /// A page showing each state's light and dark pictures side by side,
    /// from names like `wrapp-steam-stuck-light.png`.
    static func index(of pictures: [String]) -> String {
        var states: [String] = []
        for picture in pictures.sorted() {
            let state = picture.replacingOccurrences(of: #"-(light|dark)\.png$"#, with: "", options: .regularExpression)
            if !states.contains(state) { states.append(state) }
        }
        let rows = states.map { state in
            let images = ["light", "dark"].filter { pictures.contains("\(state)-\($0).png") }
                .map { #"<img src="\#(state)-\#($0).png" alt="\#(state), \#($0)">"# }.joined()
            return "<section><h2>\(state)</h2><div>\(images)</div></section>"
        }.joined(separator: "\n")
        return """
        <!doctype html><meta charset="utf-8"><title>Screenshots</title>
        <style>
        body { font: 14px -apple-system, sans-serif; margin: 24px; background: #f4f4f4; }
        section { margin-bottom: 32px; } h2 { font-size: 15px; font-family: ui-monospace, monospace; }
        div { display: flex; gap: 16px; flex-wrap: wrap; align-items: flex-start; }
        img { zoom: 0.5; box-shadow: 0 1px 6px rgba(0,0,0,.25); }
        </style>
        \(rows)
        """
    }
}
