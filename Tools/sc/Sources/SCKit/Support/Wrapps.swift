import ArgumentParser
import Foundation

// MARK: - Sources

/// Where a wrapp is built from. Each source has its own options type
/// conforming to `WrappSourceInput` — the same shape as the app's
/// `WrappBuildStrategy`, where a new source is a new builder.
enum WrappSourceKind: String, CaseIterable, ExpressibleByArgument, Sendable {
    case disk
    case steam
    case herDownload = "her-download"
    case bigFish = "big-fish"
    case download
}

/// What a source contributes to a headless build: the app's
/// `INSTALLATION_SOURCE` and the inputs that source reads.
protocol WrappSourceInput {
    func environment(for game: CatalogGame, repo: Repo) throws -> [String: String]
    /// Games this source can build right now, for prompts and error messages.
    func availableGames(repo: Repo) -> [CatalogGame]
    var availabilityDescription: String { get }
}

/// `--from disk`: the game's CD images.
struct DiskSourceOptions: ParsableArguments, WrappSourceInput {
    @Option(help: ArgumentHelp(
        "Where disk images live, as <dir>/<slug>/disk-1.iso. Default: $INSTALLERS_DIR, else installers/.",
        valueName: "dir"
    ))
    var installersDir: String?

    @Option(name: .customLong("disk"), help: ArgumentHelp(
        "A disk image to install from (repeat for disk 2). Overrides the installers directory.",
        valueName: "iso"
    ))
    var disks: [String] = []

    func installersURL(_ repo: Repo) -> URL {
        installersDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? repo.defaultInstallersDir
    }

    func availableGames(repo: Repo) -> [CatalogGame] {
        Games.withInstallers(in: installersURL(repo))
    }

    var availabilityDescription: String { "installers" }

    func environment(for game: CatalogGame, repo: Repo) throws -> [String: String] {
        var images: [URL]
        if disks.isEmpty {
            let dir = installersURL(repo).appendingPathComponent(game.slug)
            images = (1...max(game.diskCount, 1)).map { dir.appendingPathComponent("disk-\($0).iso") }
            guard FileManager.default.fileExists(atPath: images[0].path) else {
                let available = availableGames(repo: repo).map(\.slug)
                throw SCError(
                    "No disk image for \(game.slug) at \(repo.display(images[0])).",
                    hints: available.isEmpty
                        ? ["Put the game's disk images in \(repo.display(installersURL(repo)))/<slug>/disk-1.iso, or pass --disk."]
                        : ["Games with installers: \(available.joined(separator: ", "))", "Or pass the image with --disk."]
                )
            }
            images = images.filter { FileManager.default.fileExists(atPath: $0.path) }
        } else {
            images = disks.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            for image in images where !FileManager.default.fileExists(atPath: image.path) {
                throw SCError("Disk image not found: \(image.path)")
            }
        }
        if game.diskCount > images.count {
            throw SCError("\(game.title) has \(game.diskCount) disks, but only \(images.count) image was found.",
                          hints: ["Add disk-2.iso next to disk-1.iso, or pass both with --disk."])
        }
        var env = ["INSTALLATION_SOURCE": "disk", "DISK_1_PATH": images[0].path]
        if images.count > 1 { env["DISK_2_PATH"] = images[1].path }
        return env
    }
}

/// `--from steam`: the game through Steam, signed in with the shared session
/// (docs/steam.md). A headless build can't sign in, so the session has to
/// exist already — build one game from the app first.
struct SteamSourceOptions: ParsableArguments, WrappSourceInput {
    @Option(help: ArgumentHelp(
        "For a DRM-free Steam game: start it via steam (cloud saves) or direct (quicker). Default: direct.",
        valueName: "mode"
    ))
    var steamLaunch: SteamLaunch?

    enum SteamLaunch: String, CaseIterable, ExpressibleByArgument, Sendable {
        case steam
        case direct
    }

    func availableGames(repo: Repo) -> [CatalogGame] {
        Catalog.games.filter(\.isOnSteam)
    }

    var availabilityDescription: String { "Steam" }

    func environment(for game: CatalogGame, repo: Repo) throws -> [String: String] {
        guard game.isOnSteam else {
            throw SCError("\(game.title) isn't on Steam.",
                          hints: ["Games on Steam: \(availableGames(repo: repo).map(\.slug).joined(separator: ", "))"])
        }
        var env = ["INSTALLATION_SOURCE": "steam", "STEAM_GAME_SLUG": game.slug]
        if let steamLaunch {
            guard game.offersSteamLaunchChoice else {
                throw SCError("\(game.title) has no launch choice: its DRM decides how it starts.")
            }
            env["STEAM_LAUNCH_MODE"] = steamLaunch.rawValue
        }
        return env
    }
}

