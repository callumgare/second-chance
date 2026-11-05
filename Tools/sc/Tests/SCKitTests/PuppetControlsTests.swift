import Foundation
import Testing
@testable import SCKit

/// `sc puppet controls`, acting by ref and the drafted AutoIt: reading what
/// AutoIt lists, the refs, the lines that repeat an action, and how a Wine
/// session's program is started.
struct PuppetControlsTests {
    /// What the listing script writes for a typical InstallShield page.
    static let answer = [
        "W\t0x0001005C\t#32770\tNancy Drew Setup\t312,184,503,385\t1",
        "C\t0x00010060\tButton\tButton1\t< &Back\t250,322,88,24\t1\t0\t",
        "C\t0x00010062\tButton\tButton2\t&Next >\t338,322,88,24\t1\t1\t",
        "C\t0x00010064\tButton\tButton3\tCancel\t424,322,88,24\t1\t1\t",
        "C\t0x00010066\tStatic\tStatic1\tWelcome to the\\tInstallShield\\nWizard\t10,10,300,40\t1\t1\t",
        "C\t0x00010068\tButton\tButton4\tI accept; really\t10,200,200,20\t1\t1\t1",
        "C\t0x0001006A\tStatic\tStatic2\tA hidden page's\t0,0,10,10\t0\t1\t",
        "C\t0x0001006C\tStatic\tStatic3\t\u{FF}g\t0,0,10,10\t1\t1\t",
        "C\t0x0001006E\tStatic\tStatic4\t\t0,0,10,10\t1\t1\t",
        "W\t0x00020010\tSplash\t\t0,0,640,480\t0",
    ].joined(separator: "\r\n")

    @Test func parsesWindowsAndControls() throws {
        let windows = WineControls.parse(Self.answer)
        #expect(windows.count == 2)
        let setup = try #require(windows.first)
        #expect(setup.handle == 0x1005C)
        #expect(setup.className == "#32770")
        #expect(setup.title == "Nancy Drew Setup")
        #expect(setup.frame == [312, 184, 503, 385])
        #expect(setup.active)
        #expect(setup.controls.count == 8)
        let next = setup.controls[1]
        #expect(next.handle == 0x10062)
        #expect(next.classNN == "Button2")
        #expect(next.text == "&Next >")
        #expect(next.window == 0x1005C && next.windowTitle == "Nancy Drew Setup")
        #expect(next.enabled && next.visible && next.checked == nil)
        #expect(!setup.controls[0].enabled)
        #expect(setup.controls[3].text == "Welcome to the\tInstallShield\nWizard")
        #expect(setup.controls[4].checked == true)
        #expect(windows[1].title.isEmpty && windows[1].controls.isEmpty)
        // A picture's static: its resource number isn't text.
        #expect(setup.controls[6].text.isEmpty)
        // The page's own text: its shortest visible static's first line, to a tab.
        #expect(next.windowText == "Welcome to the")
    }

    @Test func textIsUniqueOnlyWhenNoSiblingOfItsClassSharesIt() {
        let controls = WineControls.parse(Self.answer)[0].controls
        #expect(controls[1].textIsUnique)
        // Empty text never names a control.
        #expect(!controls[6].textIsUnique && !controls[7].textIsUnique)
    }

    @Test func handlesReadAsHexOrDecimal() {
        #expect(WineControls.handle("0x0001005C") == 0x1005C)
        #expect(WineControls.handle("65628") == 65628)
        #expect(WineControls.handle("nonsense") == 0)
        #expect(WineControls.hex(0x1005C) == "0x0001005C")
    }

    @Test func unescapesAutoItsEscapes() {
        #expect(WineControls.unescape(#"a\tb\nc\rd\\e"#) == "a\tb\nc\rd\\e")
    }

    @Test func listingNumbersVisibleControlsAndCountsTheRest() throws {
        let listing = WineControls.listing(WineControls.parse(Self.answer), all: false, max: 60)
        #expect(listing.refs.count == 7)
        #expect(listing.lines[0] == #"* "Nancy Drew Setup" #32770 0x0001005C at 312,184 503x385"#)
        #expect(listing.lines[1] == #"  c1 Button "< &Back" Button1 at 250,322 88x24 disabled 0x00010060"#)
        #expect(listing.lines[2] == #"  c2 Button "&Next >" Button2 at 338,322 88x24 0x00010062"#)
        #expect(listing.lines.contains(#"  c5 Button "I accept; really" Button4 at 10,200 200x20 checked 0x00010068"#))
        #expect(listing.lines.contains("  untitled Splash 0x00020010 at 0,0 640x480"))
        #expect(listing.lines.last == "… 1 hidden (--all)")
        #expect(try #require(listing.refs["c2"]).handle == 0x10062)

        let everything = WineControls.listing(WineControls.parse(Self.answer), all: true, max: 2)
        #expect(everything.refs.count == 2)
        #expect(everything.lines.last == "… 6 more (--max)")
    }

