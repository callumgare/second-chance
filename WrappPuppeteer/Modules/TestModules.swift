//
//  TestModules.swift
//  WrappPuppeteer
//
//  What each module a wrapp runs means for driving its game under test:
//  which process owns the game's window, how focus is judged, what to
//  leave out of a capture, and how to end what it leaves behind.

import Foundation
import Logging
import PuppeteerCore
import SecondChanceKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.Wrapp")

/// A module's part in testing a wrapp: one for each module in the wrapp's
/// composition (`TestModules`), the way the wrapp has one at run time.
protocol TestModule {
    static var id: ModuleID { get }

    init(layout: WrappLayout, prefix: URL)

    /// The launcher only: the process owning the game's window, given the
    /// game's `.exe` name; nil when the `.exe` is.
    var gameProcessName: String? { get }

    /// The launcher only: whether its game is judged in focus by its window
    /// being fullscreen, rather than by its app being activated.
    var judgesFocusByFullscreen: Bool { get }

    /// Whether it shows a notice over the game's window for a while after
    /// the game starts (Steam's overlay), to leave out of a capture.
    var showsOverlayNotice: Bool { get }

    /// Commands that end what it runs and can outlive the wrapp, from the
    /// signal handler, which can't wait to see whether anything ends more
    /// gently. Only this wrapp's: other games may be building beside it.
    var cleanupCommands: [[String]] { get }

    /// Once the wrapp has gone, end what it left of this module, gently and
    /// then firmly; the pattern of what's still to be killed, if anything.
    func endLeftovers() -> String?
}

extension TestModule {
    var gameProcessName: String? { nil }
    var judgesFocusByFullscreen: Bool { false }
    var showsOverlayNotice: Bool { false }
    var cleanupCommands: [[String]] { [] }
    func endLeftovers() -> String? { nil }
}

/// Wine: the game is its own `.exe`, activated for focus. The wrapp's own
/// `wineserver -k` ends everything in its prefix — Steam included —
/// whatever it's called (under Wine 10 a Windows program's command line is
/// its Windows path, `C:\Program Files (x86)\Steam\steam.exe`), then
/// anything still running from the wrapp's own Wine is killed.
struct WineTestModule: TestModule {
    static let id = ModuleID.wine
    let layout: WrappLayout
    let prefix: URL

    init(layout: WrappLayout, prefix: URL) {
        self.layout = layout
        self.prefix = prefix
    }

    var cleanupCommands: [[String]] {
        let wineserver = layout.wine.appendingPathComponent("bin/wineserver").path
        return [["/usr/bin/env", "WINEPREFIX=\(prefix.path)", wineserver, "-k"]]
            + Wrapp.pkillCommand(matchingFrom: layout.wine.path + "/")
    }

    /// Wine's session gets a few seconds to finish, then `wineserver -k`,
    /// then `-k9` (`WineServer.shutDown`).
    func endLeftovers() -> String? {
        let wine = Wine(wrapp: layout.app, prefix: prefix)
        if !Blocking.wait({ await wine.server.shutDown() }) {
            logger.error("❌ The wrapp's Wine session didn't end")
        }
        guard Wrapp.isSafeToKill(from: layout.wine.path + "/") else { return nil }
        return "^" + Wrapp.extendedRegexEscaped(layout.wine.path + "/")
    }
}

/// Steam runs in the wrapp's Wine, which ends it; its overlay shows a
/// notice ("Press Shift+Tab to begin") in the window's bottom-right corner
/// for a few seconds after the game starts.
struct SteamTestModule: TestModule {
    static let id = ModuleID.steam

    init(layout: WrappLayout, prefix: URL) {}

    var showsOverlayNotice: Bool { true }
}

/// Big Fish's DRM starts the game in the wrapp's Wine, which ends it: the
/// game is its own `.exe`, as for a game the wrapp starts.
struct BigFishTestModule: TestModule {
    static let id = ModuleID.bigFish

    init(layout: WrappLayout, prefix: URL) {}
}

/// ScummVM is a single native process. It goes full screen without reliably
/// becoming the active app, so it's judged by its window being fullscreen,
/// and activating it would fight its own full-screen handling. It is ended
/// by its path: by the time that's needed the wrapp has gone and its child
/// belongs to launchd.
struct ScummVMTestModule: TestModule {
    static let id = ModuleID.scummvm
    let layout: WrappLayout

    init(layout: WrappLayout, prefix: URL) {
        self.layout = layout
    }

    var gameProcessName: String? { "scummvm" }
    var judgesFocusByFullscreen: Bool { true }

    var cleanupCommands: [[String]] {
        Wrapp.pkillCommand(matchingFrom: layout.scummvm.path)
    }

