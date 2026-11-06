import ArgumentParser
import Foundation
import PuppetProtocol

// `sc puppet controls`, `do <name> click|type|check c<n>` and `sc puppet
// autoit`: a Wine session's dialogs read and driven by their controls, as
// AutoIt sees them, each action drafting the AutoIt line that repeats it.
// See docs/dev-cli.md#wine-dialogs-and-installers.

struct PuppetControlsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "controls",
        abstract: "A Wine session's dialogs and their controls, as c1, c2… refs to click or type into.",
        discussion: """
        Lists every visible window in the session's prefix with its controls: class, \
        ClassNameNN, text, rectangle (in the window's client area) and handle, as AutoIt \
        sees them. `sc puppet do <name> click c2` then presses c2 by its handle, \
        whatever the screen shows, and `type c3 "<text>"` sets an edit control's text. \
        Only for a session started with --wine.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    @Flag(help: "Hidden controls too.") var all = false
    @Option(help: "How many controls at most.") var max: Int = 60

    func run() async throws {
        let session = try Session.start(global)
        let (puppet, setup) = try WineControls.session(name)
        let windows = try await WineControls.list(puppet, setup: setup)
        let listing = WineControls.listing(windows, all: all, max: max)
        try WineControls.saveRefs(listing.refs, in: puppet)
        listing.lines.forEach { session.ui.line($0) }
    }
}

struct PuppetAutoItCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autoit",
        abstract: "The AutoIt script the session's control actions draft: an installer's --automation, done once by hand.",
        discussion: """
        Each `do <name> click|type|check c<n>` adds a wait for its control and the \
        action, named by the window's title and the control's text (or ClassNameNN), \
        not its handle, so the script repeats it in another run. The script starts \
        the program it's given, as INSTALLER.RUN --automation gives it the installer's \
        command. Check its waits before using it.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    @Option(help: ArgumentHelp("Write it to this file instead.", valueName: "file")) var out: String?
    @Flag(help: "Forget the actions drafted so far.") var clear = false

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        let file = WineControls.draftFile(puppet)
        if clear {
            try? FileManager.default.removeItem(at: file)
            session.ui.line("\(name): drafted actions cleared.")
            return
        }
        let actions = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let script = AutoItDraft.script(session: name, actions: actions)
        if let out {
            try script.write(toFile: (out as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
            session.ui.line("Wrote \(out) (\(actions.split(separator: "\n").count) action lines).")
        } else {
            session.ui.line(script)
        }
    }
}

/// `do <name> click|type|check|uncheck c<n> …`: acting on a control by its
/// handle. nil for any other action, which `do` carries out itself.
enum PuppetControlAction {
    static func perform(verb: String, arguments: [String], puppet: PuppetSession, wait: Double) async throws -> PuppetStep? {
        guard ["click", "type", "check", "uncheck"].contains(verb), let ref = arguments.first,
              ref.range(of: #"^c\d+$"#, options: .regularExpression) != nil else { return nil }
        guard let setup = PuppetWineSetup.load(puppet) else {
            throw SCError("\(puppet.name) isn't a Wine session: c refs are for one started with --wine.")
        }
        let refs = WineControls.loadRefs(puppet)
        guard let control = refs[ref] else {
            throw SCError("No \(ref) in \(puppet.name)'s last listing.", hints: ["List them: sc puppet controls \(puppet.name)"])
        }
        let text = verb == "type" ? arguments.dropFirst().joined(separator: " ") : nil
        if verb == "type", arguments.count < 2 { throw ValidationError("type c<n> \"<text>\": the text to set.") }
        if verb != "type", arguments.count != 1 { throw ValidationError("\(verb) \(ref) takes nothing more.") }

        let before = Probe(puppet)
        let answer = try await PuppetWineChannel.runAutoIt(
            puppet, setup: setup, script: WineControls.actScript,
            arguments: [verb, String(control.window), String(control.handle), control.className] + (text.map { [$0] } ?? []))
        let result = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.hasPrefix("ok") else {
            throw SCError("\(ref) (\(control.summary)): \(WineControls.explain(result))",
                          hints: ["List them again: sc puppet controls \(puppet.name)"])
        }
        let lines = AutoItDraft.lines(verb: verb, control: control, text: text)
        try WineControls.appendDraft(lines, to: puppet)
        try await Task.sleep(for: .seconds(wait))
        let after = Probe(puppet)
        var step = PuppetOutcome.step("\(verb) \(ref) \(control.summary)", before: before, after: after)
        step.autoit = lines
        return step
    }
}

// MARK: The model

/// A top-level window in the Wine session, as AutoIt lists it.
struct WineWindow: Equatable {
    var handle: Int
    var className: String
    var title: String
    var frame: [Int]
    var active: Bool
    var controls: [WineControl]
}

/// A control in a window, with what an AutoIt script would name it by.
struct WineControl: Codable, Equatable {
    var window: Int
    var windowTitle: String
    var windowClass: String
    /// Text only this page of the window shows (its shortest visible
    /// static text), which a script waits for: a wizard keeps its title
    /// from page to page, and its Next button with it.
    var windowText: String?
    var handle: Int
    var className: String
    /// AutoIt's ClassNameNN: the class and its instance in the window.
    var classNN: String
    var text: String
    /// x, y, w, h in the window's client area.
    var frame: [Int]
    var visible: Bool
    var enabled: Bool
    /// For a check box or radio button: whether it's checked.
    var checked: Bool?
    /// Whether no other control of its class in the window has its text,
    /// so a script can name it by its text.
    var textIsUnique: Bool

