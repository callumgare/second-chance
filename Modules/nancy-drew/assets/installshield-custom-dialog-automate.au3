$gameInstallerPath = $CmdLine[1]

Func LogInfo($msg)
    ConsoleWrite(@YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & ":" & @MIN & ":" & @SEC & " " & $msg & @CRLF)
EndFunc

LogInfo("Starting automation: installer=" & $gameInstallerPath)

LogInfo("Launching installer")
Local $iPID = Run('"' & $gameInstallerPath & '" /s /sms /f1C:\nancy-drew-installer\setup.iss')
LogInfo("Installer PID=" & $iPID)

; Wait for as long as the installer is running rather than a fixed time: on a busy Mac the window has taken longer
; than 20 s to appear, and giving up then left the installer waiting for ever on a click that never came.
LogInfo("Waiting for Install window to appear")
Local $hWnd = 0
While $hWnd = 0
    $hWnd = WinWait("[REGEXPTITLE:^Install ]", "", 5)
    If $hWnd = 0 And Not ProcessExists($iPID) Then
        LogInfo("ERROR: installer exited before its Install window appeared")
        Exit (1)
    EndIf
WEnd
Local $windowTitle = WinGetTitle($hWnd)
LogInfo("Window found: " & $windowTitle)

$installButtonText = $windowTitle
LogInfo("Clicking install button: " & $installButtonText)

$result = ControlClick($hWnd, "", $installButtonText)
LogInfo("ControlClick install returned: " & $result)
If $result = 0 Then
    ; The installer is waiting on the click that failed, so it would never close by itself.
    LogInfo("ERROR: failed to click install button, closing the installer")
    ProcessClose($iPID)
    Exit (1)
EndIf

; The menu with the install button is the same as the one with the exit button we have to make sure the menu has closed
; before we wait for it to appear again with the exit button. Otherwise we risk just clicking the exit button
; immediately. Wait for the install button to disappear rather than sleeping a fixed amount of time.
LogInfo("Waiting for install button to disappear")
While ControlCommand($hWnd, "", $installButtonText, "IsVisible", "") = 1
    Sleep(200)
WEnd
LogInfo("Install button disappeared")


LogInfo("Waiting for Exit Setup button to appear")
While ControlCommand($hWnd, "", "Exit Setup", "IsVisible", "") = 0
    Sleep(200)
WEnd
LogInfo("Exit Setup button appeared, clicking")
$result = ControlClick($hWnd, "", "Exit Setup")
LogInfo("ControlClick Exit Setup returned: " & $result)
ProcessWaitClose ($iPID, 60)
LogInfo("Installer process closed, exiting")