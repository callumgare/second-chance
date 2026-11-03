import Foundation
import Testing
@testable import WrappFormat

/// Where a location a Wrappfile names is in a wrapp.
struct WrappLayoutTests {
    private let layout = WrappLayout(app: URL(fileURLWithPath: "/Apps/Game.app"))

    @Test("Each location type has its place in the app")
    func locations() {
        #expect(layout.location("wine:C:/Nancy Drew/Game.exe")?.path
                == "/Apps/Game.app/Contents/SharedSupport/prefix/drive_c/Nancy Drew/Game.exe")
        #expect(layout.location("dosbox:C:/TYRIAN/")?.path == "/Apps/Game.app/Contents/SharedSupport/dosbox/c/TYRIAN")
        #expect(layout.location("/SharedSupport/game/")?.path == "/Apps/Game.app/Contents/SharedSupport/game")
        #expect(layout.location("/../Icon\r")?.path == "/Apps/Game.app/Icon\r")
    }

    @Test("Nothing reaches above the app, and a type with no place in it has none")
    func outside() {
        #expect(layout.location("/../../elsewhere") == nil)
        #expect(layout.location("/a/../../../x") == nil)
        #expect(layout.location("steam://rungameid/1") == nil)
        #expect(layout.location("wine:D:/disc") == nil)
    }
}