    var summary: String {
        text.isEmpty ? classNN : "\(className) \"\(WineControls.short(text, 40))\""
    }
}

enum WineControls {
    static func session(_ name: String) throws -> (PuppetSession, PuppetWineSetup) {
        let puppet = try PuppetSession.load(name)
        guard puppet.isRunning else { throw SCError("\(name) has stopped: \(puppet.stopReason ?? "?").", exitCode: 4) }
        guard let setup = PuppetWineSetup.load(puppet) else {
            throw SCError("\(name) isn't a Wine session: controls are for one started with --wine <wrapp> -- <program>.")
        }
        puppet.touch()
        return (puppet, setup)
    }

    static func list(_ puppet: PuppetSession, setup: PuppetWineSetup) async throws -> [WineWindow] {
        parse(try await PuppetWineChannel.runAutoIt(puppet, setup: setup, script: listScript, arguments: []))
    }

    // MARK: Refs

    static func refsFile(_ puppet: PuppetSession) -> URL { puppet.folder.appendingPathComponent("controls.json") }
    static func draftFile(_ puppet: PuppetSession) -> URL { puppet.folder.appendingPathComponent("autoit-actions.au3") }

    static func saveRefs(_ refs: [String: WineControl], in puppet: PuppetSession) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(refs).write(to: refsFile(puppet), options: .atomic)
    }

    static func loadRefs(_ puppet: PuppetSession) -> [String: WineControl] {
        guard let data = try? Data(contentsOf: refsFile(puppet)) else { return [:] }
        return (try? JSONDecoder().decode([String: WineControl].self, from: data)) ?? [:]
    }

