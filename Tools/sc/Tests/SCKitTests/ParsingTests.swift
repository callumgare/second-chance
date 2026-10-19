import ArgumentParser
import Foundation
import Testing
@testable import SCKit

/// The command line as users type it: the right command is chosen, values are
/// validated, and pass-through arguments survive intact.
@Suite("Command-line parsing")
struct ParsingTests {
    @Test("Bare `sc test` runs everything, and takes integration games")
    func bareTestIsAll() throws {
        let bare = try SC.parseAsRoot(["test"])
        #expect(bare is TestAllCommand)

        let withGames = try #require(try SC.parseAsRoot(["test", "stay-tuned", "blue-moon"]) as? TestAllCommand)
        #expect(withGames.games == ["stay-tuned", "blue-moon"])
        #expect(withGames.integration.refreshWrapp == .full)
    }

    @Test("Named suites parse to their own commands")
    func namedSuites() throws {
        #expect(try SC.parseAsRoot(["test", "unit"]) is TestUnitCommand)
        let integration = try #require(try SC.parseAsRoot(["test", "integration", "stay-tuned", "--refresh-wrapp", "template"]) as? TestIntegrationCommand)
        #expect(integration.games == ["stay-tuned"])
        #expect(integration.integration.refreshWrapp == .template)
        #expect(integration.integration.ignoreLoad == false)
        #expect(integration.report.openReport == .failures)
        let loaded = try #require(try SC.parseAsRoot(["test", "integration", "--ignore-load"]) as? TestIntegrationCommand)
        #expect(loaded.integration.ignoreLoad)
    }

    @Test("Invalid values are rejected", arguments: [
        ["wrapp", "run", "stay-tuned", "--refresh-wrapp", "sometimes"],
        ["wrapp", "build", "stay-tuned", "--from", "stam"],
        ["wrapp", "build", "shadow-ranch", "--from", "steam", "--steam-launch", "sometimes"],
        ["app", "run", "--debug", "bogus"],
        ["app", "run", "--debug", "settings-dialog"],
        ["wrapp", "run", "x", "--debug", "wine"],
        ["wrapp", "run", "x", "--debug", "keep-in-dock=1"],
        ["release", "--dry-run", "--notes-only"],
        ["release", "--version", "1.2"],
        ["test", "unit", "--logs", "pretty"],
        ["in-gui-session"],
        ["attach", "--list", "--stop"],
        ["attach", "--list", "20260101"],
    ])
    func invalidValues(arguments: [String]) {
        #expect(throws: (any Error).self) { try SC.parseAsRoot(arguments) }
    }

    @Test("Arguments after -- reach the program unchanged")
    func passThrough() throws {
        let run = try #require(try SC.parseAsRoot(["wrapp", "run", "stay-tuned", "--debug", "log-window,wine=+seh", "--", "a b", "--debug"]) as? WrappRunCommand)
        #expect(run.game == "stay-tuned")
        #expect(run.wrappArguments == ["a b", "--debug"])
        #expect(run.debug.values == ["log-window,wine=+seh"])

        let wine = try #require(try SC.parseAsRoot(["wrapp", "wine", "stay-tuned", "--", "regedit"]) as? WrappWineCommand)
        #expect(wine.wineArguments == ["regedit"])

        let gui = try #require(try SC.parseAsRoot(["in-gui-session", "--", "open", "-n", "x.app"]) as? InGUISessionCommand)
        #expect(gui.command == ["open", "-n", "x.app"])
    }

    @Test("Shared options parse on every command that takes them")
    func sharedOptions() throws {
        let build = try #require(try SC.parseAsRoot([
            "wrapp", "build", "stay-tuned", "--skip-app-build", "--logs", "raw",
            "--disk", "/tmp/a.iso", "--disk", "/tmp/b.iso", "--patch-failure", "cancel", "--wrapps-dir", "/tmp/w",
        ]) as? WrappBuildCommand)
        #expect(build.appBuild.skipAppBuild)
        #expect(build.global.logs == .raw)
        #expect(build.source.disk.disks == ["/tmp/a.iso", "/tmp/b.iso"])
        #expect(build.source.patchFailure == .cancel)
        #expect(build.wrapps.wrappsDir == "/tmp/w")
    }

    @Test("Help for a command sc doesn't have is an error", arguments: [
        ["build", "wrapp", "--help"],
        ["build", "--help"],
        ["wrapp", "bild", "-h"],
        ["help", "build", "wrapp"],
    ])
    func helpForUnknownCommand(arguments: [String]) {
        #expect(throws: SCError.self) { try HelpRequestCheck.validate(arguments) }
    }

    @Test("Help for real commands, and their arguments, passes", arguments: [
        ["--help"],
        ["wrapp", "--help"],
        ["wrapp", "build", "--help"],
        ["wrapp", "build", "royal-tower", "--from", "disk", "-h"],
        ["test", "stay-tuned", "--help"],
        ["help", "wrapp", "build"],
        ["build", "wrapp"],
        ["in-gui-session", "--", "x", "--help"],
    ])
    func helpForKnownCommand(arguments: [String]) throws {
        try HelpRequestCheck.validate(arguments)
    }

    @Test("Swapped words suggest the command they spell")
    func helpSuggestsReorder() throws {
        let error = try #require(throws: SCError.self) { try HelpRequestCheck.validate(["build", "wrapp", "--help"]) }
        #expect(error.message == "Unknown command 'sc build'.")
        #expect(error.hints.first == "Did you mean 'sc wrapp build'?")
    }

    @Test("clean takes its targets by name")
    func cleanTargets() throws {
        let clean = try #require(try SC.parseAsRoot(["clean", "wine-prefixes", "test-results", "--yes"]) as? CleanCommand)
        #expect(clean.targets == [.winePrefixes, .testResults])
        let steam = try #require(try SC.parseAsRoot(["clean", "steam-session", "steam-client"]) as? CleanCommand)
        #expect(steam.targets == [.steamSession, .steamClient])
        #expect(clean.yes)
        #expect(throws: (any Error).self) { try SC.parseAsRoot(["clean", "everything"]) }
    }
}

@Suite("Debug options")
struct DebugOptionTests {
    @Test("Values map to the program's flags and environment")
    func effects() throws {
        let effect = try DebugOption.resolve(["log-window,wine=+seh,+d3d9", "slow-start=1", "no-cursor-lock"], for: .wrapp)
        #expect(effect.arguments == ["--debug"])
        #expect(effect.environment == [
            "SECOND_CHANCE_WINEDEBUG": "+seh,+d3d9",
            "SECOND_CHANCE_DIAG_SLOW_SECONDS": "1",
            "SECOND_CHANCE_CURSOR_LOCK": "0",
        ])
    }

    @Test("Each program accepts only its own options")
    func scopes() throws {
        #expect(try DebugOption.resolve(["strict-install"], for: .wrappBuild).environment == ["STRICT_INSTALL": "true"])
        #expect(throws: ValidationError.self) { try DebugOption.resolve(["strict-install"], for: .wrapp) }
        #expect(try DebugOption.resolve(["skip-installer"], for: .app).arguments == ["--skip-installer"])
    }

    @Test("Every option is offered to at least one program, with help")
    func tableIsComplete() {
        for option in DebugOption.all {
            #expect(!option.targets.isEmpty, "\(option.name) has no targets")
            #expect(!option.help.isEmpty, "\(option.name) has no help")
        }
        #expect(Set(DebugOption.all.map(\.name)).count == DebugOption.all.count, "duplicate --debug names")
    }
}
