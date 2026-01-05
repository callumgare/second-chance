$gameInstallerPath = $CmdLine[1]
$gameTitle = $CmdLine[2]

Local $iPID = Run('"' & $gameInstallerPath & '" /s /sms /f1C:\nancy-drew-installer\setup.iss')

Local $hWnd = WinWait("[REGEXPTITLE:^Install ]", "", 20)
Local $windowTitle = WinGetTitle($hWnd)

$installButtonText = $windowTitle

$result = ControlClick($hWnd, "", $installButtonText)
If $result = 0 Then
    ProcessWaitClose($iPID)
    Exit (1)
EndIf

sleep(1000)

WinWaitActive($hWnd, "", 300)
ControlClick($hWnd, "", "Exit Setup")
ProcessWaitClose ($iPID, 60)