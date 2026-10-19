import ArgumentParser
import Foundation
import GameCatalog

// MARK: - Sources

/// Where a wrapp is built from. Each source has its own options type
/// conforming to `WrappSourceInput` — the same shape as the app's
/// `WrappBuildStrategy`, where a new source is a new builder. Her Interactive
/// downloads would be the next case.
enum WrappSourceKind: String, CaseIterable, ExpressibleByArgument, Sendable {
    case disk
    case steam
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

enum PatchFailurePolicy: String, CaseIterable, ExpressibleByArgument, Sendable {
    case `continue`
    case cancel
}

/// Everything about what a wrapp is built from.
struct WrappSourceOptions: ParsableArguments {
    @Option(help: "What to build the wrapp from: disk or steam.")
    var from: WrappSourceKind = .disk

    @OptionGroup(title: "Disk source")
    var disk: DiskSourceOptions

    @OptionGroup(title: "Steam source")
    var steam: SteamSourceOptions

    @Option(help: "What to do when an official game patch fails to apply: continue or cancel. Default: continue.")
    var patchFailure: PatchFailurePolicy?

    var input: WrappSourceInput {
        switch from {
        case .disk: disk
        case .steam: steam
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
                let following = follower.follow { record in
                    switch record.event {
                    case "stage": if let text = record.text { update("\(label) — \(text)") }
                    case "failed": if let message = record.message { update("\(label) — failed: \(message)") }
                    default: break
                    }
                }
                defer { following.cancel() }
                try await ui.logStep(
                    "Second Chance", log: "wrapp-build-\(game.slug)", success: "Second Chance finished",
                    visibleLines: 5, keepOnSuccess: false
                ) { sink in
                    try await Proc.stream(app, arguments, env: environment, cwd: repo.root) { await sink.line($0) }
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

    /// Copy the app build's WrappTemplate executable and debug dylib into an
    /// existing wrapp and re-sign it — the fast loop for WrappTemplate
    /// changes, without reinstalling the game.
    func updateTemplate(of wrapp: URL) async throws {
        let sourceDir = repo.builtTemplate.appendingPathComponent("Contents/MacOS")
        let targetDir = wrapp.appendingPathComponent("Contents/MacOS")
        let files = ["WrappTemplate", "WrappTemplate.debug.dylib"]
        try await ui.progressStep("Update template in \(wrapp.lastPathComponent)", success: "Updated template in \(wrapp.lastPathComponent)") { update in
            for file in files {
                let source = sourceDir.appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw SCError("The app build has no \(file) at \(repo.display(source)).")
                }
                update("Copying \(file)")
                let target = targetDir.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source, to: target)
            }
            // Ad-hoc, like WrappBuildHelper.signWrapp: the files, then the bundle.
            for target in files.map({ targetDir.appendingPathComponent($0).path }) + [wrapp.path] {
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
