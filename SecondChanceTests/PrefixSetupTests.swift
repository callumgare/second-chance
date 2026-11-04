import Foundation
import Testing
@testable import SecondChance
import WrappBuilder

/// The wine module's prefix stage and cnc-ddraw function, as the app reads
/// them from its resources, and the .ini edits cnc-ddraw's settings are.
struct PrefixSetupTests {
    @Test("The app ships the wine module's prefix stage, every step of which it carries out")
    func readsTheWineModulesStage() throws {
        let steps = try WineManager.prefixStage().steps.filter { !$0.setup }
        #expect(steps.map(\.instruction) == ["DRIVES", "REGISTRY", "WINETRICKS"])
        #expect(steps.allSatisfy(ModuleSteps.handles))
        #expect(steps.compactMap { $0.option("progress") }.allSatisfy { WineManager.progressText($0) != nil })
    }

    @Test(".ini settings are set line by line, added where missing, and with --keys-must-exist named instead")
    func editsIni() {
        let text = "[ddraw]\nwindowed=false\nmaintas=false\nfullscreen=true\n"
        func edit(_ text: String, settings: [(String, String, String)], mustExist: Bool) -> (text: String, missing: [String]) {
            IniEdit.edit(text, settings: settings.map { IniEdit.Setting(section: $0.0, key: $0.1, value: $0.2) }, keysMustExist: mustExist)
        }
        let edited = edit(text, settings: [("ddraw", "windowed", "true"), ("ddraw", "maintas", "true")], mustExist: true)
        #expect(edited.text == "[ddraw]\nwindowed=true\nmaintas=true\nfullscreen=true\n")
        #expect(edited.missing.isEmpty)
        #expect(edit(text, settings: [("ddraw", "nosuchsetting", "1")], mustExist: true).missing == ["ddraw.nosuchsetting"])
        #expect(edit("[a]\nx=1\n[b]\n", settings: [("a", "y", "2"), ("c", "z", "3")], mustExist: false).text
                == "[a]\nx=1\ny=2\n[b]\n\n[c]\nz=3")
        // A Windows program's file, as cnc-ddraw's is: CRLF kept.
        let crlf = edit("; cnc-ddraw\r\n\r\n[ddraw]\r\nwindowed=false\r\nmaintas=false\r\n",
                                  settings: [("ddraw", "windowed", "true"), ("ddraw", "maintas", "true")], mustExist: true)
        #expect(crlf.missing.isEmpty)
        #expect(crlf.text == "; cnc-ddraw\r\n\r\n[ddraw]\r\nwindowed=true\r\nmaintas=true\r\n")
    }
}
