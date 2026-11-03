//
//  BigFishGameManager.swift
//  SecondChanceKit
//
//  Big Fish's Game Manager, running in a build's Wine prefix: start it, see
//  whether the person has signed in, read their library, and have it download,
//  install and activate a game. Everything goes through its page (DevToolsPage),
//  using the functions its own buttons call, so it does what it would for a
//  person. See docs/big-fish.md.

import Foundation
import GameCatalog
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.BigFish")
/// What the Game Manager and Wine print while it runs.
private nonisolated let outputLogger = Logger(label: "au.gare.callum.second-chance.Shared.Wine")

/// What a build needs from the Game Manager. The real one is
/// `BigFishGameManager`; tests drive the build with a fake.
nonisolated public protocol BigFishGameManaging: Sendable {
    /// Whether it's installed in the prefix.
    var isInstalled: Bool { get }
    /// Start it, and wait until its page can be driven.
    func start(timeout: TimeInterval) async throws
    func isSignedIn() async throws -> Bool
    /// Show its window, which is otherwise kept off the screen, open its
    /// sign-in form, and bring the window to the front.
    func showSignIn() async throws
    /// Take its window off the screen again once the person has signed in.
    func hideWindow()
    /// The Nancy Drew games (or anything else) the signed-in account owns.
    func ownedGames() async throws -> [BigFishOwnedGame]
    /// Ask it to download (then install and activate) `sku`: the full game,
    /// or its free trial.
    func download(_ sku: BigFishSKU, fullVersion: Bool) async throws
    /// Start the installed `sku`, as its Play button does: for a trial, the
    /// only way to start it (bfgprocess just opens the Game Manager).
    func play(_ sku: BigFishSKU) async throws
    /// Where it has got to with `sku`; nil while it has no entry for it.
    func status(of sku: BigFishSKU) async throws -> BigFishGameStatus?
    /// The game once installed.
    func installedGame(_ sku: BigFishSKU) -> BigFishInstalledGame?
    func isRunning() -> Bool
    func signOut() async throws
    /// For test harnesses only (`BIG_FISH_TEST_SIGN_IN`): fill in and send the
    /// Game Manager's own sign-in form. A person always signs in themselves.
    func signInForTesting(email: String, password: String) async throws
    /// Quit it and end the prefix's Wine session.
    func shutdown(timeout: TimeInterval) async
}

