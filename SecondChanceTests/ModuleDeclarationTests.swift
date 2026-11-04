import Foundation
import Testing
@testable import SecondChance
import WrappBuilder

/// Each shipped module's `build:` declarations against what carries its
/// instructions out (`BuilderDeclarations`, today's builders): nothing
/// declared that isn't carried out, nothing carried out that isn't
/// declared, and no option declared that's accepted and ignored.
struct ModuleDeclarationTests {
    static let modules: [ModuleFolder] = {
        (try? ModuleLoader(root: TestPaths.repoRoot.appendingPathComponent("Modules")).loadAll().get()) ?? []
    }()

    @Test("Every shipped module's instructions are carried out, with every option they declare")
    func declaredIsCarriedOut() throws {
        try #require(!Self.modules.isEmpty)
        for module in Self.modules {
            let id = module.manifest.id
            let declared = module.declarations.instructions
            let handled = BuilderDeclarations.handled[id] ?? [:]
            #expect(Set(declared.keys) == Set(handled.keys), "\(id): declares \(declared.keys.sorted()), carried out: \(handled.keys.sorted())")
            for (name, spec) in declared {
                #expect(Set(spec.options.keys) == handled[name] ?? [],
                        "\(id).\(name): declares \(spec.options.keys.sorted()), read: \((handled[name] ?? []).sorted())")
            }
        }
    }

    @Test("Nothing is carried out for a module that isn't shipped")
    func noStrayModules() {
        let ids = Set(Self.modules.map(\.manifest.id))
        #expect(Set(BuilderDeclarations.handled.keys).isSubset(of: ids))
    }
}
