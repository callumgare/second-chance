; update-installation-wizard.au3 <patcher exe>
;
; Drives Her Interactive's later updaters (Crystal Skull's CRYUpdater1.0.1,
; Water's Edge's SAW_Updater, Trail of the Twister's TOT_Updater, Castle
; Malloy's HAU 1.1 patch, White Wolf's updater), whose window is an "Update
; Installation Wizard". It finds the game folder and patches on its own, then
; stops on a Finished page with a Close button; its Details pane lists each
; file it backed up, updated or added.
;
; Any Next/Update/Start button on the way is clicked, in case a build of the
; wizard asks first. Exits 0 once the Finished page says the update
; completed, 1 on anything else, logging the details. See
; docs/game-patches.md.

Opt("WinTitleMatchMode", 2)

Func Say($msg)
    ConsoleWrite("[update-installation-wizard] " & $msg & @CRLF)
EndFunc

Func WindowText($hWnd)
    Return StringStripWS(StringReplace(StringReplace(WinGetText($hWnd), @CRLF, " "), @LF, " "), 4)
EndFunc

Local $patcher = $CmdLine[1]
Say("Starting " & $patcher)
Local $workDir = StringLeft($patcher, StringInStr($patcher, "\", 0, -1) - 1)
Local $pid = Run('"' & $patcher & '"', $workDir)
If $pid = 0 Then
    Say("ERROR: could not start the patcher")
    Exit 1
EndIf

Local $hWnd = WinWait("[REGEXPTITLE:(?i)update]", "Update Installation Wizard", 60)
If $hWnd = 0 Then
    Say("ERROR: no Update Installation Wizard window within 60s")
    Exit 1
EndIf
Say("Window: " & WinGetTitle($hWnd))

Local $start = TimerInit()
Local $lastText = ""
While TimerDiff($start) < 150000
    If Not WinExists($hWnd) Then
        Say("ERROR: the wizard closed before its Finished page")
        Exit 1
    EndIf
    Local $text = WindowText($hWnd)
    If $text <> $lastText Then
        Say("Page: " & StringLeft($text, 300))
        $lastText = $text
    EndIf
    If StringInStr($text, "&Close") Then ExitLoop
    For $button In StringSplit("&Next >|Next >|&Next|&Update|&Start|Update|Start", "|", 2)
        If ControlCommand($hWnd, "", $button, "IsVisible", "") = 1 And ControlCommand($hWnd, "", $button, "IsEnabled", "") = 1 Then
            Say("Clicking " & $button)
            ControlClick($hWnd, "", $button)
            Sleep(1000)
            ExitLoop
        EndIf
    Next
    Sleep(500)
WEnd
If Not StringInStr($lastText, "&Close") Then
    Say("ERROR: timed out before the Finished page")
    Exit 1
EndIf

; The Details pane is what says which files changed.
ControlClick($hWnd, "", "Details...")
Sleep(1000)
Local $details = WindowText($hWnd)
Say("Details: " & $details)
ControlClick($hWnd, "", "&Close")

If StringInStr($details, "successfully updated") Or StringInStr($details, "successfuly completed") Then
    Say("Updated")
    Exit 0
EndIf
Say("ERROR: the Finished page doesn't say the update completed")
Exit 1
