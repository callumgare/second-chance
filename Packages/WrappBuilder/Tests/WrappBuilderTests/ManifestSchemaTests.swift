import Foundation
import Testing
@testable import WrappBuilder

/// The YAML pitfalls J1 found, each one hand edit to a valid manifest, read
/// as YAML 1.2 and checked against the schema.
struct ManifestSchemaTests {
    private static let valid = """
    format: 1
    id: "nancy-drew/old-clock"
    version: 1
    title: "Secret of the Old Clock"
    editions:
      - id: "cd"
        source: "disc"
        build:
          target: "disc"
          inputs:
            disc-1: { type: "disc" }
      - id: "steam"
        source: "steam"
        build:
          target: "steam"
          inputs:
            game: { type: "steam-game", app-id: 31880, common-folder: "Old Clock" }
            launch-mode: { type: "choice", options: ["direct", "steam"], default: "direct", prompt: "How should the game start?" }
        notes:
          drm: "no"
    notes:
      anything: [goes, here, yes, 10.10]

    """

    private func problems(_ yaml: String) throws -> [String] {
        let validator = try SchemaValidator()
        try validator.addSchema(Data(contentsOf: bundlesRoot.appendingPathComponent("manifest.schema.json")))
        let document = try YAML12.load(yaml)
        return try validator.problems(with: document, against: ProgramBundle.manifestSchemaID).map(\.description)
    }

    @Test func aValidManifestPasses() throws {
        #expect(try problems(Self.valid) == [])
    }

    @Test(arguments: [
        // A bare no is the text "no" in YAML 1.2, as the editor reads it
        ("drm: \"no\"", "drm: no", nil),
        // an edition's notes are anything, but drm is a note now, not a field
        ("    notes:\n      drm: \"no\"", "    drm: \"no\"", "/editions/1: drm isn't something this can have"),
        // the program Steam starts is the launch's, not the input's
        ("common-folder: \"Old Clock\" }", "common-folder: \"Old Clock\", exe: \"Game.exe\" }", "/editions/1/build/inputs/game: exe isn't something this can have"),
        // and yes, on and off are words too
        ("title: \"Secret of the Old Clock\"", "title: off", nil),
        // but true is a boolean, which a title can't be
        ("title: \"Secret of the Old Clock\"", "title: true", "/title: must be text, in quotes"),
        // a version-like name reads as a number
        ("common-folder: \"Old Clock\"", "common-folder: 10.10", "/editions/1/build/inputs/game/common-folder: must be text, in quotes"),
        // a quoted number isn't a number
        ("app-id: 31880", "app-id: \"31880\"", "/editions/1/build/inputs/game/app-id: must be a whole number"),
        // a mistyped key is caught, not dropped
        ("    notes:", "    ntoes:", "/editions/1: ntoes isn't something this can have; is it mistyped?"),
        // a value from the wrong list
        ("source: \"disc\"", "source: \"cdrom\"", "/editions/0/source: must be one of: disc, her-download, steam, big-fish, download"),
        // a Steam field on a disc
        ("disc-1: { type: \"disc\" }", "disc-1: { type: \"disc\", app-id: 1 }", "/editions/0/build/inputs/disc-1"),
        // an input of no type there is
        ("disc-1: { type: \"disc\" }", "disc-1: { type: \"cd\" }", "/editions/0/build/inputs/disc-1"),
        // choices are inputs now
        ("    notes:", "    choices: {}\n    notes:", "/editions/1: choices isn't something this can have"),
        // the id needs a namespace
        ("id: \"nancy-drew/old-clock\"", "id: \"old-clock\"", "/id: isn't written as it should be"),
    ] as [(String, String, String?)])
    func aHandEdit(from original: String, to edit: String, expecting problem: String?) throws {
        #expect(Self.valid.contains(original))
        let found = try problems(Self.valid.replacingOccurrences(of: original, with: edit))
        if let problem {
            #expect(found.contains { $0.hasPrefix(problem) }, "\(found)")
        } else {
            #expect(found == [])
        }
    }

    @Test func aKeyGivenTwiceIsRefused() throws {
        #expect(throws: YAML12.Error.self) {
            try YAML12.load("title: \"A\"\ntitle: \"B\"\n")
        }
    }

    @Test func plainValuesAreReadAsYAML12Does() throws {
        let document = try #require(try YAML12.load("""
        words: [yes, no, on, off, y, n]
        booleans: [true, false, True]
        nulls: [~, null, ]
        numbers: [12, -3, 0x1F, 0o17, 1.5, 1e3, .inf]
        version: 10.10
        quoted: ["true", "12"]
        """) as? [String: Any])
        #expect(document["words"] as? [String] == ["yes", "no", "on", "off", "y", "n"])
        #expect(document["booleans"] as? [Bool] == [true, false, true])
        #expect((document["nulls"] as? [Any])?.allSatisfy { $0 is NSNull } == true)
        #expect(document["numbers"].flatMap { $0 as? [Any] }?.map { ($0 as? NSNumber)?.doubleValue } == [12, -3, 31, 15, 1.5, 1000, .infinity])
        #expect(document["numbers"].flatMap { $0 as? [Any] }?.prefix(4).allSatisfy { $0 is Int } == true)
        #expect(document["version"] as? Double == 10.1)
        #expect(document["quoted"] as? [String] == ["true", "12"])
    }
}