/// `--from her-download`: a game bought from Her Interactive, its Windows
/// installer (.exe) or Mac download (.dmg) (docs/her-download.md).
struct HerDownloadSourceOptions: ParsableArguments, WrappSourceInput {
    @Option(name: .customLong("her-download"), help: ArgumentHelp(
        "The download to build from. Default: the one in <installers>/<slug>/ named her-download*.exe or her-download*.dmg.",
        valueName: "file"
    ))
    var download: String?

    func availableGames(repo: Repo) -> [CatalogGame] {
        Games.withHerDownloads(in: repo.defaultInstallersDir)
    }

    var availabilityDescription: String { "Her Interactive downloads" }

    func environment(for game: CatalogGame, repo: Repo) throws -> [String: String] {
        let file: URL
        if let download {
            file = URL(fileURLWithPath: (download as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw SCError("Her download not found: \(file.path)")
            }
        } else {
            let found = Games.herDownloads(for: game.slug, in: repo.defaultInstallersDir)
            guard let first = found.first else {
                let available = availableGames(repo: repo).map(\.slug)
                throw SCError(
                    "No Her Interactive download for \(game.slug) in \(repo.display(repo.defaultInstallersDir.appendingPathComponent(game.slug))).",
                    hints: ["Name it her-download-<anything>.exe or .dmg, or pass --her-download."]
                        + (available.isEmpty ? [] : ["Games with Her downloads: \(available.joined(separator: ", "))"])
                )
            }
            guard found.count == 1 else {
                throw SCError("\(game.slug) has more than one Her download: \(found.map(\.lastPathComponent).joined(separator: ", ")).",
                              hints: ["Pick one with --her-download."])
            }
            file = first
        }
        return ["INSTALLATION_SOURCE": "her-download", "HER_INSTALLER_PATH": file.path]
    }
}

/// `--from big-fish`: a game through Big Fish's Game Manager
/// (docs/big-fish.md). A headless build can't ask anyone to sign in, so the
/// full game signs in with the test account in `.env` (`BIG_FISH_EMAIL`,
/// `BIG_FISH_PASSWORD`); `--big-fish-trial` builds the game's free trial,
/// signed out, instead.
struct BigFishSourceOptions: ParsableArguments, WrappSourceInput {
    @Flag(help: ArgumentHelp(
        "Build the game's free trial from Big Fish, signed out, rather than the full game the test account owns.",
        discussion: "A trial wrapp is for testing: it starts through the Game Manager's Play Now and runs for 60 minutes."
    ))
    var bigFishTrial = false

    /// The `.env` keys holding the test account's sign-in. Passed on to the
    /// app (or the test host) and never shown.
    static let accountKeys = ["BIG_FISH_EMAIL", "BIG_FISH_PASSWORD"]

    func availableGames(repo: Repo) -> [CatalogGame] {
        Catalog.games.filter(\.isOnBigFish)
    }

    var availabilityDescription: String { "Big Fish Games" }

    func environment(for game: CatalogGame, repo: Repo) throws -> [String: String] {
        try environment(for: game, dotEnv: bigFishTrial ? [:] : DotEnv.load(repo))
    }

    func environment(for game: CatalogGame, dotEnv: [String: String]) throws -> [String: String] {
        guard game.isOnBigFish else {
            throw SCError("\(game.title) isn't sold by Big Fish Games.",
                          hints: ["Games on Big Fish: \(Catalog.games.filter(\.isOnBigFish).map(\.slug).joined(separator: ", "))"])
        }
        var env = ["INSTALLATION_SOURCE": "big-fish", "BIG_FISH_GAME_SLUG": game.slug]
        if bigFishTrial {
            env["BIG_FISH_TRIAL"] = "1"
            return env
        }
        guard let account = Self.testAccount(dotEnv: dotEnv) else {
            throw SCError("A headless Big Fish build can't ask anyone to sign in, and .env has no test account.",
                          hints: ["Set \(Self.accountKeys.joined(separator: " and ")) in .env (see .env.example).",
                                  "Or build the free trial with --big-fish-trial."])
        }
        env["BIG_FISH_TEST_SIGN_IN"] = "1"
        env.merge(account) { _, new in new }
        return env
    }

