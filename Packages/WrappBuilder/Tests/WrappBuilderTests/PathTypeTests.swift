import Foundation
import Testing
@testable import WrappBuilder
import WrappModules

struct PathTypeTests {
    @Test("The shipped modules declare their path types, and they're sound: no name twice, none of one letter")
    func shippedTypes() throws {
        let registry = PathTypeRegistry(modules: try shippedModules())
        #expect(registry.problems == [])
        #expect(Set(registry.types.map(\.name)).isSuperset(of: ["wine", "dosbox", "scummvm", "steam", "big-fish"]))
        #expect(registry.type(named: "wine")?.module == .wine)
        // A bare /… is the core's: ScummVM's folder has no short form.
        #expect(registry.type(named: "scummvm")?.shortForm == nil)
    }

    @Test func aTypeOfOneLetterTwiceOrWithABadPatternIsAProblem() {
        let registry = PathTypeRegistry([
            PathType(name: "x", module: "a", roles: [.program]),
            PathType(name: "dup", module: "a", roles: [.program]),
            PathType(name: "dup", module: "b", roles: [.location]),
            PathType(name: "bad", module: "c", roles: [.program], shortForm: "("),
        ])
        #expect(registry.problems == [
            "the a module's path type x: is one letter, which reads as a drive",
            "the c module's path type bad:'s short form isn't a regular expression: (",
            "two modules declare the path type dup:",
        ])
    }

    @Test("A drive letter is never a type, and a type's prefix is")
    func splitting() throws {
        let registry = PathTypeRegistry(modules: try shippedModules())
        #expect(registry.split("C:/x") == nil)
        #expect(registry.split("wine:C:/x")?.type.name == "wine")
        #expect(registry.split("wine:C:/x")?.rest == "C:/x")
        #expect(registry.split("steam://rungameid/1")?.rest == "//rungameid/1")
    }

    @Test("A short form is its module's pattern on the whole path, in the type's roles")
    func shortForms() throws {
        let wine = try #require(PathTypeRegistry(modules: try shippedModules()).type(named: "wine"))
        #expect(wine.claims("C:/x", as: .location))
        #expect(wine.claims("D:\\Setup.exe", as: .program))
        #expect(wine.claims("C:", as: .location))
        #expect(!wine.claims("/SharedSupport/game/", as: .location))
        #expect(!wine.claims("assets/C:/x", as: .location))
        let programOnly = PathType(name: "stub", module: "a", roles: [.program], shortForm: "^C:/.*$")
        #expect(!programOnly.claims("C:/x", as: .location))
    }

    @Test("Of the stage's modules whose short forms claim a path, the one it used last takes it")
    func lastUseWins() throws {
        let registry = PathTypeRegistry(modules: try shippedModules())
        #expect(registry.claiming("C:/x", as: .location, among: [.wine, .dosbox])?.name == "dosbox")
        #expect(registry.claiming("C:/x", as: .location, among: [.dosbox, .wine])?.name == "wine")
        #expect(registry.claiming("C:/x", as: .location, among: [.scummvm]) == nil)
        #expect(registry.claiming("/SharedSupport/game/", as: .program, among: [.scummvm]) == nil)
    }

    @Test("No two modules' ids differ only in case")
    func moduleIDsDifferInMoreThanCase() throws {
        let ids = try shippedModules().map(\.manifest.id)
        #expect(Set(ids.map { $0.lowercased() }).count == ids.count)
    }
}
