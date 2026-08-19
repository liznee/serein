' serein LLM 代理开机自启脚本
' 路由: OpenCode GO (glm-5.2) 优先, DeepSeek 兜底
' 放在 Windows Startup 文件夹, 登录后自动静默启动

Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' 从 ~/.claude/settings.json 读取密钥
settingsPath = WshShell.ExpandEnvironmentStrings("%USERPROFILE%\.claude\settings.json")
If Not fso.FileExists(settingsPath) Then
    WScript.Quit 1
End If

Set f = fso.OpenTextFile(settingsPath, 1, False, -1)
content = f.ReadAll()
f.Close

Function ExtractKey(text, keyName)
    Dim pos, startQuote, endQuote
    pos = InStr(text, keyName)
    If pos = 0 Then
        ExtractKey = ""
        Exit Function
    End If
    startQuote = InStr(pos, text, ":")
    startQuote = InStr(startQuote, text, """") + 1
    endQuote = InStr(startQuote, text, """")
    ExtractKey = Mid(text, startQuote, endQuote - startQuote)
End Function

openkeyCode = ExtractKey(content, "OPENCODE_GO_API_KEY")
deepseekCode = ExtractKey(content, "DEEPSEEK_API_KEY")

If openkeyCode = "" Or deepseekCode = "" Then
    WScript.Quit 1
End If

projectRoot = WshShell.ExpandEnvironmentStrings("%SEREIN_PROJECT_ROOT%")
If projectRoot = "%SEREIN_PROJECT_ROOT%" Or projectRoot = "" Then projectRoot = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
configPath = fso.BuildPath(projectRoot, "deploy\litellm-fallback.yaml")
litellmExe = WshShell.ExpandEnvironmentStrings("%SEREIN_LITELLM_EXE%")
If litellmExe = "%SEREIN_LITELLM_EXE%" Or litellmExe = "" Then litellmExe = "litellm.exe"

' 设置环境变量后静默启动 litellm (0=隐藏窗口, False=不等待)
Set env = WshShell.Environment("Process")
env.Item("OPENCODE_GO_API_KEY") = openkeyCode
env.Item("DEEPSEEK_API_KEY") = deepseekCode

' 用 cmd /c start 启动, 隐藏窗口
cmdLine = "cmd /c set OPENCODE_GO_API_KEY=" & openkeyCode & _
          " && set DEEPSEEK_API_KEY=" & deepseekCode & _
          " && start """" /B """ & litellmExe & """ --config """ & configPath & """ --host 127.0.0.1 --port 4000"

WshShell.Run cmdLine, 0, False
