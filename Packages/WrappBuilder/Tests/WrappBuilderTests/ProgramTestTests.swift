import Foundation
import CoreGraphics
import Testing
@testable import WrappBuilder

struct ProgramTestTests {
    private func test(_ slug: String) throws -> ProgramTest {
        try ProgramTest.load(bundleFolder: bundlesRoot.appendingPathComponent("nancy-drew/\(slug)"), modulesRoot: modulesRoot)
    }

    @Test("Every bundle's test loads: its scenario, parameters and needles",
          arguments: try FileManager.default.contentsOfDirectory(atPath: bundlesRoot.appendingPathComponent("nancy-drew").path).sorted())
    func everyBundle(slug: String) throws {
        let test = try test(slug)
        #expect(test.scenario.id == "nancy-drew/quit-from-menu")
        for handler in test.scenario.handlers where handler.when != "blank" {
            #expect(!test.needles.tagged(handler.when).isEmpty, "\(slug): nothing is tagged \(handler.when)")
        }
    }

    @Test("A game's own splash screens join the shared ones, and no other game's")
    func splashesByBundle() throws {
        let oldClock = try test("old-clock").needles.tagged("splash").map(\.name)
        #expect(oldClock.contains("splash-old-clock-title"))
        #expect(oldClock.contains("splash-any-her-logo-blue"))
        #expect(!oldClock.contains { $0.hasPrefix("splash-blue-moon") })
        // Secrets Can Kill's name begins Secrets Can Kill Remastered's, whose
        // screens it took by its file names' prefix before they were in bundles.
        let original = try test("secrets-can-kill").needles.tagged("splash").map(\.name)
        #expect(!original.contains { $0.hasPrefix("splash-secrets-can-kill-remastered") })
    }

    @Test("A bundle's needle replaces the module's of the same id: Scarlet Hand's Exit is clicked at its label's top")
    func scarletHandsExit() throws {
        let exit = try #require(try test("scarlet-hand").needles.needles.first { $0.id == "exit-text" })
        #expect(exit.spec.click == .init(x: 0.5, y: 0))
        #expect(exit.clickPoint(in: CGRect(x: 10, y: 20, width: 100, height: 40)) == CGPoint(x: 60, y: 20))
        let usual = try #require(try test("old-clock").needles.needles.first { $0.id == "exit-text" })
        #expect(usual.clickPoint(in: CGRect(x: 10, y: 20, width: 100, height: 40)) == CGPoint(x: 60, y: 40))
    }

    @Test("A bundle's parameters set the scenario's")
    func parameters() throws {
        #expect(try test("secrets-can-kill-remastered").scenario.parameters["blank-start-takes-click"] == "true")
        let usual = try test("old-clock").scenario
        #expect(usual.parameters["blank-start-takes-click"] == "false")
        let blackStart = try #require(usual.handlers.first { $0.id == "black-start" })
        #expect(!blackStart.applies(with: usual.parameters))
        #expect(usual.handlers.first { $0.id == "splash" }?.retryAfter == 2)
    }

    @Test("The scenario's handlers say what to do")
    func handlers() throws {
        let scenario = try test("old-clock").scenario
        #expect(scenario.handlers.map(\.id) == ["black-start", "splash", "main-menu", "her-logo"])
        let menu = try #require(scenario.handlers.first { $0.id == "main-menu" })
        #expect(menu.actions == [.check("menu"), .click, .expectEnd])
        #expect(menu.repeatWhereLastSeen == 3)
        #expect(scenario.handlers.first { $0.id == "her-logo" }?.once == true)
    }

    @Test("A program beyond Nancy Drew has its own test: SkiFree started, then quit")
    func skifree() throws {
        let test = try ProgramTest.load(bundleFolder: bundlesRoot.appendingPathComponent("freeware/skifree"), modulesRoot: modulesRoot)
        #expect(test.scenario.id == "wine/starts-and-quits")
        // Its bundle sets no first key, so the handler that acts is the plain quit.
        #expect(test.scenario.handlers.first { $0.applies(with: test.scenario.parameters) }?.actions == [.quit(1)])
        #expect(test.needles.tagged("running").first?.spec.text?.strings.contains("Start") == true)
    }

    @Test("Every bundle beyond Nancy Drew has a test, with something for each handler to wait for",
          arguments: try FileManager.default.contentsOfDirectory(atPath: bundlesRoot.appendingPathComponent("freeware").path).sorted())
    func freeware(name: String) throws {
        let test = try ProgramTest.load(bundleFolder: bundlesRoot.appendingPathComponent("freeware/\(name)"), modulesRoot: modulesRoot)
        for handler in test.scenario.handlers where handler.when != "blank" {
            #expect(!test.needles.tagged(handler.when).isEmpty, "\(name): nothing is tagged \(handler.when)")
        }
    }