    @Test func noWindowsSaysSo() {
        #expect(WineControls.listing([], all: false, max: 60).lines == ["No windows showing in the prefix."])
    }

    @Test func draftNamesTheControlByItsTextWhenItCan() throws {
        let controls = WineControls.parse(Self.answer)[0].controls
        #expect(AutoItDraft.lines(verb: "click", control: controls[1], text: nil) == [
            #"WaitControl("Nancy Drew Setup", "Welcome to the", "[CLASS:Button; TEXT:&Next >]")"#,
            #"ControlClick("Nancy Drew Setup", "Welcome to the", "[CLASS:Button; TEXT:&Next >]")"#,
        ])
        // A ; in the text is doubled, as AutoIt's descriptions need.
        #expect(AutoItDraft.lines(verb: "check", control: controls[4], text: nil)[1]
            == #"ControlCommand("Nancy Drew Setup", "Welcome to the", "[CLASS:Button; TEXT:I accept;; really]", "Check", "")"#)
        // No text to go by: its ClassNameNN.
        #expect(AutoItDraft.control(controls[6]) == #""[CLASSNN:Static3]""#)
    }

    @Test func draftQuotesTypedTextAndUntitledWindows() {
        var edit = WineControl(window: 1, windowTitle: "", windowClass: "#32770", handle: 2, className: "Edit", classNN: "Edit1",
                               text: "", frame: [], visible: true, enabled: true, checked: nil, textIsUnique: false)
        #expect(AutoItDraft.lines(verb: "type", control: edit, text: #"C:\Games\"ND""#) == [
            #"WaitControl("[CLASS:#32770]", "", "[CLASSNN:Edit1]")"#,
            #"ControlSetText("[CLASS:#32770]", "", "[CLASSNN:Edit1]", "C:\Games\""ND""")"#,
        ])
        edit.text = "two\nlines"
        edit.textIsUnique = true
        #expect(AutoItDraft.control(edit) == #""[CLASSNN:Edit1]""#)
    }

    @Test func draftedScriptStartsTheProgramItsGivenThenActs() {
        let script = AutoItDraft.script(session: "setup", actions: "WaitControl(\"A\", \"B\")\nControlClick(\"A\", \"\", \"B\")\n")
        #expect(script.contains("$iPID = Run($command)"))
        #expect(script.contains("Func WaitControl($window, $text, $control)"))
        #expect(script.hasSuffix("ControlClick(\"A\", \"\", \"B\")\n"))
    }

    @Test func explainsWhyAnActionWasRefused() {
        #expect(WineControls.explain("gone-window") == "its window has closed.")
        #expect(WineControls.explain("disabled") == "it's disabled.")
        #expect(WineControls.explain("") == "AutoIt gave no answer.")
    }

    // MARK: Starting the program

    @Test func windowsPathsRunFromTheirOwnFolder() {
        #expect(PuppetWineSetup.isWindowsPath(#"D:\SETUP.EXE"#))
        #expect(PuppetWineSetup.isWindowsPath("c:/x.exe"))
        #expect(!PuppetWineSetup.isWindowsPath("/Volumes/ND/SETUP.EXE"))
        let run = PuppetWineSetup.wineCommand(for: [#"D:\SETUP.EXE"#, "/s"], discMount: nil)
        #expect(run.command == .wine(["start", "/wait", "/d", #"D:\"#, #"D:\SETUP.EXE"#, "/s"]))
        #expect(run.lend == nil)
        let nested = PuppetWineSetup.wineCommand(for: [#"C:\Program Files\Her\game.exe"#], discMount: nil)
        #expect(nested.command == .wine(["start", "/wait", "/d", #"C:\Program Files\Her"#, #"C:\Program Files\Her\game.exe"#]))
    }

    @Test func aMacPathOnTheDiscIsNamedByItsDrive() {
        let run = PuppetWineSetup.wineCommand(for: ["/Volumes/ND_HAUNT/Setup/SETUP.EXE"], discMount: "/Volumes/ND_HAUNT")
        #expect(run.command == .wine(["start", "/wait", "/d", #"D:\Setup"#, #"D:\Setup\SETUP.EXE"#]))
        #expect(run.lend == nil)
    }

    @Test func anyOtherMacPathHasItsFolderLent() {
        let run = PuppetWineSetup.wineCommand(for: ["/Users/Shared/x/installer.exe", "/q"], discMount: "/Volumes/ND")
        let folder = URL(fileURLWithPath: "/Users/Shared/x/installer.exe").deletingLastPathComponent()
        #expect(run.command == .start("/Users/Shared/x/installer.exe", ["/q"], unixPath: true, in: folder))
        #expect(run.lend?.path == "/Users/Shared/x")
    }

    @Test func wineOwnProgramsDontKeepASessionGoing() {
        #expect(!PuppetWineSetup.isSessionsOwn(#"C:\windows\system32\winedevice.exe"#))
        #expect(!PuppetWineSetup.isSessionsOwn(#"C:\windows\system32\Explorer.EXE"#))
        #expect(!PuppetWineSetup.isSessionsOwn(#"C:\sc-puppet\autoit\AutoIt3.exe"#))
        #expect(PuppetWineSetup.isSessionsOwn(#"D:\SETUP.EXE"#))
        #expect(PuppetWineSetup.isSessionsOwn(#"C:\users\crossover\Temp\_INS5576._MP"#))
    }

    @Test func toolsAreNamedOnC() {
        #expect(PuppetWineSetup.windowsPath(ofTool: "abc.au3") == #"C:\sc-puppet\abc.au3"#)
    }

    @Test func readsTheMountPointHdiutilGives() throws {
        let plist: [String: Any] = ["system-entities": [
            ["dev-entry": "/dev/disk9", "content-hint": "GUID_partition_scheme"],
            ["dev-entry": "/dev/disk9s1", "mount-point": "/Volumes/ND_HAUNT"],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let found = try #require(PuppetWineServer.mountPoint(plist: data))
        #expect(found.mount == "/Volumes/ND_HAUNT" && found.device == "/dev/disk9s1")
        #expect(PuppetWineServer.mountPoint(plist: Data("nope".utf8)) == nil)
    }

    @Test func resolvesAWrappItsPrefixAndNothingElse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("puppet-wine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Game.app")
        let wineBin = app.appendingPathComponent("Contents/SharedSupport/wine/bin")
        try FileManager.default.createDirectory(at: wineBin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: wineBin.appendingPathComponent("wine").path, contents: nil)
        let session = root.appendingPathComponent("session")

        let cloned = try PuppetWineSetup.resolve(wine: app.path, prefix: nil, sessionFolder: session)
        #expect(cloned.wrapp.path == app.path && cloned.prefix.path == session.appendingPathComponent("prefix").path && cloned.owns)

        let given = try PuppetWineSetup.resolve(wine: app.path, prefix: root.appendingPathComponent("p").path, sessionFolder: session)
        #expect(given.prefix.lastPathComponent == "p" && !given.owns)

        let ownPrefix = app.appendingPathComponent("Contents/SharedSupport/prefix")
        let inPlace = try PuppetWineSetup.resolve(wine: ownPrefix.path, prefix: nil, sessionFolder: session)
        #expect(inPlace.wrapp.path == app.path && inPlace.prefix.path == ownPrefix.path && !inPlace.owns)

        #expect(throws: SCError.self) { try PuppetWineSetup.resolve(wine: root.path, prefix: nil, sessionFolder: session) }
    }

    @Test func setupRoundTripsThroughItsFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("puppet-wine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let setup = PuppetWineSetup(wrapp: "/a.app", prefix: "/p", ownsPrefix: true, command: [#"D:\SETUP.EXE"#],
                                    autoIt: "/autoit", disc: "/d.iso", discMount: "/Volumes/D", discDevice: "/dev/disk9")
        try setup.save(in: folder)
        let read = try JSONDecoder().decode(PuppetWineSetup.self, from: Data(contentsOf: PuppetWineSetup.file(folder)))
        #expect(read == setup)
        #expect(setup.tools.path == "/p/drive_c/sc-puppet")
    }
}
