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

Global $pid = 0

Func Say($msg)
    ConsoleWrite("[update-installation-wizard] " & $msg & @CRLF)
EndFunc

Func WindowText($hWnd)
    Return StringStripWS(StringReplace(StringReplace(WinGetText($hWnd), @CRLF, " "), @LF, " "), 4)
EndFunc

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
            Say("Window: [" & $windows[$i][0] & "] " & StringLeft(WindowText($windows[$i][1]), 500))
        EndIf
    Next
EndFunc

Local $patcher = $CmdLine[1]
Say("Starting " & $patcher)
Local $workDir = StringLeft($patcher, StringInStr($patcher, "\", 0, -1) - 1)
$pid = Run('"' & $patcher & '"', $workDir)
If $pid = 0 Then
    Fail("could not start the patcher")
EndIf

; The waits allow for a machine with every core busy, where the wizard can take
; minutes to appear; the build's own timeout on the patcher is longer still.
Local $hWnd = WinWait("[REGEXPTITLE:(?i)update]", "Update Installation Wizard", 300)
If $hWnd = 0 Then
    Fail("no Update Installation Wizard window within 300s")
EndIf
Say("Window: " & WinGetTitle($hWnd))

Local $start = TimerInit()
Local $lastText = ""
Local $changed = TimerInit()
Local $loggedStuck = False
While TimerDiff($start) < 600000
    If Not WinExists($hWnd) Then
        Fail("the wizard closed before its Finished page")
    EndIf
    Local $text = WindowText($hWnd)
    If $text <> $lastText Then
        Say("Page: " & StringLeft($text, 300))
        $lastText = $text
        $changed = TimerInit()
        $loggedStuck = False
    ElseIf Not $loggedStuck And TimerDiff($changed) > 60000 Then
        Say("No change for 60s; the windows showing:")
        LogWindows()
        $loggedStuck = True
    EndIf
    If StringInStr($text, "&Close") Then ExitLoop
    ; Castle Malloy's CD updater asks for the game folder, and finds no
    ; registry entry to fill it from ('Folder "(null)" doesn't exist'). The
    ; build always runs the patcher from the game's folder.
    If StringInStr($text, "Select application folder") And ControlGetText($hWnd, "", "obj_EDIT1") <> $workDir Then
        Say("Folder was [" & ControlGetText($hWnd, "", "obj_EDIT1") & "], setting it to " & $workDir)
        ControlSetText($hWnd, "", "obj_EDIT1", $workDir)
    EndIf
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
    Fail("timed out before the Finished page")
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
Fail("the Finished page doesn't say the update completed")
