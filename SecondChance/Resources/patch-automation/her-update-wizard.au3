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
    Say("ERROR: could not start the patcher")
    Exit 1
EndIf

Func ButtonLive($hWnd, $button)
    Return ControlCommand($hWnd, "", $button, "IsVisible", "") = 1 And ControlCommand($hWnd, "", $button, "IsEnabled", "") = 1
EndFunc

; Pages are told apart by their text: some builds put the page name in the
; title ("... Update Program - Welcome"), others (Message in a Haunted
; Mansion's) leave the title the same throughout.
Local $deadline = TimerInit()
Local $lastText = ""
While TimerDiff($deadline) < 150000
    Local $hWnd = WinWait("[CLASS:UpdShClass]", "", 5)
    If $hWnd = 0 Then
        Say("ERROR: no update wizard window" & ($lastText = "" ? "" : " after the page: " & StringLeft($lastText, 120)))
        Exit 1
    EndIf
    Local $title = WinGetTitle($hWnd)
    Local $text = PageText($hWnd)
    If $text <> $lastText Then
        Say("Page: " & $title & " | " & StringLeft($text, 300))
        $lastText = $text
    EndIf

    Local $canStart = ButtonLive($hWnd, "&Start")
    Local $canNext = ButtonLive($hWnd, "&Next >")
    Local $isEnd = StringRight($title, 6) = " - End" Or (StringInStr($text, "successfully updated") And Not $canStart And Not $canNext)
    If $isEnd Then
        ControlClick($hWnd, "", "E&xit")
        If StringInStr($text, "successfully updated") Then
            Say("Updated")
            Exit 0
        EndIf
        Say("ERROR: the End page doesn't say the game was updated")
        Exit 1
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
    While WinExists($hWnd) And PageText($hWnd) = $text And TimerDiff($waited) < 20000
        Sleep(200)
    WEnd
WEnd
Say("ERROR: timed out on the page: " & StringLeft($lastText, 120))
Exit 1
