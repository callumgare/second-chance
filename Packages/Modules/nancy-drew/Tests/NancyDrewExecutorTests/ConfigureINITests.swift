import Foundation
import Testing
@testable import NancyDrewExecutor

/// The games' .ini settings, as the module's ini.yaml has them.
struct ConfigureINITests {
    let settings = NancyDrewExecutor.Settings(
        replace: [.init(from: "WindowMode=0", to: "WindowMode=2", already: "WindowMode=2")],
        set: [.init(key: "LoadSavePath", value: #"\users\crossover\Documents"#)])

    @Test func setsLCDModeAndSavesInDocuments() throws {
        let text = "[Game]\r\nWindowMode=0\r\nLoadSavePath=C:\\Saves\r\n"
        #expect(try NancyDrewExecutor.configure(text, with: settings)
                == "[Game]\r\nWindowMode=2\r\nLoadSavePath=\\users\\crossover\\Documents\r\n")
    }

    @Test func leavesAFileWithNothingToChange() throws {
        #expect(try NancyDrewExecutor.configure("[Game]\nOther=1\n", with: settings) == "[Game]\nOther=1\n")
    }

    @Test func readsTheShippedTable() throws {
        let table = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Modules/nancy-drew/ini.yaml")
        let decoded = try YAMLDecoderShim.decode(table)
        #expect(decoded.replace?.isEmpty == false && decoded.set?.isEmpty == false)
    }
}

import Yams

enum YAMLDecoderShim {
    static func decode(_ file: URL) throws -> NancyDrewExecutor.Settings {
        try YAMLDecoder().decode(NancyDrewExecutor.Settings.self, from: String(contentsOf: file, encoding: .utf8))
    }
}
