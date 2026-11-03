; big-fish-directx-cancel.au3
;
; Cancels Microsoft's DirectX web setup, which the installer of each game from
; Big Fish's Game Manager starts. The games don't need it (Wine has its own
; DirectX), and it would sit on its licence page, holding up the install, for
; ever. Runs until the build stops it. See docs/big-fish.md.

Opt("WinTitleMatchMode", 2)

Func Say($msg)
    ConsoleWrite("[big-fish-directx] " & $msg & @CRLF)
EndFunc

Local $title = "Installing Microsoft(R) DirectX(R)"
While 1
    Local $window = WinGetHandle($title)
    If @error Then
        Sleep(1000)
        ContinueLoop
    EndIf
    Say("Cancelling DirectX's setup")
    ControlClick($window, "", "[TEXT:Cancel]")
    Sleep(1500)
    ; In case it asks whether to stop: its question is a window of its own.
    For $button In StringSplit("&Yes|Yes|OK", "|", 2)
        If WinExists("DirectX") Then ControlClick("DirectX", "", "[TEXT:" & $button & "]")
    Next
    Sleep(1500)
WEnd
