import Foundation
import Testing
@testable import WrappBuilder
import WrappModules

struct PathTypeTests {
    @Test("The shipped path types are sound: no name twice, none of one letter")
    func shippedTypes() {
        #expect(PathTypeRegistry.shipped.problems == [])
    }

    @Test func aTypeOfOneLetterOrTwiceIsAProblem() {
        let registry = PathTypeRegistry([
            PathType(name: "x", module: "a", roles: [.program]),
            PathType(name: "dup", module: "a", roles: [.program]),
            PathType(name: "dup", module: "b", roles: [.location]),
        ])
        #expect(registry.problems == [
            "the a module's path type x: is one letter, which reads as a drive",
            "two modules register the path type dup:",
        ])
    }

    @Test("A drive letter is never a type, and a type's prefix is")
    func splitting() {
        let registry = PathTypeRegistry.shipped
        #expect(registry.split("C:/x") == nil)
        #expect(registry.split("wine:C:/x")?.type.name == "wine")
        #expect(registry.split("wine:C:/x")?.rest == "C:/x")
        #expect(registry.split("steam://rungameid/1")?.rest == "//rungameid/1")
        #expect(PathTypeRegistry.shortForm(of: "C:/x") == .driveLetter)
        #expect(PathTypeRegistry.shortForm(of: "/SharedSupport/game/") == .folder)
        #expect(PathTypeRegistry.shortForm(of: "assets/x") == nil)
    }

    @Test("No two modules' ids differ only in case")
    func moduleIDsDifferInMoreThanCase() throws {
        let ids = try shippedModules().map(\.manifest.id)
        #expect(Set(ids.map { $0.lowercased() }).count == ids.count)
    }
}
