; her-update-wizard.au3 <patcher exe>
;
; Drives Her Interactive's small "Update Program" patchers (Danger on
; Deception Island's wood/C-sound fix, Shadow Ranch's full patch, …) to the
; end. Each is a wizard, window class UpdShClass, titled
; "<game> Update Program - <page>", whose pages are Welcome, Information,
; Directory (already showing the folder the patcher runs from), Confirmation
; (a Start button), and End; not every build names the page in its title. The stub unpacks and runs a second program that
; shows the wizard, so the window is found by class, not by process.
;
; Exits 0 once the End page says the game was updated, 1 on anything else,
; logging each page it sees. See docs/game-patches.md.

Opt("WinTitleMatchMode", 2)

Func Say($msg)
    ConsoleWrite("[her-update-wizard] " & $msg & @CRLF)
EndFunc

Func PageText($hWnd)
    Return StringStripWS(StringReplace(WinGetText($hWnd), @LF, " "), 4)
EndFunc

Local $patcher = $CmdLine[1]
Say("Starting " & $patcher)
Local $workDir = StringLeft($patcher, StringInStr($patcher, "\", 0, -1) - 1)
Local $pid = Run('"' & $patcher & '"', $workDir)
If $pid = 0 Then
    Fail("could not start the patcher")
EndIf

; Every visible window, for when the wizard stops changing: a message box the
; patcher raised is a separate window the main loop never looks at.
; Give up: close the patcher too, or it holds the Wine session open until the
; build's wait for it times out.
Func Fail($msg)
    Say("ERROR: " & $msg)
    If $pid <> 0 Then ProcessClose($pid)
    Exit 1
EndFunc

Func LogWindows()
    Local $windows = WinList()
    For $i = 1 To $windows[0][0]
        If $windows[$i][0] <> "" And BitAND(WinGetState($windows[$i][1]), 2) Then
            Say("Window: [" & $windows[$i][0] & "] " & StringLeft(PageText($windows[$i][1]), 500))
        EndIf
    Next
EndFunc

Func ButtonLive($hWnd, $button)
    Return ControlCommand($hWnd, "", $button, "IsVisible", "") = 1 And ControlCommand($hWnd, "", $button, "IsEnabled", "") = 1
EndFunc

; Last Train to Blue Moon Canyon's patcher stayed running after its End page
; was closed, which keeps the Wine session (and the build's wait for it)
; alive. Give it a while, log whatever windows it still shows, then close it:
; the update is done by then.
Func WaitForPatcherExit()
    If ProcessWaitClose($pid, 15) Then Return
    LogWindows()
    Say("Patcher still running 15s after its End page - closing it")
    ProcessClose($pid)
EndFunc

; Pages are told apart by their text: some builds put the page name in the
; title ("... Update Program - Welcome"), others (Message in a Haunted
; Mansion's) leave the title the same throughout.
;
; The waits allow for a machine with every core busy, where the wizard can take
; minutes to appear and seconds to turn each page; the build's own timeout on
; the patcher is longer still.
Local $deadline = TimerInit()
Local $lastText = ""
Local $changed = TimerInit()
Local $loggedStuck = False
While TimerDiff($deadline) < 600000
    Local $hWnd = WinWait("[CLASS:UpdShClass]", "", $lastText = "" ? 300 : 30)
    If $hWnd = 0 Then
        Fail("no update wizard window" & ($lastText = "" ? "" : " after the page: " & StringLeft($lastText, 120)))
    EndIf
    Local $title = WinGetTitle($hWnd)
    Local $text = PageText($hWnd)
    If $text <> $lastText Then
        Say("Page: " & $title & " | " & StringLeft($text, 300))
        $lastText = $text
        $changed = TimerInit()
        $loggedStuck = False
    ElseIf Not $loggedStuck And TimerDiff($changed) > 60000 Then
        Say("No change for 60s; the windows showing:")
        LogWindows()
        $loggedStuck = True
    EndIf

    Local $canStart = ButtonLive($hWnd, "&Start")
    Local $canNext = ButtonLive($hWnd, "&Next >")
    Local $isEnd = StringRight($title, 6) = " - End" Or (StringInStr($text, "successfully updated") And Not $canStart And Not $canNext)
    If $isEnd Then
        ControlClick($hWnd, "", "E&xit")
        If StringInStr($text, "successfully updated") Then
            Say("Updated")
            WaitForPatcherExit()
            Exit 0
        EndIf
        Fail("the End page doesn't say the game was updated")
    EndIf

    ; The Directory page's box is filled from the game's registry entry, so it
    ; is empty for a game ScummVM runs from its CD files, and the patcher
    ; would then write to the root of C:. The build always runs the patcher
    ; from the game's folder. (The Information page has an Edit1 too, holding
    ; the patch notes.)
    If StringInStr($text, "will be updated in") And ControlGetText($hWnd, "", "Edit1") <> $workDir Then
        Say("Directory was [" & ControlGetText($hWnd, "", "Edit1") & "], setting it to " & $workDir)
        ControlSetText($hWnd, "", "Edit1", $workDir)
    EndIf

    If $canStart Then
        ControlClick($hWnd, "", "&Start")
    ElseIf $canNext Then
        ControlClick($hWnd, "", "&Next >")
    Else
        ; Copying: neither button is live until the next page.
        Sleep(500)
        ContinueLoop
    EndIf
    ; Wait for the page to change before looking again.
    Local $waited = TimerInit()
    While WinExists($hWnd) And PageText($hWnd) = $text And TimerDiff($waited) < 120000
        Sleep(200)
    WEnd
WEnd
Fail("timed out on the page: " & StringLeft($lastText, 120))
