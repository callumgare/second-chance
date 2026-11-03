import Foundation
import Testing
@testable import WrappBuilder

struct ManifestQueryTests {
    private let document: Any = [
        "series": "Nancy Drew",
        "series-order": 13,
        "notes": ["installer": "installshield"],
        "editions": [
            ["id": "cd", "source": "disc"],
            ["id": "steam", "source": "steam"],
        ],
    ] as [String: Any]

    @Test(arguments: [
        ("series=Nancy Drew", true),
        ("series=Hardy Boys", false),
        ("series-order=13", true),
        ("notes.installer=installshield", true),
        ("notes.installer=inno", false),
        ("editions.source=steam", true),
        ("editions.source=download", false),
        ("missing.path=x", false),
    ])
    func matches(_ query: String, _ expected: Bool) throws {
        #expect(try #require(ManifestQuery(query)).matches(document) == expected)
    }

    @Test func needsAPathAndAnEquals() {
        #expect(ManifestQuery("series") == nil)
        #expect(ManifestQuery("=x") == nil)
    }
}