    @Test("A parameter the scenario doesn't have is refused")
    func unknownParameter() throws {
        let file = modulesRoot.appendingPathComponent("nancy-drew/scenarios/quit-from-menu.yaml")
        #expect(throws: ScenarioError.self) {
            try Scenario.load(id: "nancy-drew/quit-from-menu", file: file, overrides: ["no-such-thing": "1"])
        }
    }

    @Test("An image with no description, and no defaults beside it, is refused")
    func undescribedImage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("needles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("lonely.png"))
        #expect(throws: NeedleError.self) { try NeedleLibrary.load([folder]) }
    }

    @Test("A region needle searched for over most of the screen, or at several sizes, is warned about; a narrow one isn't")
    func slowRegionNeedles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("needles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let needles = [
            "whole": "kind: region\ntags: [running]\n",
            "wide": "kind: region\ntags: [running]\nregion: { search: { x: 0, y: 0, width: 0.8, height: 0.8 } }\n",
            "sizes": "kind: region\ntags: [running]\nregion: { search: { x: 0.5, y: 0, width: 0.5, height: 0.5 }, scales: [0.9, 1.0, 1.1] }\n",
            "narrow": "kind: region\ntags: [running]\nregion: { search: { x: 0.5, y: 0, width: 0.5, height: 0.5 }, scales: [1.0] }\n",
        ]
        for (name, yaml) in needles {
            try yaml.write(to: folder.appendingPathComponent(name + ".yaml"), atomically: true, encoding: .utf8)
            try Data([0]).write(to: folder.appendingPathComponent(name + ".png"))
        }
        let warnings = Dictionary(uniqueKeysWithValues: try NeedleLibrary.load([folder]).needles.map { ($0.id, $0.searchWarnings) })
        #expect(warnings["whole"]?.first?.contains("the whole screen") == true)
        #expect(warnings["wide"]?.first?.contains("64%") == true)
        #expect(warnings["sizes"]?.first?.contains("3 sizes") == true)
        #expect(warnings["narrow"] == [])
    }
}

@Suite("Scenario key actions")
struct ScenarioKeyActionTests {
    @Test("A key action reads its key from a parameter, and its handler is on only when the parameter is set")
    func firstKey() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scenario-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        goal: "program-ends"
        timeout: 120
        parameters:
          first-key: ""
        handlers:
          - id: "running-after-key"
            when: "running"
            if: "first-key"
            do: [{ key: "${first-key}" }, "quit"]
          - id: "running"
            when: "running"
            do: ["quit"]
        """.write(to: file, atomically: true, encoding: .utf8)
        let plain = try Scenario.load(id: "test", file: file)
        #expect(!plain.handlers[0].applies(with: plain.parameters))
        let iji = try Scenario.load(id: "test", file: file, overrides: ["first-key": "escape"])
        #expect(iji.handlers[0].applies(with: iji.parameters))
        #expect(iji.handlers[0].actions == [.key("escape"), .quit(1)])
        // Keys in the notation, checked when the scenario is loaded.
        let sequence = try Scenario.load(id: "test", file: file, overrides: ["first-key": "up return*2"])
        #expect(sequence.handlers[0].actions == [.key("up return*2"), .quit(1)])
        #expect {
            try Scenario.load(id: "test", file: file, overrides: ["first-key": "return*0"])
        } throws: { error in
            "\(error)".contains("return*0")
        }
    }
}

@Suite("Scenario sound checks")
struct ScenarioSoundTests {
    @Test("expect-sound is an action, and the wine module's sound handler is on only for a bundle that asks")
    func soundParameter() throws {
        let file = modulesRoot.appendingPathComponent("wine/scenarios/starts-and-quits.yaml")
        let quiet = try Scenario.load(id: "wine/starts-and-quits", file: file)
        let sound = try #require(quiet.handlers.first { $0.id == "sound" })
        #expect(sound.actions == [.expectSound] && sound.once)
        #expect(!sound.applies(with: quiet.parameters))
        let heard = try Scenario.load(id: "wine/starts-and-quits", file: file, overrides: ["sound": "true"])
        #expect(heard.handlers.filter { $0.applies(with: heard.parameters) }.map(\.id) == ["sound", "running"])
    }

    @Test("Icy Tower's test listens for its sound")
    func icyTower() throws {
        let test = try ProgramTest.load(bundleFolder: bundlesRoot.appendingPathComponent("freeware/icy-tower"), modulesRoot: modulesRoot)
        #expect(test.scenario.parameters["sound"] == "true")
        let on = test.scenario.handlers.filter { $0.applies(with: test.scenario.parameters) }
        #expect(on.map(\.id) == ["sound", "running"])
        #expect(on.first?.actions == [.expectSound])
        // Its first Quit asks (--wine.quit-confirm-key); the second sees it through.
        #expect(on.last?.actions == [.quit(2)])
    }

    @Test("The wine module's quit is pressed once unless a bundle says how many times; a count out of range is refused")
    func quits() throws {
        let file = modulesRoot.appendingPathComponent("wine/scenarios/starts-and-quits.yaml")
        let once = try Scenario.load(id: "wine/starts-and-quits", file: file)
        #expect(once.handlers.first { $0.id == "running" }?.actions == [.quit(1)])
        let twice = try Scenario.load(id: "wine/starts-and-quits", file: file, overrides: ["quits": "2"])
        #expect(twice.handlers.first { $0.id == "running" }?.actions == [.quit(2)])
        #expect(twice.handlers.first { $0.id == "running-after-key" }?.actions.last == .quit(2))
        #expect(throws: ScenarioError.self) { try Scenario.load(id: "wine/starts-and-quits", file: file, overrides: ["quits": "0"]) }
        #expect(throws: ScenarioError.self) { try Scenario.load(id: "wine/starts-and-quits", file: file, overrides: ["quits": "two"]) }
    }
}
