import BasiliskKit
import Foundation
import Testing
import WrappModules

struct BasiliskPathsTests {
    @Test("A basilisk: path is on the emulated Mac: no place in the app, named by its disk")
    func paths() {
        let places = PathPlaces([BasiliskPaths.self])
        #expect(places.split("basilisk:Ingenious CD:Ingenious")?.rest == "Ingenious CD:Ingenious")
        #expect(BasiliskPaths.location(of: "Ingenious CD:Ingenious", type: "basilisk", in: URL(fileURLWithPath: "/tmp")) == nil)
        #expect(places.describe("basilisk:Ingenious CD:Ingenious") == "Ingenious, on the game's Mac's disk Ingenious CD")
        #expect(places.legacyProgramPath(of: "basilisk:Ingenious CD:Ingenious") == nil)
    }
}