    static func appendDraft(_ lines: [String], to puppet: PuppetSession) throws {
        let file = draftFile(puppet)
        let text = lines.joined(separator: "\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Reading AutoIt's answer

    /// The windows and controls `listScript` wrote: a `W` line for each
    /// window, then a `C` line for each of its controls, tab-separated, with
    /// `\t`, `\n`, `\r` and `\\` escaped in text.
    static func parse(_ answer: String) -> [WineWindow] {
        var windows: [WineWindow] = []
        for line in answer.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { unescape(String($0)) }
            switch fields.first {
            case "W" where fields.count >= 6:
                windows.append(WineWindow(handle: handle(fields[1]), className: fields[2], title: fields[3],
                                          frame: numbers(fields[4]), active: fields[5] == "1", controls: []))
            case "C" where fields.count >= 9 && !windows.isEmpty:
                let window = windows[windows.count - 1]
                windows[windows.count - 1].controls.append(WineControl(
                    window: window.handle, windowTitle: window.title, windowClass: window.className,
                    handle: handle(fields[1]), className: fields[2], classNN: fields[3],
                    // A picture's static holds its resource's number, 0xFF first.
                    text: fields[4].hasPrefix("\u{FF}") ? "" : fields[4],
                    frame: numbers(fields[5]), visible: fields[6] == "1", enabled: fields[7] == "1",
                    checked: fields[8] == "" ? nil : fields[8] == "1", textIsUnique: true))
            default:
                continue
            }
        }
        for index in windows.indices {
            let controls = windows[index].controls
            let pageText = controls.filter { $0.className == "Static" && $0.visible }
                .compactMap { $0.text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).first.map { String($0).trimmingCharacters(in: .whitespaces) } }
                .filter { !$0.isEmpty }
                .min { $0.count < $1.count }
            for (position, control) in controls.enumerated() {
                windows[index].controls[position].windowText = pageText
                windows[index].controls[position].textIsUnique = !control.text.isEmpty
                    && controls.filter { $0.className == control.className && $0.text == control.text }.count == 1
            }
        }
        return windows
    }

