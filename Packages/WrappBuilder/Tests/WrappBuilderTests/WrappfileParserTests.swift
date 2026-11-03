import Foundation
import Testing
@testable import WrappBuilder

struct WrappfileParserTests {
    static let example = #"""
    ARG install-dir="C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon"

    # Shared set-up, as steps
    FUNCTION prefix-setup
      WINE.WINETRICKS cnc_ddraw
    END

    FROM scratch AS prefix
    USE wine@10
    DO prefix-setup

    FROM prefix AS disc
    ARG install-dir
    USE nancy-drew AS nd                     # its functions are then DO nd.<name>
    WINE.MOUNT C:/discs/disc-1/ D: --cdrom
    RUN --creates="${install-dir}/Game.exe" \
        D:/setup.exe /s /sms /f1${assets/disc.iss}
    DO nd.patch --id=blue-moon-taffy-sort --into=${install-dir}
    WINE.REGISTRY --set HKCU\Software\Wine\Direct3D:renderer gl
    IF arch=arm64
      WINE.REGISTRY --set "HKCU\Software\Wine\Mac Driver:RetinaMode" "n"
    ELSE IF macos>=26
      WINE.REGISTRY --remove "HKCU\Software\Wine\Mac Driver:RetinaMode"
    ELSE
      # nothing
    END

    FROM steam@2/client AS steam
    IF updates has taffy-patch
      LAYER
        RUN cmd /c echo $$HOME page#anchor
      END
    END
    """#

    @Test func parsesThePlansExample() throws {
        let file = try WrappfileParser.parse(Self.example)
        #expect(file.globalArgs.map(\.name) == ["install-dir"])
        #expect(file.globalArgs.first?.value?.raw == "C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon")
        #expect(file.functions.map(\.name) == ["prefix-setup"])
        #expect(file.stages.map(\.name) == ["prefix", "disc", "steam"])
        #expect(file.stages[0].from == .scratch)
        #expect(file.stages[1].from == .stage("prefix"))
        #expect(file.stages[2].from == .module(id: "steam", constraint: "2", stage: "client"))

        let disc = file.stages[1].body.flatMap(\.instructions)
        #expect(disc.map(\.keyword) == ["ARG", "USE", "WINE.MOUNT", "RUN", "DO", "WINE.REGISTRY",
                                         "WINE.REGISTRY", "WINE.REGISTRY"])
        let run = disc[3]
        #expect(run.option("creates")?.value?.substitutions == ["install-dir"])
        #expect(run.arguments.map(\.raw) == ["D:/setup.exe", "/s", "/sms", "/f1${assets/disc.iss}"])
        #expect(run.arguments[3].substitutions == ["assets/disc.iss"])
        #expect(disc[1].arguments.map(\.raw) == ["nancy-drew", "AS", "nd"])
        #expect(disc[4].moduleAlias == nil && disc[2].moduleAlias == "wine" && disc[2].name == "MOUNT")
        // A backslash is only special at the end of a line.
        #expect(disc[5].arguments.first?.raw == #"HKCU\Software\Wine\Direct3D:renderer"#)
    }

    @Test func conditionsAndBlocks() throws {
        let file = try WrappfileParser.parse(Self.example)
        guard case .conditional(let branches) = file.stages[1].body.last else {
            Issue.record("no IF")
            return
        }
        #expect(branches.map(\.condition) == [
            Condition(name: "arch", comparison: .equals, value: "arm64"),
            Condition(name: "macos", comparison: .atLeast, value: "26"),
            nil,
        ])
        #expect(branches[2].steps.isEmpty)
        guard case .conditional(let update) = file.stages[2].body.first,
              case .layer(let steps, _) = update.first?.steps.first else {
            Issue.record("no IF … LAYER")
            return
        }
        #expect(update.first?.condition == Condition(name: "updates", comparison: .has, value: "taffy-patch"))
        // $$ is a $, and a # inside a word isn't a comment.
        #expect(steps.first?.instructions.first?.arguments.map(\.raw) == ["cmd", "/c", "echo", "$$HOME", "page#anchor"])
        #expect(steps.first?.instructions.first?.arguments[3].parts == [.text("$HOME")])
    }

    @Test func nestedSubstitutions() throws {
        let file = try WrappfileParser.parse("""
        FUNCTION patch
          ARG id
          ARG into=${install-dir}
          RUN --mount=type=fetch,url=${data.patches.${id}.url},target=C:/patch.exe C:/patch.exe /s
        END
        """)
        let function = try #require(file.function(named: "patch"))
        #expect(function.parameters.map(\.name) == ["id", "into"])
        let mount = try #require(function.body.flatMap(\.instructions).last?.option("mount"))
        #expect(mount.value?.substitutions == ["data.patches.${id}.url", "id"])
        #expect(mount.fields["type"] == "fetch")
    }

    @Test("Keywords, module names and stage names are case-insensitive")
    func caseInsensitive() throws {
        let lower = try WrappfileParser.parse("""
        function Setup
          wine.winetricks x
        end
        from scratch as Prefix
        use wine
        if arch=arm64
          wine.mount C:/x D:
        else if macos>=26
          run x
        else
          layer
            Module.Wine.Registry --set k v
          end
        end
        from PREFIX AS disc
        """)
        #expect(lower.functions.map(\.name) == ["setup"])
        #expect(lower.functions.first?.body.flatMap(\.instructions).first?.keyword == "WINE.WINETRICKS")
        #expect(lower.stages.map(\.name) == ["prefix", "disc"])
        #expect(lower.stages[0].nameAsWritten == "Prefix")
        #expect(lower.stages[1].from == .stage("prefix"))
        #expect(lower.stage(named: "PREFIX") != nil)
        let instructions = lower.stages[0].body.flatMap(\.instructions)
        #expect(instructions.map(\.keyword) == ["USE", "WINE.MOUNT", "RUN", "MODULE.WINE.REGISTRY"])
        #expect(instructions[1].moduleAlias == "wine" && instructions[1].name == "MOUNT")
        #expect(instructions[3].moduleAlias == "wine" && instructions[3].name == "REGISTRY")
    }

    @Test("Quotes make one word, and \"\" inside them is a quote")
    func quoting() throws {
        let file = try WrappfileParser.parse(#"""
        FROM scratch
        RUN prog "a b" "say ""hi""" "--not-an-option"
        """#)
        let run = try #require(file.stages.first?.body.first?.instructions.first)
        #expect(run.arguments.map(\.raw) == ["prog", "a b", #"say "hi""#, "--not-an-option"])
    }

    @Test(arguments: [
        ("RUN x", "line 1: RUN comes before the first FROM; only ARG and FUNCTION can"),
        ("FROM scratch\nIF arch=arm64\nRUN x", "line 2: IF has no END"),
        ("FROM scratch\nEND", "line 2: END without an IF, LAYER or FUNCTION to close"),
        ("FROM scratch\nRUN \"x", "line 2: a quote isn't closed"),
        ("FROM scratch\nRUN ${x", "line 2: a ${ isn't closed, or is empty"),
        ("FROM scratch\nIF a=b\nELSE\nELSE IF c=d\nEND", "line 4: nothing can follow ELSE but END"),
    ])
    func errors(_ text: String, _ message: String) {
        #expect(throws: WrappfileError.self) { try WrappfileParser.parse(text) }
        do {
            _ = try WrappfileParser.parse(text)
        } catch {
            #expect(error.description == message)
        }
    }
}
