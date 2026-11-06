import Foundation
import Testing
@testable import WrappFormat
import WrappModules

/// A module's answers for a test: `fake:<path>` is its `Fake/<path>` in the
/// app, and `fake:away` has no place.
private enum FakePaths: ModulePaths {
    static let typeNames = ["fake"]
    static func location(of path: String, type: String, in contents: URL) -> URL? {
        path == "away" ? nil : contents.appendingPathComponent("Fake").appendingPathComponent(path)
    }
}

/// Where a location a Wrappfile names is in a wrapp.
struct WrappLayoutTests {
    private let layout = WrappLayout(app: URL(fileURLWithPath: "/Apps/Game.app"))
    private let places = PathPlaces([FakePaths.self])

    @Test("A bare path is the core's, in the app's Contents/; a typed one is where its module says")
    func locations() {
        #expect(layout.location("/SharedSupport/game/", places: places)?.path == "/Apps/Game.app/Contents/SharedSupport/game")
        #expect(layout.location("/../Icon\r", places: places)?.path == "/Apps/Game.app/Icon\r")
        #expect(layout.location("fake:x/y", places: places)?.path == "/Apps/Game.app/Contents/Fake/x/y")
    }

    @Test("Nothing reaches above the app, and a type with no place in it, or no module, has none")
    func outside() {
        #expect(layout.location("/../../elsewhere", places: places) == nil)
        #expect(layout.location("/a/../../../x", places: places) == nil)
        #expect(layout.location("fake:away", places: places) == nil)
        #expect(layout.location("steam://rungameid/1", places: places) == nil)
        #expect(layout.location("fake:x", places: .none) == nil)
    }
}
