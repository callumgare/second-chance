import Foundation
import WrappBuilder
import WrappFormat

/// Every path the CLI reads or writes, resolved from the repo root.
///
/// The root comes from `SC_REPO_ROOT` (set by the `./sc` shim), else by walking
/// up from the current directory to the one holding `SecondChance.xcodeproj`,
/// so `sc` works from any directory inside the repo.
struct Repo: Sendable {
    let root: URL

    static func locate() throws -> Repo {
        let env = ProcessInfo.processInfo.environment
        if let override = env["SC_REPO_ROOT"], !override.isEmpty {
            return Repo(root: URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL)
        }
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("SecondChance.xcodeproj").path) {
                return Repo(root: dir.standardizedFileURL)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path {
                throw SCError("Not inside the Second Chance repo.",
                              hints: ["Run sc from the repo, or set SC_REPO_ROOT."])
            }
            dir = parent
        }
    }

    var project: URL { root.appendingPathComponent("SecondChance.xcodeproj") }
    var pbxproj: URL { project.appendingPathComponent("project.pbxproj") }
    var derivedData: URL { root.appendingPathComponent("DerivedData") }
    var debugProducts: URL { derivedData.appendingPathComponent("Build/Products/Debug") }
    var releaseProducts: URL { derivedData.appendingPathComponent("Build/Products/Release") }
    var app: URL { debugProducts.appendingPathComponent("Second Chance.app") }
    var appExecutable: URL { app.appendingPathComponent("Contents/MacOS/Second Chance") }
    /// The unit test bundle a test build embeds in the app. A plain app
    /// build (`sc app build`) removes it again.
    var testBundle: URL { app.appendingPathComponent("Contents/PlugIns/SecondChanceTests.xctest") }
    /// The freshly built template, outside the app bundle (what `wrapp update` copies from).
    var builtTemplate: URL { debugProducts.appendingPathComponent("WrappTemplate.app") }
    var testResults: URL { root.appendingPathComponent("test-results") }
    var scLogs: URL { derivedData.appendingPathComponent("sc-logs") }
    /// GUI-session jobs (`GUISession`), kept so `sc attach` can find them.
    var scJobs: URL { derivedData.appendingPathComponent("sc-jobs") }
    var releaseDir: URL { root.appendingPathComponent("build/release") }
    var changelog: URL { root.appendingPathComponent("CHANGELOG.md") }
    var notesTemplate: URL { root.appendingPathComponent(".cog/release-notes.tera") }
    /// What Claude Code is told when it rewrites the notes for players.
    var notesPrompt: URL { root.appendingPathComponent(".cog/release-notes-prompt.md") }
    /// Sparkle's command-line tools (`generate_keys`, `generate_appcast`),
    /// which Xcode downloads with the package on the first build.
    var sparkleTools: URL { derivedData.appendingPathComponent("SourcePackages/artifacts/sparkle/Sparkle/bin") }

    /// The program bundles Second Chance ships, and their schema.
    var bundles: URL { root.appendingPathComponent("Bundles") }
    /// The modules Second Chance ships, their schema and their releases' record.
    var modules: URL { root.appendingPathComponent("Modules") }
    var moduleReleases: URL { modules.appendingPathComponent("releases.json") }

    var defaultWrappsDir: URL { root.appendingPathComponent("built-apps") }

    /// `$INSTALLERS_DIR` when set, else `installers/`.
    var defaultInstallersDir: URL {
        if let override = ProcessInfo.processInfo.environment["INSTALLERS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return root.appendingPathComponent("installers")
    }

    /// The layer cache builds keep (`LayerStore`, `~/Library/Caches/SecondChance/layers`).
    static var layerStore: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecondChance/layers")
    }

    /// Where Wine prefixes were cached before the layer store; a build
    /// removes it, as does `sc clean layers`.
    static var formerWinePrefixCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecondChance/wine-prefix-cache")
    }

    /// The Steam sign-in every Steam wrapp shares (`SteamSessionStore`, in
    /// the steam module's `sign-in` store, which 1.1.0's apps reach through
    /// a link, `AppMigrations`).
    static var steamSession: [URL] {
        [StoreLocations.shared(owner: "steam", name: "sign-in").appendingPathComponent("session")]
    }

    /// The engine store: prepared engines (docs/modules.md#the-engine-store),
    /// the one every user shares on a Mac with test users.
    static var engineStore: URL { EngineStore.standardRoot() }

    /// What the build downloads into `~/Library/Caches/SecondChance` (AutoIt,
    /// the game patches, Steam's installer, Big Fish's Game Manager installer
    /// `bfginstaller35.exe`, engines' and free games' files): every entry
    /// there but the caches `sc clean` has targets of its own for, and the
    /// app's wrapp cache.
    static var downloads: [URL] {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecondChance")
        // `stores` is the cache stores' (`sc clean stores`), Steam's client among them.
        let kept: Set = ["layers", "wine-prefix-cache", "steam-client", "engines", "wrapp-cache", "wrapper-cache", "stores"]
        let entries = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { !kept.contains($0.lastPathComponent) }
    }

    /// The updated Steam client Steam builds reuse (`SteamClientCache`): the
    /// steam module's `client` store, and where 1.1.0 kept it.
    static var steamClientCache: [URL] {
        [StoreLocations.sharedCache(owner: "steam", name: "client"),
         FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SecondChance/steam-client")]
    }

    /// The path to show the user: relative to the repo when inside it.
    func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    }

    func wrapp(for game: CatalogGame, in wrappsDir: URL) -> URL {
        wrappsDir.appendingPathComponent(game.wrappName)
    }

    func requireDebugApp() throws {
        guard FileManager.default.fileExists(atPath: appExecutable.path) else {
            throw SCError("No app build found at \(display(app)).",
                          hints: ["Drop --skip-app-build, or run `sc app build` first."])
        }
    }
}

extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
