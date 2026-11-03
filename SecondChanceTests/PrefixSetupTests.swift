import Foundation
import Testing
@testable import SecondChance
import WrappBuilder

/// The wine module's prefix set-up, as the app reads it from its resources.
struct PrefixSetupTests {
    @Test("The app ships the wine module, and its set-up is today's, in order")
    func readsTheWineModulesSetUp() throws {
        let steps = try WineManager.prefixSetup().setup
        #expect(steps.map { $0.registry?.name ?? $0.winetricks ?? ($0.ddrawIni == nil ? "?" : "ddraw.ini") }
                == ["EmulateModeset", "cnc_ddraw", "ddraw.ini", "isolate_home"])
        #expect(steps.compactMap(\.progress).allSatisfy { WineManager.progressText($0) != nil })
        #expect(steps.first { $0.ddrawIni != nil }?.ddrawIni == ["maintas": "true", "windowed": "true"])
    }

    @Test("cnc-ddraw's settings are set line by line, and a missing one says so")
    func configuresDdrawIni() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ddraw-\(UUID().uuidString).ini")
        defer { try? FileManager.default.removeItem(at: file) }
        try "[ddraw]\nwindowed=false\nmaintas=false\nfullscreen=true\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(WineManager.configureDdrawIni(file, settings: ["windowed": "true", "maintas": "true"]))
        #expect(try String(contentsOf: file, encoding: .utf8) == "[ddraw]\nwindowed=true\nmaintas=true\nfullscreen=true\n")
        #expect(!WineManager.configureDdrawIni(file, settings: ["nosuchsetting": "1"]))
    }
}