nonisolated public final class BigFishGameManager: BigFishGameManaging, @unchecked Sendable {
    /// The Game Manager inside the prefix, as Wine sees it and as macOS does.
    public static let clientDirInPrefix = "drive_c/Program Files (x86)/bfgclient"
    static let windowsClient = #"C:\Program Files (x86)\bfgclient\bfgclient.exe"#
    /// Its programs, by process name: the window's, and its background services.
    public static let programs: Set<String> = ["bfgclient.exe", "bfggameservices.exe", "bfgipcmonitor.exe", "bfgprocess.exe"]

    /// Where it keeps its sign-in in the registry, and the values that make
    /// one: its tokens and when they expire, and the account's address. It
    /// starts signed in from these alone (`BigFishSessionStore`).
    public static let accountKey: WineRegistry.Key = #"HKEY_CURRENT_USER\Software\Big Fish Games\Client"#
    public static let accountValues = ["AccessToken", "AccessExpires", "RefreshToken", "RefreshExpires", "Email", "EmailError"]

    public let wine: Wine
    private let state = NSLock()
    private var page: DevToolsPage?
    private var desktop: WineDesktop?
    /// The exe of the game the Game Manager will start, whose in-process
    /// helpers (native fullscreen, mode scaling) are armed through the Game
    /// Manager's environment: a game it starts gets its, as one Steam starts
    /// gets Steam's.
    private let gameExe: URL?
    private let onOutputLine: (@Sendable (String) -> Void)?

    /// `gameExe`, the game's .exe, when the Game Manager will start a game
    /// (a trial's Play Now) — not while a build installs one.
    public init(wrappPath: URL, prefixDir: URL? = nil, gameExe: URL? = nil, onOutputLine: (@Sendable (String) -> Void)? = nil) {
        wine = Wine(wrapp: wrappPath, prefix: prefixDir)
        self.gameExe = gameExe
        self.onOutputLine = onOutputLine
    }

    /// While this file exists the Game Manager's windows are on screen; they
    /// are kept off it otherwise (`Wine.hiddenWindowsVariables`). Outside the
    /// prefix, so it never ships in a wrapp.
    let showWindowFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("second-chance-show-big-fish-\(UUID().uuidString)")

    /// What its processes are started with: its windows hidden, and the
    /// game's helpers armed when it will start a game. Without a game, the
    /// windows of everything it runs are hidden too (the game's installer,
    /// Microsoft's DirectX setup); with one, only its own, as the game is
    /// one of the programs it runs.
    var environment: [String: String] {
        var environment = Wine.hiddenWindowsVariables(exe: gameExe == nil ? "*" : "bfgclient.exe", showFile: showWindowFile)
        if let gameExe {
            environment.merge(Wine.inProcessHelperVariables(gameExe: gameExe)) { _, game in game }
        }
        return environment
    }

    var clientDir: URL { wine.prefix.appendingPathComponent(Self.clientDirInPrefix) }
    var programFiles: URL { wine.prefix.appendingPathComponent("drive_c/Program Files (x86)") }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: clientDir.appendingPathComponent("bfgclient.exe").path)
    }

    public func start(timeout: TimeInterval) async throws {
        guard let port = DevToolsPage.freePort() else { throw BigFishError.couldNotStart("no free port") }
        let desktop = await WineDesktop.start(wine, logger: logger, outputLogger: outputLogger)
        state.withLock { self.desktop = desktop }
        _ = try wine.start(.program(Self.windowsClient, ["--remote-debugging-port=\(port)"]),
                           environment: environment,
                           output: .log(outputLogger, onLine: onOutputLine))
        logger.notice("Started the Game Manager (DevTools on port \(port))")

        let page = DevToolsPage(port: port)
        let deadline = Date().addingTimeInterval(timeout)
        // Until Wine has set it up the process is its loader, by another name,
        // so it has only quit once it has been seen running.
        var seenRunning = false
        while true {
            do {
                if await !page.isConnected {
                    try await page.connect(matching: Self.isUIPage)
                }
                if try await page.evaluate(Script.ready, as: Bool.self, timeout: 10) { break }
            } catch {
                // Not listening, or the page still loading: try again.
            }
            guard Date() < deadline else {
                await page.close()
                throw BigFishError.couldNotStart("its window didn't load within \(Int(timeout))s")
            }
            if isRunning() {
                seenRunning = true
            } else if seenRunning {
                throw BigFishError.exited
            }
            try await Task.sleep(for: .seconds(1))
        }
        state.withLock { self.page = page }
        logger.notice("The Game Manager's page is ready")
    }

    public func isSignedIn() async throws -> Bool {
        try await currentPage().evaluate(Script.signedIn, as: Bool.self)
    }

    public func showSignIn() async throws {
        let page = try await currentPage()
        try await waitForSignInForm(on: page)
        // Only the sign-in dialog, centred in the window. The window keeps
        // its size: the Game Manager holds it at its own minimum, whether
        // macOS or Windows resizes it.
        if try await !page.evaluate(Script.signInOnly, as: Bool.self) {
            logger.warning("The Game Manager's sign-in dialog has changed, so its whole window is shown")
        }
        FileManager.default.createFile(atPath: showWindowFile.path, contents: nil)
        logger.notice("Showing the Game Manager's sign-in form")
        await SteamSignInWindow.bringForward(window: "sign-in window", programs: ["bfgclient.exe"], store: "the Game Manager")
    }

    public func hideWindow() {
        try? FileManager.default.removeItem(at: showWindowFile)
    }

    public func ownedGames() async throws -> [BigFishOwnedGame] {
        let games = try await currentPage().evaluate(Script.ownedGames, as: [BigFishOwnedGame]?.self, timeout: 90)
        guard let games else { throw BigFishError.libraryUnavailable }
        logger.notice("The Big Fish account owns \(games.count) game(s): \(games.map(\.sku).joined(separator: ", "))")
        return games
    }

    public func download(_ sku: BigFishSKU, fullVersion: Bool) async throws {
        try await currentPage().run(Script.download(sku: sku.description, fullVersion: fullVersion))
        logger.notice("Asked the Game Manager to download \(sku)\(fullVersion ? "" : " (free trial)")")
    }

    public func play(_ sku: BigFishSKU) async throws {
        try await currentPage().run(Script.play(sku: sku.description))
        logger.notice("Asked the Game Manager to start \(sku)")
    }

    public func status(of sku: BigFishSKU) async throws -> BigFishGameStatus? {
        try await currentPage().evaluate(Script.status(sku: sku.description), as: BigFishGameStatus?.self)
    }

    public func installedGame(_ sku: BigFishSKU) -> BigFishInstalledGame? {
        BigFishInstalledGame.find(sku: sku, in: programFiles)
    }

    public func isRunning() -> Bool { ProcessList.isRunning("bfgclient.exe") }

    public func signOut() async throws {
        try await currentPage().run(Script.signOut)
        logger.notice("Signed the Game Manager out")
    }

    /// Open the sign-in form, and wait until it's there.
    private func waitForSignInForm(on page: DevToolsPage) async throws {
        try await page.run(Script.openSignIn)
        let deadline = Date().addingTimeInterval(60)
        while try await !page.evaluate(Script.signInFormShown, as: Bool.self) {
            guard Date() < deadline else { throw BigFishError.couldNotStart("its sign-in form didn't appear") }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    public func signInForTesting(email: String, password: String) async throws {
        let page = try await currentPage()
        try await waitForSignInForm(on: page)
        // The expression holds the password: never log it.
        guard try await page.evaluate(Script.fillSignIn(email: email, password: password), as: Bool.self) else {
            throw BigFishError.couldNotStart("its sign-in form has changed")
        }
        logger.notice("Sent the Game Manager's sign-in form (test sign-in)")
    }

    public func shutdown(timeout: TimeInterval) async {
        let start = Date()
        hideWindow()
        if let page = state.withLock({ page }) { await page.close() }
        state.withLock { desktop }?.release()
        // The Game Manager has no quit command line; its whole session goes.
        await wine.server.stop()
        let stopped = await wine.server.waitUntilStopped(timeout: max(0, timeout - Date().timeIntervalSince(start)))
        logger.notice(stopped ? "The Game Manager and its Wine session stopped" : "The Game Manager's Wine session was still running after \(Int(timeout))s")
    }

    /// The page, connected again if it has gone away since (a reload drops
    /// the connection, and nothing reconnects it by itself).
    private func currentPage() async throws -> DevToolsPage {
        guard let page = state.withLock({ page }) else { throw BigFishError.notStarted }
        if await !page.isConnected {
            try await page.connect(matching: Self.isUIPage)
            logger.notice("Connected to the Game Manager's page again")
        }
        return page
    }

    /// Whether a DevTools page URL is the Game Manager's own window.
    static let isUIPage: @Sendable (String) -> Bool = { $0.contains("Game%20Manager/resources") || $0.contains("Game Manager/resources") }

    /// The scripts run in the Game Manager's page. They use what its own
    /// buttons call (site_output.js / global_output.js under
    /// ProgramData/Big Fish/Game Manager/resources), so they ask nothing of it
    /// a person couldn't.
    enum Script {
        static let ready = "!!(window.GM && GM.controller && GM.data && GM.data.userData && window.jQuery)"
        static let signedIn = "GM.data.userData.isLoggedIn === true"
        static let openSignIn = "(() => { const a = document.querySelector('li.sign_in a'); if (a) jQuery(a).trigger('click'); return !!a; })()"
        static let signOut = "GM.auth.logout(); true"
        static let signInFormShown = "!!document.querySelector('#o_login_email') && !!document.querySelector('#o_login_submit a.btn_login')"
        /// Show the sign-in dialog (SimpleModal's `#simplemodal-container`)
        /// alone, centred in the window, without its close button, and keep
        /// Escape from closing it. False when there's no such dialog.
        static let signInOnly = """
            (() => {
              const dialog = document.querySelector('#simplemodal-container');
              if (!dialog) return false;
              if (document.getElementById('second-chance-sign-in-only')) return true;
              const style = document.createElement('style');
              style.id = 'second-chance-sign-in-only';
              style.textContent = `
                body * { visibility: hidden !important; }
                #simplemodal-container, #simplemodal-container * { visibility: visible !important; }
                #simplemodal-container { position: fixed !important; left: 50% !important; top: 50% !important;
                  transform: translate(-50%, -50%) !important; }
                #simplemodal-container .simplemodal-close, #simplemodal-container .overlay_close { display: none !important; }
                .simplemodal-overlay { display: none !important; }
                html, body { background: #fff !important; overflow: hidden !important; }`;
              document.head.appendChild(style);
              document.addEventListener('keydown', event => {
                if (event.key === 'Escape') { event.stopImmediatePropagation(); event.preventDefault(); }
              }, true);
              return true;
            })()
            """

        /// Fill in the sign-in form and press its button, as a person would.
        static func fillSignIn(email: String, password: String) -> String {
            """
            (() => {
              const set = (selector, value) => {
                const field = document.querySelector(selector);
                if (!field) return false;
                field.value = value;
                jQuery(field).trigger('input').trigger('change');
                return true;
              };
              if (!set('#o_login_email', \(quoted(email))) || !set('#o_login_password', \(quoted(password)))) return false;
              const button = document.querySelector('#o_login_submit a.btn_login');
              if (!button) return false;
              jQuery(button).trigger('click');
              return true;
            })()
            """
        }
        /// The page's own library request (it adds the sign-in token and
        /// refreshes it), then what it filled in; null when it never answered.
        static let ownedGames = """
        (async () => {
          GM.data.userData.gameLibrary = null;
          GM.util.getPurchaseHistoryList('second-chance');
          for (let i = 0; i < 120 && !GM.data.userData.gameLibrary; i++) await new Promise(r => setTimeout(r, 500));
          const library = GM.data.userData.gameLibrary;
          return library ? library.map(g => ({sku: String(g.sku), title: String(g.title || '')})) : null;
        })()
        """

        static func download(sku: String, fullVersion: Bool) -> String {
            "GM.controller.event_to_native('downloadNewGame', {wrappingID: \(quoted(sku)), downloadFullVersion: \(fullVersion)}); true"
        }

        static func play(sku: String) -> String {
            "GM.extendedFunctions.playGame(\(quoted(sku)), 'second-chance'); true"
        }

        static func status(sku: String) -> String {
            """
            (() => {
              const g = (GM.data.installedGames || {})[\(quoted(sku))];
              if (!g || !g.gameState) return null;
              return {state: Number(g.gameState.state), errorCode: Number(g.gameState.errorCode || 0),
                      downloadProgress: Number(g.downloadProgress || 0), downloadSize: Number(g.downloadSize || 0),
                      installProgress: Number(g.installProgress || 0)};
            })()
            """
        }

        /// A JavaScript string literal (JSON's quoting is JavaScript's).
        static func quoted(_ text: String) -> String {
            String(decoding: (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
        }
    }
}

nonisolated public enum BigFishError: Error, Equatable, CustomStringConvertible {
    case notStarted
    case couldNotStart(String)
    case exited
    case libraryUnavailable

    public var description: String {
        switch self {
        case .notStarted: "the Game Manager hasn't been started"
        case .couldNotStart(let why): "the Game Manager couldn't start: \(why)"
        case .exited: "the Game Manager quit"
        case .libraryUnavailable: "the Game Manager didn't get the account's library"
        }
    }
}
