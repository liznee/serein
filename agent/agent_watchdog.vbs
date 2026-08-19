' serein Agent watchdog - boot auto-start + auto-revive
' Uses WMI to detect agent process by script path, not PID file.
' Uses pythonw.exe (no console window) for completely silent operation.
' Place shortcut to this script in shell:startup for boot-launch.
'
' Config:
'   1. agentDir defaults to script directory (agent/), no change needed
'   2. pythonwExe: read from SEREIN_PYTHONW env var, or auto-detect
'      real Python path (skips Windows Store stub)
'   3. SEREIN_BACKEND and SEREIN_HOOK_TOKEN are auto-loaded by
'      common.py from ~/.claude/settings.json, no env vars needed here
'
' IMPORTANT: This file must contain ONLY ASCII characters.
' Windows Script Host reads VBS using the system ANSI codepage (GBK
' on Chinese Windows). UTF-8 encoded Chinese/Unicode characters will
' be misinterpreted, causing line merging and runtime errors.
Option Explicit

Dim WshShell, fso, agentDir, pythonwExe
Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' -- Config --
agentDir = WshShell.Environment("Process").Item("SEREIN_AGENT_DIR")
If agentDir = "" Then
    ' Default: script directory (agent/)
    agentDir = fso.GetParentFolderName(WScript.ScriptFullName)
End If

' -- Find pythonw.exe (avoid Windows Store stub) --
pythonwExe = WshShell.Environment("Process").Item("SEREIN_PYTHONW")
If pythonwExe = "" Or Not fso.FileExists(pythonwExe) Then
    ' Check user-level env var too
    pythonwExe = WshShell.Environment("User").Item("SEREIN_PYTHONW")
End If
If pythonwExe = "" Or Not fso.FileExists(pythonwExe) Then
    ' Auto-detect: check common Python install paths (priority order)
    Dim candidates, userProfile
    userProfile = WshShell.Environment("Process").Item("USERPROFILE")
    If userProfile = "" Then
        userProfile = WshShell.ExpandEnvironmentStrings("%USERPROFILE%")
    End If
    candidates = Array( _
        userProfile & "\AppData\Local\Programs\Python\Python313\pythonw.exe", _
        userProfile & "\AppData\Local\Programs\Python\Python312\pythonw.exe", _
        userProfile & "\AppData\Local\Programs\Python\Python311\pythonw.exe", _
        "C:\Python313\pythonw.exe", _
        "C:\Python312\pythonw.exe", _
        "C:\Python311\pythonw.exe" _
    )
    Dim found, i
    found = False
    For i = 0 To UBound(candidates)
        If fso.FileExists(candidates(i)) Then
            pythonwExe = candidates(i)
            found = True
            Exit For
        End If
    Next
    ' Last resort: bare name from PATH (may hit Store stub)
    If Not found Then
        pythonwExe = "pythonw.exe"
    End If
End If

Const agentPy   = "local_agent.py"  ' relative to agentDir
Const checkSec  = 15   ' check interval (seconds)
Const enableRemoteHost = True  ' public export rewrites this to False

Dim fullAgentPy
fullAgentPy = agentDir & "\" & agentPy

' -- Launch agent (pythonw.exe, 0 = hidden window) --
Sub LaunchAgent()
    On Error Resume Next
    WshShell.CurrentDirectory = agentDir
    ' Explicitly enable RemoteHostManager so the PC registers as a remote
    ' control host and heartbeats the backend. Without this, the manager's
    ' tick() short-circuits at the enabled check and the host stays offline.
    If enableRemoteHost Then
        WshShell.Environment("Process").Item("SEREIN_REMOTE_HOST_ENABLE") = "1"
    Else
        WshShell.Environment("Process").Item("SEREIN_REMOTE_HOST_ENABLE") = "0"
    End If
    WshShell.Run """" & pythonwExe & """ """ & fullAgentPy & """", 0, False
    On Error GoTo 0
End Sub

' -- Check if agent is alive via WMI (command line contains local_agent.py) --
Function IsAgentAlive()
    Dim wmi, procs, p
    On Error Resume Next
    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    If Err.Number <> 0 Then
        IsAgentAlive = False
        On Error GoTo 0
        Exit Function
    End If
    Set procs = wmi.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name = 'pythonw.exe' OR Name = 'python.exe'")
    If Err.Number <> 0 Then
        IsAgentAlive = False
        On Error GoTo 0
        Exit Function
    End If
    For Each p In procs
        If InStr(1, p.CommandLine, "local_agent.py", 1) > 0 Then
            IsAgentAlive = True
            On Error GoTo 0
            Exit Function
        End If
    Next
    IsAgentAlive = False
    On Error GoTo 0
End Function

' -- Main loop (all errors suppressed to prevent boot popup) --
On Error Resume Next
If Not IsAgentAlive() Then
    LaunchAgent
    WScript.Sleep 6000
End If

Do While True
    If Not IsAgentAlive() Then
        LaunchAgent
        WScript.Sleep 6000
    End If
    WScript.Sleep checkSec * 1000
Loop
