import Foundation
import Testing
@testable import WrappBuilder

struct WrappfileParserTests {
    static let example = #"""
    CONST install-dir = "C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon"
    INPUT disc-1

    # Shared set-up, as steps
    FUNCTION prefix-setup
      WINE.WINETRICKS cnc_ddraw
    END

    FROM scratch AS prefix
    USE wine@10
    DO prefix-setup

    FROM prefix AS disc
    USE nancy-drew AS nd                     # its functions are then DO nd.<name>
    WINE.MOUNT C:/discs/disc-1/ D: --cdrom
    RUN --creates="${const.install-dir}/Game.exe" \
        D:/setup.exe /s /sms /f1C:/setup.iss
    DO nd.patch --id=blue-moon-taffy-sort --into=${const.install-dir}
    WINE.REGISTRY --set HKCU\Software\Wine\Direct3D:renderer gl
    IF ${platform.arch} = "arm64"
      WINE.REGISTRY --set "HKCU\Software\Wine\Mac Driver:RetinaMode" "n"
    ELSE IF ${platform.macos}!="15"
      WINE.REGISTRY --remove "HKCU\Software\Wine\Mac Driver:RetinaMode"
    ELSE
      # nothing
    END

    FROM --module=steam@2 client AS steam
    VAR mode
    IF ${input.disc-1.id} = "disc-1"
      LAYER-HINT
        SET mode="x"
        RUN cmd /c echo $$HOME page#anchor
      END
    END
    """#

    @Test func parsesThePlansExample() throws {
        let file = try WrappfileParser.parse(Self.example)
        let globals = file.globals.compactMap(Declaration.init)
        #expect(globals.map(\.name) == ["install-dir", "disc-1"])
        #expect(globals.map(\.kind) == [.const, .input])
        #expect(globals.first?.value?.raw == "C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon")
        #expect(globals.first?.value?.quoted == true)
        #expect(file.functions.map(\.name) == ["prefix-setup"])
        #expect(file.stages.map(\.name) == ["prefix", "disc", "steam"])
        #expect(file.stages[0].from == .scratch)
        #expect(file.stages[1].from == .stage("prefix"))
        #expect(file.stages[2].from == .module(id: "steam", constraint: "2", stage: "client"))

        let disc = file.stages[1].body.flatMap(\.instructions)
        #expect(disc.map(\.keyword) == ["USE", "WINE.MOUNT", "RUN", "DO", "WINE.REGISTRY",
                                         "WINE.REGISTRY", "WINE.REGISTRY"])
        let run = disc[2]
        #expect(run.option("creates")?.value?.substitutions == ["const.install-dir"])
        #expect(run.arguments.map(\.raw) == ["D:/setup.exe", "/s", "/sms", "/f1C:/setup.iss"])
        #expect(disc[0].arguments.map(\.raw) == ["nancy-drew", "AS", "nd"])
        #expect(disc[3].moduleAlias == nil && disc[1].moduleAlias == "wine" && disc[1].name == "MOUNT")
        // A backslash is only special at the end of a line.
        #expect(disc[4].arguments.first?.raw == #"HKCU\Software\Wine\Direct3D:renderer"#)
    }

    @Test func conditionsAndBlocks() throws {
        let file = try WrappfileParser.parse(Self.example)
        guard case .conditional(let branches) = file.stages[1].body.last else {
            Issue.record("no IF")
            return
        }
        #expect(branches.map { $0.condition.map { "\($0.left.raw) \($0.comparison.rawValue) \($0.right.raw)" } } == [
            "${platform.arch} = arm64", "${platform.macos} != 15", nil,
        ])
        #expect(branches[0].condition?.right.quoted == true)
        #expect(branches[2].steps.isEmpty)
        guard case .conditional(let update) = file.stages[2].body.last,
              case .layer(let steps, _) = update.first?.steps.first else {
            Issue.record("no IF … LAYER")
            return
        }
        // $$ is a $, and a # inside a word isn't a comment.
        #expect(steps.last?.instructions.first?.arguments.map(\.raw) == ["cmd", "/c", "echo", "$$HOME", "page#anchor"])
        #expect(steps.last?.instructions.first?.arguments[3].parts == [.text("$HOME")])
        let set = try #require(steps.first?.instructions.first.flatMap(Declaration.init))
        #expect(set.kind == .set && set.name == "mode" && set.value?.raw == "x")
    }

    @Test("Declarations take = spaced or not, and INPUT its options")
    func declarations() throws {
        let file = try WrappfileParser.parse("""
        CONST a = "1"
        CONST b="2"
        CONST c= ${const.a}
        VAR d
        VAR e =${const.b}
        INPUT f --default=x --secret
        FUNCTION g
          INPUT h
          INPUT i --default="j"
          EDIT ${input.h}
        END
        FROM scratch
        """)
        let globals = file.globals.compactMap(Declaration.init)
        #expect(globals.map(\.name) == ["a", "b", "c", "d", "e", "f"])
        #expect(globals.map { $0.value?.raw } == ["1", "2", "${const.a}", nil, "${const.b}", "x"])
        #expect(globals[2].value?.lone == (try Reference.parse("const.a")))
        #expect(file.globals[5].option("secret") != nil)
        #expect(file.function(named: "g")?.parameters.map(\.name) == ["h", "i"])
    }

    @Test("A reference is a namespace and a path, with brackets for a key worked out from a value")
    func references() throws {
        let reference = try Reference.parse("self.data.patches[input.id].url")
        #expect(reference.root == "self")
        #expect(reference.plainPath == ["data", "patches"])
        #expect(reference.segments.count == 5)
        #expect(reference.description == "self.data.patches[input.id].url")
        #expect(reference.all.map(\.description) == ["self.data.patches[input.id].url", "input.id"])
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

    @Test("Keywords, module names and stage names are case-insensitive")
    func caseInsensitive() throws {
        let lower = try WrappfileParser.parse("""
        function Setup
          wine.winetricks x
        end
        from scratch as Prefix
        use wine
        if ${platform.arch}="arm64"
          wine.mount C:/x D:
        else if ${platform.macos} = "26"
          run x
        else
          layer-hint
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