    /// The test account's sign-in from `.env`, or nil when either half is
    /// missing or empty.
    static func testAccount(dotEnv: [String: String]) -> [String: String]? {
        var account: [String: String] = [:]
        for key in accountKeys {
            guard let value = dotEnv[key], !value.isEmpty else { return nil }
            account[key] = value
        }
        return account
    }
}

/// `--from download`: a game its makers give away, downloaded from where
/// its bundle says (docs/wrapp-build.md#the-download-source).
struct DownloadSourceOptions: ParsableArguments, WrappSourceInput {
    func availableGames(repo: Repo) -> [CatalogGame] {
        Catalog.games.filter { $0.hasEdition(source: "download", repo: repo) }
    }

    var availabilityDescription: String { "download editions" }

    func environment(for game: CatalogGame, repo: Repo) throws -> [String: String] {
        guard availableGames(repo: repo).contains(game) else {
            throw SCError("\(game.title) has no download edition.",
                          hints: ["Games to download: \(availableGames(repo: repo).map(\.slug).joined(separator: ", "))"])
        }
        return ["INSTALLATION_SOURCE": "download", "DOWNLOAD_PROGRAM": game.programID]
    }
}

enum PatchFailurePolicy: String, CaseIterable, ExpressibleByArgument, Sendable {
    case `continue`
    case cancel
}

/// Everything about what a wrapp is built from.
struct WrappSourceOptions: ParsableArguments {
    @Option(help: "What to build the wrapp from: disk, steam, her-download, big-fish or download.")
    var from: WrappSourceKind = .disk

    @OptionGroup(title: "Disk source")
    var disk: DiskSourceOptions

    @OptionGroup(title: "Steam source")
    var steam: SteamSourceOptions

    @OptionGroup(title: "Her Interactive download source")
    var herDownload: HerDownloadSourceOptions

    @OptionGroup(title: "Big Fish Games source")
    var bigFish: BigFishSourceOptions

    @OptionGroup(title: "Download source")
    var download: DownloadSourceOptions

    @Option(help: "What to do when an official game patch fails to apply: continue or cancel. Default: continue.")
    var patchFailure: PatchFailurePolicy?

    @OptionGroup var inputs: InputOptions

    var input: WrappSourceInput {
        switch from {
        case .disk: disk
        case .steam: steam
        case .herDownload: herDownload
        case .bigFish: bigFish
        case .download: download
        }
    }
}

/// How `--refresh-wrapp` brings an existing wrapp up to date first.
enum WrappRefresh: String, CaseIterable, ExpressibleByArgument, Sendable {
    /// Use it as it is.
    case skip
    /// Put the app build's WrappTemplate into it and re-sign it (`sc wrapp update`).
    case template
    /// Rebuild it from its source (`sc wrapp build`).
    case full
}

// MARK: - Building

struct WrappBuilder {
    let session: Session
    var repo: Repo { session.repo }
    var ui: UI { session.ui }

