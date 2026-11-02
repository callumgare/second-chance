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
    /// Open its sign-in form, and bring its window to the front.
    func showSignIn() async throws
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

    public let wine: Wine
    private let state = NSLock()
    private var page: DevToolsPage?
    private var desktop: WineDesktop?
    private let onOutputLine: (@Sendable (String) -> Void)?

    public init(wrappPath: URL, prefixDir: URL? = nil, onOutputLine: (@Sendable (String) -> Void)? = nil) {
        wine = Wine(wrapp: wrappPath, prefix: prefixDir)
        self.onOutputLine = onOutputLine
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
        try await currentPage().run(Script.openSignIn)
        await SteamSignInWindow.bringForward(window: "sign-in window", programs: ["bfgclient.exe"], store: "the Game Manager")
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

    public func signInForTesting(email: String, password: String) async throws {
        let page = try await currentPage()
        try await page.run(Script.openSignIn)
        let deadline = Date().addingTimeInterval(60)
        while try await !page.evaluate(Script.signInFormShown, as: Bool.self) {
            guard Date() < deadline else { throw BigFishError.couldNotStart("its sign-in form didn't appear") }
            try await Task.sleep(for: .milliseconds(500))
        }
        // The expression holds the password: never log it.
        guard try await page.evaluate(Script.fillSignIn(email: email, password: password), as: Bool.self) else {
            throw BigFishError.couldNotStart("its sign-in form has changed")
        }
        logger.notice("Sent the Game Manager's sign-in form (test sign-in)")
    }

    public func shutdown(timeout: TimeInterval) async {
        let start = Date()
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