    @Test(arguments: [
        ("RUN x", "line 1: RUN comes before the first FROM; only INPUT, CONST, VAR, STORE, LOCK and FUNCTION can"),
        ("FROM scratch\nIF ${platform.arch} = \"arm64\"\nRUN x", "line 2: IF has no END"),
        ("FROM scratch\nEND", "line 2: END without an IF, LAYER-HINT or FUNCTION to close"),
        ("FROM scratch\nRUN \"x", "line 2: a quote isn't closed"),
        ("FROM scratch\nRUN ${x", "line 2: a ${ isn't closed, or is empty"),
        ("FROM scratch\nIF ${a.b} = \"b\"\nELSE\nELSE IF ${c.d} = \"d\"\nEND", "line 4: nothing can follow ELSE but END"),
        ("ARG x=1", "line 1: ARG is gone: INPUT declares a value from outside, CONST a fixed one"),
        ("FROM scratch\nRUN ${x:-y}", "line 2: ${x:-y}: modifiers such as :- are gone"),
        ("FROM scratch\nRUN ${data.${id}.url}", "line 2: ${data.${id}.url}: a ${…} can't hold another"),
        ("FROM scratch\nIF arch=arm64\nEND", "line 2: arch in a condition is neither a ${…} nor a quoted string"),
        ("FROM scratch\nIF ${a.b} >= \"1\"\nEND", "line 2: a condition is <a> = <b> or <a> != <b>"),
        ("FROM scratch\nCONST x", "line 2: CONST is CONST <name> = <value>"),
    ])
    func errors(_ text: String, _ message: String) {
        #expect(throws: WrappfileError.self) { try WrappfileParser.parse(text) }
        do {
            _ = try WrappfileParser.parse(text)
        } catch {
            #expect(error.description.hasPrefix(message), "\(error.description)")
        }
    }
}
