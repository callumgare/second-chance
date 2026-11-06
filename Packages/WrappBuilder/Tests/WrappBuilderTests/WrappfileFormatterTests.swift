import Foundation
import Testing
@testable import WrappBuilder

/// `wrapp-builder fmt`: the one style, losing nothing, and `--migrate`'s
/// rewrites of syntax that has changed.
struct WrappfileFormatterTests {
    @Test("Blocks are indented, keywords upper-cased, continuations and comments kept")
    func formats() {
        let text = """
        input disc-1
        function patch
        if ${input.disc-1} = "x"
        # a comment, its text as it is
        run --name=x \\
        C:/a.exe   # after the code
        end
        end


        from scratch as x
        DO patch
        """
        #expect(WrappfileFormatter.format(text) == """
        INPUT disc-1
        FUNCTION patch
          IF ${input.disc-1} = "x"
            # a comment, its text as it is
            RUN --name=x \\
                C:/a.exe   # after the code
          END
        END

        FROM scratch as x
        DO patch

        """)
    }

    @Test("A stage's comments come with it, after one blank line")
    func stagesAreSpaced() {
        let text = "FROM scratch AS a\nRUN C:/a.exe\n# the next\nFROM a AS b\n"
        #expect(WrappfileFormatter.format(text) == "FROM scratch AS a\nRUN C:/a.exe\n\n# the next\nFROM a AS b\n")
    }

    @Test("Migrating rewrites what has changed, in code and never in comments")
    func migrates() {
        let text = """
        FROM wine@10/prefix AS prefix   # FROM wine@10/prefix
        COPY module:nancy-drew/assets/x.icns /Resources/x.icns
        ICON /Resources/x.icns
        EDIT C:/a.ini --must-exist --ini=a.b=c
        """
        #expect(WrappfileFormatter.format(text, migrate: true) == """
        FROM --module=wine@10 prefix AS prefix   # FROM wine@10/prefix
        COPY module:nancy-drew:/assets/x.icns /Resources/x.icns
        APP --icon=/Resources/x.icns
        EDIT C:/a.ini --keys-must-exist --ini=a.b=c

        """)
    }

    @Test("A bare LAUNCH /… in a stage that uses scummvm, or is built from one that does, becomes scummvm:/…")
    func migratesScummVMLaunches() {
        let text = """
        FROM scratch AS scummvm
        USE scummvm
        LAUNCH --mount=type=store,source=s,target=scummvm:saves/
        LAUNCH /SharedSupport/game/ nancy:nancy6

        FROM scummvm AS disc
        LAUNCH /SharedSupport/game/ nancy:nancy6

        FROM scratch AS other
        LAUNCH /MacOS/tool
        """
        #expect(WrappfileFormatter.format(text, migrate: true) == """
        FROM scratch AS scummvm
        USE scummvm
        LAUNCH --mount=type=store,source=s,target=scummvm:saves/
        LAUNCH scummvm:/SharedSupport/game/ nancy:nancy6

        FROM scummvm AS disc
        LAUNCH scummvm:/SharedSupport/game/ nancy:nancy6

        FROM scratch AS other
        LAUNCH /MacOS/tool

        """)
    }

    @Test("Every shipped Wrappfile is formatted and migrated, and parses the same as written")
    func shippedAreFormatted() throws {
        var files: [URL] = []
        for root in ["Bundles", "Modules"] {
            let walk = FileManager.default.enumerator(at: repoRoot.appendingPathComponent(root), includingPropertiesForKeys: nil)
            while let file = walk?.nextObject() as? URL {
                let parent = file.deletingLastPathComponent().lastPathComponent
                if file.lastPathComponent == "Wrappfile" || (["stages", "functions"].contains(parent) && file.pathExtension.isEmpty) {
                    files.append(file)
                }
            }
        }
        try #require(files.count > 30)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(WrappfileFormatter.format(text, migrate: true) == text, "\(file.path) isn't formatted")
        }
    }
}