    /// A handle as AutoIt writes one, `0x0001005C`, or a plain number.
    static func handle(_ text: String) -> Int {
        text.lowercased().hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16) ?? 0 : Int(text) ?? 0
    }

    static func numbers(_ text: String) -> [Int] {
        text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func unescape(_ text: String) -> String {
        var result = "", escaping = false
        for character in text {
            if escaping {
                switch character {
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "r": result.append("\r")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    static func hex(_ handle: Int) -> String { String(format: "0x%08X", handle) }

    static func short(_ text: String, _ length: Int) -> String {
        let flat = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return flat.count > length ? String(flat.prefix(length - 1)) + "…" : flat
    }

    /// The lines `controls` prints, and the refs they name.
    static func listing(_ windows: [WineWindow], all: Bool, max: Int) -> (lines: [String], refs: [String: WineControl]) {
        var lines: [String] = [], refs: [String: WineControl] = [:]
        var number = 0, hidden = 0, cut = 0
        if windows.isEmpty { lines.append("No windows showing in the prefix.") }
        for window in windows {
            let title = window.title.isEmpty ? "untitled" : "\"\(window.title)\""
            let frame = window.frame.count == 4 ? " at \(window.frame[0]),\(window.frame[1]) \(window.frame[2])x\(window.frame[3])" : ""
            lines.append("\(window.active ? "*" : " ") \(title) \(window.className) \(hex(window.handle))\(frame)")
            for control in window.controls {
                guard all || control.visible else {
                    hidden += 1
                    continue
                }
                guard number < max else {
                    cut += 1
                    continue
                }
                number += 1
                let ref = "c\(number)"
                refs[ref] = control
                var line = "  \(ref) \(control.className)"
                if !control.text.isEmpty { line += " \"\(short(control.text, 60))\"" }
                line += " \(control.classNN)"
                if control.frame.count == 4 { line += " at \(control.frame[0]),\(control.frame[1]) \(control.frame[2])x\(control.frame[3])" }
                if !control.visible { line += " hidden" }
                if !control.enabled { line += " disabled" }
                if let checked = control.checked { line += checked ? " checked" : " unchecked" }
                line += " \(hex(control.handle))"
                lines.append(line)
            }
        }
        if hidden > 0 { lines.append("… \(hidden) hidden (--all)") }
        if cut > 0 { lines.append("… \(cut) more (--max)") }
        return (lines, refs)
    }

    /// What `actScript` answered, other than `ok`, said plainly.
    static func explain(_ answer: String) -> String {
        switch answer.split(separator: " ").first.map(String.init) ?? "" {
        case "gone-window": return "its window has closed."
        case "gone-control": return "it has gone from its window."
        case "replaced": return "its handle is another control's now."
        case "disabled": return "it's disabled."
        case "failed": return "AutoIt couldn't act on it."
        default: return answer.isEmpty ? "AutoIt gave no answer." : answer
        }
    }

    // MARK: The scripts

    /// Lists every visible top-level window and its controls into the file
    /// named first on its command line. Built-in functions only: ClassNameNN
    /// is AutoIt's own, from WinGetClassList's order.
    static let listScript = #"""
    #NoTrayIcon
    Opt("WinDetectHiddenText", 1)
    Local $out = FileOpen($CmdLine[1], 2 + 256)
    Local $active = WinGetHandle("[ACTIVE]")
    Local $list = WinList()
    For $i = 1 To $list[0][0]
        Local $h = $list[$i][1]
        If Not BitAND(WinGetState($h), 2) Then ContinueLoop
        Local $class = ClassOf($h)
        If $class = "Progman" Or $class = "Shell_TrayWnd" Or $class = "tooltips_class32" Then ContinueLoop
        Local $pos = WinGetPos($h)
        If @error Then ContinueLoop
        Local $isActive = 0
        If $h = $active Then $isActive = 1
        FileWriteLine($out, "W" & @TAB & $h & @TAB & Clean($class) & @TAB & Clean(WinGetTitle($h)) & @TAB _
            & $pos[0] & "," & $pos[1] & "," & $pos[2] & "," & $pos[3] & @TAB & $isActive)
        Local $classes = StringSplit(StringStripWS(WinGetClassList($h), 3), @LF)
        If $classes[1] = "" Then ContinueLoop
        For $j = 1 To $classes[0]
            Local $n = 0
            For $k = 1 To $j
                If $classes[$k] = $classes[$j] Then $n += 1
            Next
            Local $nn = $classes[$j] & $n
            Local $c = ControlGetHandle($h, "", "[CLASSNN:" & $nn & "]")
            If @error Then ContinueLoop
            Local $cp = ControlGetPos($h, "", $c)
            Local $frame = ""
            If Not @error Then $frame = $cp[0] & "," & $cp[1] & "," & $cp[2] & "," & $cp[3]
            Local $checked = ""
            ; A check box or radio button: BS_CHECKBOX to BS_AUTO3STATE, or BS_AUTORADIOBUTTON.
            If $classes[$j] = "Button" And StringInStr("|2|3|4|5|6|9|", "|" & BitAND(StyleOf($c), 0xF) & "|") Then $checked = ControlCommand($h, "", $c, "IsChecked", "")
            FileWriteLine($out, "C" & @TAB & $c & @TAB & Clean($classes[$j]) & @TAB & Clean($nn) & @TAB _
                & Clean(ControlGetText($h, "", $c)) & @TAB & $frame & @TAB & ControlCommand($h, "", $c, "IsVisible", "") & @TAB _
                & ControlCommand($h, "", $c, "IsEnabled", "") & @TAB & $checked)
        Next
    Next
    FileClose($out)

    Func ClassOf($h)
        Local $r = DllCall("user32.dll", "int", "GetClassNameW", "hwnd", $h, "wstr", "", "int", 256)
        If @error Then Return ""
        Return $r[2]
    EndFunc

    Func StyleOf($h)
        Local $r = DllCall("user32.dll", "long", "GetWindowLongW", "hwnd", $h, "int", -16)
        If @error Then Return 0
        Return $r[0]
    EndFunc

    Func Clean($s)
        $s = StringReplace($s, "\", "\\")
        $s = StringReplace($s, @TAB, "\t")
        $s = StringReplace($s, @CR, "\r")
        Return StringReplace($s, @LF, "\n")
    EndFunc
    """#

    /// Acts on one control by its handle: `click`, `type <text>`, `check`
    /// or `uncheck`, after checking it's still the control listed. Answers
    /// `ok`, or why not, into the file named first.
    static let actScript = #"""
    #NoTrayIcon
    Local $out = FileOpen($CmdLine[1], 2 + 256)
    Local $verb = $CmdLine[2]
    Local $w = HWnd(Number($CmdLine[3]))
    Local $c = HWnd(Number($CmdLine[4]))
    Local $class = $CmdLine[5]
    If Not WinExists($w) Then Answer("gone-window")
    Local $isWindow = DllCall("user32.dll", "bool", "IsWindow", "hwnd", $c)
    If @error Or Not $isWindow[0] Then Answer("gone-control")
    Local $r = DllCall("user32.dll", "int", "GetClassNameW", "hwnd", $c, "wstr", "", "int", 256)
    If @error Or $r[2] <> $class Then Answer("replaced")
    If ControlCommand($w, "", $c, "IsEnabled", "") <> 1 Then Answer("disabled")
    Local $done = 0
    Switch $verb
        Case "click"
            $done = ControlClick($w, "", $c)
        Case "type"
            $done = ControlSetText($w, "", $c, $CmdLine[6])
        Case "check"
            $done = ControlCommand($w, "", $c, "Check", "")
        Case "uncheck"
            $done = ControlCommand($w, "", $c, "UnCheck", "")
    EndSwitch
    If $done Then Answer("ok")
    Answer("failed")

    Func Answer($word)
        FileWrite($out, $word)
        FileClose($out)
        Exit
    EndFunc
    """#
}

/// AutoIt lines that repeat an action on a control in another run, named by
/// what stays the same: the window's title and the control's text, or its
/// ClassNameNN.
enum AutoItDraft {
    /// An AutoIt string literal: in double quotes, each doubled inside.
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The window, by its title, or by its class when it has none.
    static func window(_ control: WineControl) -> String {
        literal(control.windowTitle.isEmpty ? "[CLASS:\(control.windowClass)]" : control.windowTitle)
    }

    /// The control, by its class and text when that's unique in its window,
    /// otherwise by its ClassNameNN. `;` is doubled in a description's text.
    static func control(_ control: WineControl) -> String {
        if control.textIsUnique, !control.text.contains("\n") {
            return literal("[CLASS:\(control.className); TEXT:\(control.text.replacingOccurrences(of: ";", with: ";;"))]")
        }
        return literal("[CLASSNN:\(control.classNN)]")
    }

    static func lines(verb: String, control target: WineControl, text: String?) -> [String] {
        let window = window(target), control = control(target), page = literal(target.windowText ?? "")
        let action = switch verb {
        case "type": "ControlSetText(\(window), \(page), \(control), \(literal(text ?? "")))"
        case "check": "ControlCommand(\(window), \(page), \(control), \"Check\", \"\")"
        case "uncheck": "ControlCommand(\(window), \(page), \(control), \"UnCheck\", \"\")"
        default: "ControlClick(\(window), \(page), \(control))"
        }
        return ["WaitControl(\(window), \(page), \(control))", action]
    }

    /// The whole script: what starts the program, the helpers the actions
    /// use, then the actions.
    static func script(session: String, actions: String) -> String {
        """
        ; Drafted by `sc puppet` from session \(session): each action done by hand, as a wait for its control on
        ; the page showing a text of its own (the page's shortest static text), then the action. Check each page's
        ; text is its own and add what tells the install has finished before using it as an INSTALLER.RUN
        ; --automation script.
        #NoTrayIcon
        Opt("WinTitleMatchMode", 1)
        Global $iPID = 0

        Func LogInfo($msg)
            ConsoleWrite(@YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & ":" & @MIN & ":" & @SEC & " " & $msg & @CRLF)
        EndFunc

        ; Wait until the window's page showing $text has the control, shown and usable, for as long as the installer runs.
        Func WaitControl($window, $text, $control)
            LogInfo("Waiting for " & $control & " in " & $window & " (" & $text & ")")
            While ControlCommand($window, $text, $control, "IsVisible", "") <> 1 Or ControlCommand($window, $text, $control, "IsEnabled", "") <> 1
                If Not ProcessExists($iPID) And Not WinExists($window) Then
                    LogInfo("ERROR: the installer ended before " & $control & " showed")
                    Exit (1)
                EndIf
                Sleep(200)
            WEnd
        EndFunc

        ; The installer's command, as the installer module builds it: the program, then its own arguments.
        Local $command = '"' & $CmdLine[1] & '"'
        For $i = 2 To $CmdLine[0]
            $command &= " " & $CmdLine[$i]
        Next
        LogInfo("Launching " & $command)
        $iPID = Run($command)

        \(actions.trimmingCharacters(in: .whitespacesAndNewlines))

        """
    }
}