    /// SIGTERM, before the caller's SIGKILL.
    func endLeftovers() -> String? {
        guard Wrapp.isSafeToKill(from: layout.scummvm.path) else { return nil }
        let leftovers = "^" + Wrapp.extendedRegexEscaped(layout.scummvm.path)
        if ProcessControl.anyRunning(matching: leftovers),
           ProcessControl.end(matching: leftovers, signal: SIGTERM, timeout: 5) {
            logger.notice("   ScummVM ended when asked")
            return nil
        }
        return leftovers
    }
}

/// DOSBox is a single native process too, started full screen, so it is
/// judged and ended as ScummVM is.
struct DOSBoxTestModule: TestModule {
    static let id = ModuleID.dosbox
    let layout: WrappLayout

    init(layout: WrappLayout, prefix: URL) {
        self.layout = layout
    }

    var gameProcessName: String? { "dosbox" }
    var judgesFocusByFullscreen: Bool { true }

    var cleanupCommands: [[String]] {
        Wrapp.pkillCommand(matchingFrom: layout.dosbox.path)
    }

    /// SIGTERM, before the caller's SIGKILL.
    func endLeftovers() -> String? {
        guard Wrapp.isSafeToKill(from: layout.dosbox.path) else { return nil }
        let leftovers = "^" + Wrapp.extendedRegexEscaped(layout.dosbox.path)
        if ProcessControl.anyRunning(matching: leftovers),
           ProcessControl.end(matching: leftovers, signal: SIGTERM, timeout: 5) {
            logger.notice("   DOSBox ended when asked")
            return nil
        }
        return leftovers
    }
}

/// Basilisk II is a single native process too, its window the emulated
/// Mac's screen, activated for focus, and ended by its path as DOSBox is.
struct BasiliskTestModule: TestModule {
    static let id = ModuleID.basilisk
    let program: URL

    init(layout: WrappLayout, prefix: URL) {
        program = layout.app.appendingPathComponent("Contents/MacOS/BasiliskII")
    }

    var gameProcessName: String? { "BasiliskII" }

    var cleanupCommands: [[String]] {
        Wrapp.pkillCommand(matchingFrom: program.path)
    }

    /// SIGTERM, before the caller's SIGKILL.
    func endLeftovers() -> String? {
        guard Wrapp.isSafeToKill(from: program.path) else { return nil }
        let leftovers = "^" + Wrapp.extendedRegexEscaped(program.path)
        if ProcessControl.anyRunning(matching: leftovers),
           ProcessControl.end(matching: leftovers, signal: SIGTERM, timeout: 5) {
            logger.notice("   Basilisk II ended when asked")
            return nil
        }
        return leftovers
    }
}

/// A program the core starts (`LAUNCH /MacOS/tool`): a single native
/// process, named by its file, activated for focus, and ended by its path.
/// No module: a composition with no launcher has it.
struct CoreTestModule: TestModule {
    static let id = ModuleID(rawValue: Composition.coreTag)
    /// The program, in the app; nil when the wrapp's settings don't say.
    let program: URL?

    init(layout: WrappLayout, prefix: URL) {
        program = (try? WrappSettings(of: layout)).flatMap { layout.bareLocation($0.launch.program) }
    }

    var gameProcessName: String? { program?.lastPathComponent }

    var cleanupCommands: [[String]] {
        program.map { Wrapp.pkillCommand(matchingFrom: $0.path) } ?? []
    }

    /// SIGTERM, before the caller's SIGKILL.
    func endLeftovers() -> String? {
        guard let program, Wrapp.isSafeToKill(from: program.path) else { return nil }
        let leftovers = "^" + Wrapp.extendedRegexEscaped(program.path)
        if ProcessControl.anyRunning(matching: leftovers),
           ProcessControl.end(matching: leftovers, signal: SIGTERM, timeout: 5) {
            logger.notice("   The program ended when asked")
            return nil
        }
        return leftovers
    }
}

/// The test modules a wrapp's composition has, in start order.
struct TestModules {
    private(set) var all: [any TestModule]
    /// The module that starts the game; nil for a composition this doesn't
    /// know.
    let launcher: (any TestModule)?

    static let known: [any TestModule.Type] = [
        WineTestModule.self, SteamTestModule.self, BigFishTestModule.self, ScummVMTestModule.self, DOSBoxTestModule.self,
        BasiliskTestModule.self,
    ]

    init(composition: Composition?, layout: WrappLayout, prefix: URL) {
        guard let composition else {
            all = []
            launcher = nil
            return
        }
        all = composition.modules.compactMap { id in
            Self.known.first { $0.id == id }?.init(layout: layout, prefix: prefix)
        }
        guard let id = composition.launcher else {
            // The core starts the program.
            let core = CoreTestModule(layout: layout, prefix: prefix)
            all.append(core)
            launcher = core
            return
        }
        launcher = all.first { type(of: $0).id == id }
    }
}
