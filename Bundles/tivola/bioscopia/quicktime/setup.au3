; QuickTime 4's setup, from Bioscopia's disc 1, clicked through with its
; defaults (a Full install into Program Files (x86)\QuickTime), declining the
; README and the sample movie it offers to show at the end. Given the
; installer's path as its argument; ends once the installer has, closing
; the folder window it leaves open.
#NoTrayIcon
Opt("WinTitleMatchMode", 1)
Global $iPID = 0

Func LogInfo($msg)
    ConsoleWrite(@YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & ":" & @MIN & ":" & @SEC & " " & $msg & @CRLF)
EndFunc

; Wait until the page showing $text has the control, shown and usable, for as
; long as the installer runs.
Func WaitControl($window, $text, $control)
    LogInfo("Waiting for " & $control & " in " & $window)
    While ControlCommand($window, $text, $control, "IsVisible", "") <> 1 Or ControlCommand($window, $text, $control, "IsEnabled", "") <> 1
        If Not ProcessExists($iPID) Then
            LogInfo("ERROR: the installer ended before " & $control & " showed in " & $window)
            Exit (1)
        EndIf
        Sleep(200)
    WEnd
EndFunc

Func Press($window, $text, $control)
    WaitControl($window, $text, $control)
    ControlClick($window, $text, $control)
EndFunc

Local $command = '"' & $CmdLine[1] & '"'
For $i = 2 To $CmdLine[0]
    $command &= " " & $CmdLine[$i]
Next
LogInfo("Launching " & $command)
$iPID = Run($command)

Local $next = "[CLASS:Button; TEXT:&Next >]"
Press("QuickTime 4 Setup", "", $next)
Press("Welcome", "This program will install QuickTime 4", $next)
Press("Software License Agreement", "Please read the following License Agreement", "[CLASS:Button; TEXT:Agree]")
Press("Choose Destination Location", "Setup will install QuickTime 4 in the following directory", $next)
Press("Choose Installation Type", "Recommended for advanced users.", $next)
Press("Select Program Folder", "&Program Folder:", $next)
Press("QuickTime Plugin Options", "Setup will install the QuickTime Plugin", $next)
Press("Connection Speed", "QuickTime will choose among multiple versions", $next)
Press("Enter Registration", "Organization:", $next)
; The copying, then its last page.
Local $finished = "Click Close to complete QuickTime Setup."
WaitControl("Finished", $finished, "[CLASS:Button; TEXT:Close]")
ControlCommand("Finished", $finished, "[CLASS:Button; TEXT:Yes, I want to view the QuickTime README file.]", "UnCheck", "")
ControlCommand("Finished", $finished, "[CLASS:Button; TEXT:Yes, I want to view the Sample Movie.]", "UnCheck", "")
ControlClick("Finished", $finished, "[CLASS:Button; TEXT:Close]")
If ProcessWaitClose($iPID, 120) = 0 Then
    LogInfo("ERROR: the installer didn't end after Close")
    Exit (1)
EndIf
; Setup opens the Start menu's new QuickTime folder in a window of its own,
; which would keep the prefix's Wine running after the install: closed. It
; opens a few seconds after setup has ended.
If WinWait("[CLASS:ExplorerWClass]", "", 30) = 0 Then LogInfo("No folder window opened")
Sleep(1000)
Local $folders = WinList("[CLASS:ExplorerWClass]")
For $i = 1 To $folders[0][0]
    LogInfo("Closing the folder window " & $folders[$i][0])
    WinClose($folders[$i][1])
Next
LogInfo("QuickTime 4 installed")
Exit (0)