    /// Build a wrapp headlessly with the app built in DerivedData. Shows the
    /// app's build stage as a progress step with its log tail underneath,
    /// and (interactively) an `l` key to launch the wrapp when it's done.
    func build(
        _ game: CatalogGame,
        source: WrappSourceOptions,
        debug: DebugEffect,
        wrappsDir: URL,
        toggle: LaunchToggle? = nil
    ) async throws -> URL {
        try repo.requireDebugApp()
        var env = try source.input.environment(for: game, repo: repo)
        try FileManager.default.createDirectory(at: wrappsDir, withIntermediateDirectories: true)

        let progressFile = FileManager.default.temporaryDirectory.appendingPathComponent("sc-progress-\(UUID().uuidString).jsonl")
        let follower = ProgressFollower(url: progressFile)
        defer { follower.remove() }

        env["NON_INTERACTIVE"] = "true"
        env["OUTPUT_PATH"] = wrappsDir.path
        env["SECOND_CHANCE_PROGRESS_PATH"] = progressFile.path
        // The app only copies its logs to stderr when stderr is a terminal;
        // here it's a pipe to sc. That copy is notice and up; the full log,
        // every level, goes beside it.
        env["SECOND_CHANCE_LOG_STDERR"] = "1"
        let fullLog = try ui.makeLogFile("wrapp-build-\(game.slug).full")
        env["SECOND_CHANCE_LOG_FILE"] = fullLog.path
        // And as JSON lines, for jq and agents (docs/logging.md).
        env["SECOND_CHANCE_LOG_JSONL"] = fullLog.path.replacingOccurrences(of: ".full.log", with: ".jsonl")
        // A disc of another game fails the build instead of building that game.
        env["EXPECTED_GAME_SLUG"] = game.slug
        if let policy = source.patchFailure { env["PATCH_FAILURE_POLICY"] = policy.rawValue }
        if let json = try source.inputs.environmentValue() { env["SECOND_CHANCE_INPUTS"] = json }
        env.merge(debug.environment) { _, new in new }

        toggle?.start()
        defer { toggle?.stop() }

        let app = repo.appExecutable.path
        let arguments = debug.arguments
        let environment: [String: String?] = env.mapValues { $0 }
        let label = "Building \(game.title)"
        do {
            try await ui.progressStep(label, success: "Built \(game.wrappName)", failure: "Couldn't build \(game.wrappName)") { update in
                // The step's message is replaced by each update, so every update
                // keeps the game in it.
                let status = BuildStatusLine(label: label)
                let following = follower.follow { record in
                    if let line = status.line(after: record) { update(line) }
                }
                defer { following.cancel() }
                try await ui.logStep(
                    "Second Chance", log: "wrapp-build-\(game.slug)", success: "Second Chance finished",
                    visibleLines: 5, keepOnSuccess: false
                ) { sink in
                    // The app answers for itself, so Steam inside a Steam build
                    // doesn't wait on macOS prompts addressed to sc (docs/steam.md).
                    try await Proc.stream(app, arguments, env: environment, cwd: repo.root, disclaimResponsibility: true) { await sink.line($0) }
                }
            }
        } catch {
            ui.line(ui.format("\(.muted("  Every level: \(repo.display(fullLog))"))"))
            throw error
        }

        // Where the app says it saved the wrapp; the expected name only if it
        // didn't say, so an older wrapp of the same name can't pass for this one.
        let reported = ProgressRecord.all(in: progressFile).last { $0.event == "completed" }?.path
        let wrapp = reported.map { URL(fileURLWithPath: $0) } ?? repo.wrapp(for: game, in: wrappsDir)
        guard FileManager.default.fileExists(atPath: wrapp.appendingPathComponent("Contents/Info.plist").path) else {
            throw SCError("Second Chance finished, but there's no wrapp at \(repo.display(wrapp)).",
                          hints: ["Check the log in \(repo.display(repo.scLogs))."])
        }
        return wrapp
    }

