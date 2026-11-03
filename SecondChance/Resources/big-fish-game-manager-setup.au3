; big-fish-game-manager-setup.au3 <installer exe> <bfgclient.exe it installs>
;
; Installs Big Fish's Game Manager (bfginstaller35.exe). Its /S isn't silent:
; it relaunches itself for administrator rights, and the relaunch stops on its
; licence page, a wizard titled "Big Fish Game Manager Setup". This clicks
; whichever of its buttons is live until the Game Manager is installed and the
; wizard has gone. The installer starts the Game Manager as it finishes; the
; build ends that Wine session afterwards. See docs/big-fish.md.
;
; Exits 0 once the Game Manager is installed and the wizard has closed, 1 on
; anything else.

Opt("WinTitleMatchMode", 2)

Func Say($msg)
    ConsoleWrite("[big-fish-setup] " & $msg & @CRLF)
EndFunc

Local $installer = $CmdLine[1]
Local $client = $CmdLine[2]
Local $title = "Big Fish Game Manager Setup"

Say("Starting " & $installer)
Local $pid = Run('"' & $installer & '" /S')
If $pid = 0 Then
    Say("ERROR: could not start the installer")
    Exit 1
EndIf

; The waits allow for a Mac with every core busy, where the wizard can take
; minutes to appear; the build's own timeout on this script is longer still.
Local $deadline = TimerInit()
Local $goneSince = 0
Local $seen = False
While TimerDiff($deadline) < 1500000
    If WinExists($title) Then
        If Not $seen Then Say("The setup window is showing")
        $seen = True
        $goneSince = 0
        For $button In StringSplit("I &Agree|&Next >|&Install|&Finish|&Close", "|", 2)
            If ControlCommand($title, "", "[TEXT:" & $button & "]", "IsVisible", "") = 1 _
                    And ControlCommand($title, "", "[TEXT:" & $button & "]", "IsEnabled", "") = 1 Then
                Say("Clicking " & $button)
                ControlClick($title, "", "[TEXT:" & $button & "]")
                Sleep(1500)
                ExitLoop
            EndIf
        Next
    Else
        If $goneSince = 0 Then $goneSince = TimerInit()
        If FileExists($client) And TimerDiff($goneSince) > 10000 Then
            Say("Installed: " & $client)
            Exit 0
        EndIf
        If Not FileExists($client) And TimerDiff($goneSince) > 600000 Then
            Say("ERROR: no setup window for 10 minutes, and the Game Manager isn't installed" & ($seen ? " (the window closed)" : ""))
            Exit 1
        EndIf
    EndIf
    Sleep(1000)
WEnd
Say("ERROR: timed out" & (FileExists($client) ? " (the Game Manager is there, but the setup window is still open)" : ""))
Exit 1