    /// Copy the app build's WrappTemplate executable, its debug dylib, the
    /// in-process helpers (which both engines load from the wrapp's
    /// Frameworks) and its asset catalog (the accent colour and icon, nothing
    /// per game) into an existing wrapp and re-sign it — the fast loop for
    /// WrappTemplate changes, without reinstalling the game.
    func updateTemplate(of wrapp: URL) async throws {
        let files = ["Contents/MacOS/WrappTemplate", "Contents/MacOS/WrappTemplate.debug.dylib",
                     "Contents/Frameworks/in_process_helpers.dylib", "Contents/Resources/Assets.car"]
        try await ui.progressStep("Update template in \(wrapp.lastPathComponent)", success: "Updated template in \(wrapp.lastPathComponent)") { update in
            for file in files {
                let source = repo.builtTemplate.appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw SCError("The app build has no \(source.lastPathComponent) at \(repo.display(source)).")
                }
                update("Copying \(source.lastPathComponent)")
                let target = wrapp.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source, to: target)
            }
            // Ad-hoc, like WrappBuildHelper.signWrapp: the files, then the bundle.
            for target in files.map({ wrapp.appendingPathComponent($0).path }) + [wrapp.path] {
                update("Signing \(URL(fileURLWithPath: target).lastPathComponent)")
                let result = try await Proc.collect("/usr/bin/codesign", ["--force", "--sign", "-", target])
                guard result.succeeded else {
                    throw SCError("codesign failed for \(target): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        }
    }

    /// The wrapp for `game`, or an error saying how to make one.
    func existingWrapp(_ game: CatalogGame, in wrappsDir: URL) throws -> URL {
        let wrapp = repo.wrapp(for: game, in: wrappsDir)
        guard FileManager.default.fileExists(atPath: wrapp.appendingPathComponent("Contents/Info.plist").path) else {
            throw SCError("There's no wrapp for \(game.slug) in \(repo.display(wrappsDir)).",
                          hints: ["Build one with: sc wrapp build \(game.slug)"])
        }
        return wrapp
    }

    /// Replace sc with the wrapp, so it owns the terminal (its logs stream
    /// here; Ctrl-C goes to it).
    func launch(_ wrapp: URL, debug: DebugEffect, arguments: [String]) -> Never {
        ui.line(ui.format("\(.primary("▸ Launching \(wrapp.deletingPathExtension().lastPathComponent)"))"))
        Proc.exec(wrapp.appendingPathComponent("Contents/MacOS/WrappTemplate").path,
                  debug.arguments + arguments, env: debug.environment.mapValues { $0 })
    }
}

// MARK: - Status line

/// What a wrapp build's progress step says, from the app's progress
/// records: the stage, with the step's figures after it while it has some
/// ("Downloading through Steam — 1.2 GB of 2.4 GB").
final class BuildStatusLine: @unchecked Sendable {
    private let lock = NSLock()
    private let label: String
    private var stage: String?

    init(label: String) { self.label = label }

    /// The line to show after `record`, or nil when it changes nothing.
    func line(after record: ProgressRecord) -> String? {
        lock.withLock {
            switch record.event {
            case "stage":
                guard let text = record.text else { return nil }
                stage = text
                return "\(label) — \(text)"
            case "step-progress":
                let base = stage.map { "\(label) — \($0)" } ?? label
                return record.text.map { "\(base) (\($0))" } ?? base
            case "failed":
                return record.message.map { "\(label) — failed: \($0)" }
            default:
                return nil
            }
        }
    }
}

// MARK: - Launch when done

/// The `l` key during a wrapp build: decide mid-build whether to launch the
/// wrapp when it finishes. Shown as a footer line under the build's live
/// output; only offered when keys can be read.
final class LaunchToggle: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    private let note: String
    private let ui: UI
    private var footer: UI.RendererHandle?
    private var reader: Thread?
    private var stopped = false

    init(initiallyOn: Bool, note: String, ui: UI) {
        on = initiallyOn
        self.note = note
        self.ui = ui
    }

    var isOn: Bool { lock.withLock { on } }

    func start() {
        guard ui.canPrompt, TTY.enterKeyMode() else { return }
        footer = ui.renderer(pinnedToBottom: true)
        render()
        let thread = Thread { [weak self] in
            var byte: UInt8 = 0
            while let self, !self.isStopped {
                if read(STDIN_FILENO, &byte, 1) == 1, byte == UInt8(ascii: "l") || byte == UInt8(ascii: "L") {
                    self.lock.withLock { self.on.toggle() }
                    self.render()
                }
            }
        }
        reader = thread
        thread.start()
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func render() {
        // e.g. "launch when done: on, with default options (press l to toggle)"
        let state = isOn ? "on\(note.isEmpty ? "" : ", with \(note)")" : "off"
        let text = ui.format("\(.muted("  launch when done: "))")
            + ui.format(isOn ? "\(.success(state))" : "\(.muted(state))")
            + ui.format("\(.muted(" (press l to toggle)"))")
        footer?.rendering.render(text, standardPipeline: RegionAwarePipeline(region: ui.region))
    }

    func stop() {
        lock.withLock { stopped = true }
        TTY.leaveKeyMode()
        footer?.remove()
        footer = nil
    }
}

/// `--input <name>=<value>`: a value for one of the edition's inputs (a
/// choice's answer, `launch-mode=steam`), as the app takes them headless.
struct InputOptions: ParsableArguments {
    @Option(name: .customLong("input"), help: ArgumentHelp(
        "A value for one of the edition's inputs, as <name>=<value> (launch-mode=steam). Repeat it for more.",
        valueName: "name=value"
    ))
    var values: [String] = []

    /// The values by name.
    func parsed() throws -> [String: String] {
        var parsed: [String: String] = [:]
        for value in values {
            guard let equals = value.firstIndex(of: "="), equals != value.startIndex else {
                throw SCError("--input \(value) isn't <name>=<value>.", hints: ["For example: --input launch-mode=steam"])
            }
            parsed[String(value[..<equals])] = String(value[value.index(after: equals)...])
        }
        return parsed
    }

    /// `SECOND_CHANCE_INPUTS`: the values as JSON, since an environment
    /// variable's name can't keep an input's case and hyphens; nil for none.
    func environmentValue() throws -> String? {
        let parsed = try parsed()
        guard !parsed.isEmpty else { return nil }
        let data = try JSONSerialization.data(withJSONObject: parsed, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
