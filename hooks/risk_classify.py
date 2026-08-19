"""风险分级器 —— hook 本地静态分级。

与后端 backend/internal/risk/engine.go 的静态规则镜像。
不包含会话记忆 / 白名单（那些由后端动态判断，hook 本地无状态无法查 DB）。

优先级：黑名单(本地高危) > 红规则 > 黄规则 > 绿规则 > 默认黄
返回 level: green / yellow / red

ReDoS 防护：命令长度上限 4096 字节，所有正则模块加载时预编译。
"""
import re

# 只读工具，直接绿（即使触发 hook 也安全放行）
# 覆盖所有 Claude Code / CatPaw 只读工具，避免遗漏
GREEN_TOOLS = {
    # Claude Code 标准只读工具
    "Read", "Glob", "Grep", "LS",
    "WebSearch", "WebFetch",
    "TodoWrite", "TaskList", "TaskGet", "TaskOutput",
    # CatPaw / 扩展只读工具
    "list_dir", "search", "codebase_search", "read_file",
    "web_fetch", "glob_file_search", "fetch_rules", "read_lints",
    "AskQuestion", "SpecAskQuestion",
}

# 文件编辑工具，黄（可 git 回滚，可逆）
# 覆盖所有编辑/写入类工具
YELLOW_TOOLS = {
    "Edit", "Write", "NotebookEdit", "MultiEdit",
    "string_replace",  # CatPaw 字符串替换
}

# 绿色命令（只读 / 无副作用）
GREEN_PATTERNS = [
    (r'^(ls|ll|la|cat|pwd|echo|whoami|date|dir|cd|cls|clear|true)\b', "只读命令"),
    (r'^git (status|log|diff|show|branch|stash list|remote -v|config --get)\b', "git 只读"),
    (r'^(go test|go build|go vet|go fmt|go list|go mod|go env|go version|go doc)\b', "go 构建/测试"),
    (r'^(npm run|npx|yarn|pnpm) (build|test|lint|dev|start|run|ci)\b', "npm 构建/测试"),
    (r'^(grep|rg|find|fd|where|which|tree|head|tail|less|more|wc|sort|uniq)\b', "搜索/查看命令"),
    (r'^(python|python3|py|node|go|java|rustc|gcc|flutter|dart) --version\b', "版本查询"),
    (r'^(docker|kubectl) (ps|logs|get|describe|top|version|info)\b', "容器只读"),
    (r'^(pytest|go test|jest|vitest|cargo test)\b', "运行测试"),
    # PowerShell 只读 cmdlet
    (r'^(Get-Content|Get-ChildItem|Get-Item|Get-Location|Get-Process|Get-Service|Get-Date|Get-Variable|Get-Module|Get-Command|Get-Member|Get-Property)\b', "PowerShell 只读"),
    (r'^(Write-Output|Write-Host|Write-Verbose|Out-Default|Out-Host|Out-String|Out-Null)\b', "PowerShell 输出"),
    (r'^(Select-String|Select-Object|Where-Object|ForEach-Object|Sort-Object|Measure-Object|Format-Table|Format-List|Format-Wide)\b', "PowerShell 查询/格式化"),
    (r'^(Test-Path|Test-Connection|Resolve-Path|Show-Command)\b', "PowerShell 测试/诊断"),
]

# 黄色命令（可逆 / 本地变更 / 本地安装）
YELLOW_PATTERNS = [
    (r'^git (add|commit|stash|checkout|switch|merge|rebase|reset)\b', "git 本地操作"),
    (r'^npm install\b(?!.*(\s-g\b|--global\b))', "npm 本地安装"),
    (r'^(pip|pip3) install\b(?!.*(\s-g\b|--global\b))', "pip 本地安装"),
    (r'^(mkdir|touch|cp|mv|ln|sed|awk)\b', "文件操作(可逆)"),
    (r'^go (get|install|mod tidy|mod download)\b', "go 依赖安装"),
    (r'^(docker|kubectl) (run|exec|build|start|stop|restart|create)\b', "容器本地操作"),
    (r'^(make|cmake|cargo build)\b', "本地构建"),
    # PowerShell 可逆操作
    (r'^(Set-Content|Add-Content|Clear-Content|New-Item|Copy-Item|Move-Item|Rename-Item|Out-File)\b', "PowerShell 文件操作(可逆)"),
    (r'^(Set-Variable|Set-Location|Set-Item)\b', "PowerShell 环境设置"),
    (r'^(Install-Module|Install-Package|Install-Script)\b(?!.*-(?:AllUsers|Scope\s+AllUsers))', "PowerShell 本地安装"),
]

# 红色命令（不可逆 / 外发 / 系统级）
RED_PATTERNS = [
    (r'\brm\b.*\s-[^-]*[rf]', "递归/强制删除"),
    (r'^del\s+/[sSfFqQ]', "Windows 递归删除"),
    (r'Remove-Item.*(-Recurse|-Force)', "PowerShell 递归/强制删除"),
    (r'^(format|dd|mkfs|diskpart|fdisk)\b', "磁盘格式化/写"),
    (r'^git (push|fetch|pull)\b', "git 外发"),
    (r'^(scp|rsync|sftp)\b', "远程文件传输"),
    (r'^(sudo|runas|doas)\b', "提权执行"),
    (r'\breg (add|delete|import|load|save)\b', "注册表修改"),
    (r'\bsetx\b', "环境变量持久化"),
    (r'^npm install\b.*(\s-g\b|--global\b)', "系统级 npm 安装"),
    (r'^(pip|pip3) install\b.*(\s-g\b|--global\b)', "系统级 pip 安装"),
    (r'^(shutdown|reboot|halt|poweroff)\b', "关机/重启"),
    (r':\(\)\s*\{\s*:\|:&\s*\}\s*;', "fork bomb"),
    (r'(?<![0-9])>(>?)\s*\S', "文件重定向覆盖/追加"),
    (r'^(curl|wget|Invoke-WebRequest)\b.*(-X\s*(POST|PUT|DELETE|PATCH)|--upload-file|--data|-d\b|-T\b|--post)', "HTTP 写/上传"),
    (r'chmod\s+0?777\b', "过度开放权限"),
    (r'^crontab\b', "定时任务修改"),
    (r'^(systemctl|service)\s+(start|stop|restart|reload|enable|disable)\b', "系统服务控制"),
    # PowerShell 高危操作
    (r'^(Invoke-Expression|iex)\b', "PowerShell 动态执行(注入风险)"),
    (r'^(Start-Process)\b', "PowerShell 启动进程"),
    (r'^(Stop-Process|Stop-Service|Stop-Computer)\b', "PowerShell 停止进程/服务"),
    (r'^(Restart-Computer|Restart-Service)\b', "PowerShell 重启"),
    (r'^(Set-ExecutionPolicy)\b', "PowerShell 修改执行策略"),
    (r'^Install-Module\b.*-(?:AllUsers|Scope\s+AllUsers)', "PowerShell 全局模块安装"),
    (r'^(Remove-Item)\b', "PowerShell 删除"),
    (r'^(New-Service|Set-Service)\b', "PowerShell 系统服务修改"),
    (r'^(Export-Clixml|Export-Csv|Export-FormatData)\b.*-NoTypeInformation', "PowerShell 导出数据"),
    (r'^(Clear-Item|Clear-ItemProperty)\b', "PowerShell 清除项"),
]

# 本地黑名单（绝对高危，永远 red，后端也不可豁免）
# 注意：精确匹配根目录/家目录，避免误伤 rm -rf /tmp 这类普通目录
BLACKLIST_LOCAL = [
    (r'\brm\s+-rf?\s+/\s*$', "rm -rf 根目录(极危)"),
    (r'\brm\s+-rf?\s+/\*', "rm -rf /* (删根)"),
    (r'\brm\s+-rf?\s+~\s*$', "rm -rf 家目录(极危)"),
    (r'\brm\s+-rf?\s+~/', "rm -rf ~/ (删家目录)"),
    (r'\brm\s+-rf?\s+\*\s*$', "rm -rf * (全删)"),
    (r'mkfs\.\w+\s+/dev/', "格式化磁盘设备"),
    (r'dd\s+.*of=/dev/[sh]d', "dd 写裸磁盘"),
]

# 命令最大长度（ReDoS 防护：正常 shell 命令远小于此值）
MAX_COMMAND_LENGTH = 4096


def _compile_patterns(patterns):
    """预编译正则列表为 (compiled_regex, pattern_str, description)。"""
    result = []
    for pat, desc in patterns:
        try:
            result.append((re.compile(pat), pat, desc))
        except re.error:
            pass  # 无效正则跳过（防御性处理，不应发生）
    return result


# 模块加载时一次性预编译所有正则——避免每次 classify 调用重新 re.search 编译
_GREEN = _compile_patterns(GREEN_PATTERNS)
_YELLOW = _compile_patterns(YELLOW_PATTERNS)
_RED = _compile_patterns(RED_PATTERNS)
_BLACKLIST = _compile_patterns(BLACKLIST_LOCAL)


def _match(patterns, cmd):
    """在命令上依次匹配预编译规则，返回首个命中的描述，未命中返回 None。"""
    for compiled, pat, desc in patterns:
        if compiled.search(cmd):
            return desc
    return None


def classify(tool_name, command):
    """对工具调用做风险分级。

    参数:
        tool_name: Claude Code 工具名（Bash/Edit/Write/Read...）
        command: 工具命令原文（Bash 时为 shell 命令；Edit/Write 时通常为空）
    返回:
        (level, reason)  level ∈ {"green","yellow","red"}
    """
    # 1. 工具级别快速判断
    if tool_name in GREEN_TOOLS:
        return "green", f"read-only tool: {tool_name}"
    if tool_name in YELLOW_TOOLS:
        return "yellow", f"file edit tool: {tool_name}"

    cmd = (command or "").strip()
    if not cmd:
        return "yellow", "empty command"

    # ReDoS 防护：拒绝超长命令
    if len(cmd) > MAX_COMMAND_LENGTH:
        return "red", f"command too long ({len(cmd)} chars), denied for safety"

    # 2. 优先级：黑名单 > 红 > 黄 > 绿 > 默认黄
    if desc := _match(_BLACKLIST, cmd):
        return "red", f"blacklisted: {desc}"
    if desc := _match(_RED, cmd):
        return "red", f"red rule: {desc}"
    if desc := _match(_YELLOW, cmd):
        return "yellow", f"yellow rule: {desc}"
    if desc := _match(_GREEN, cmd):
        return "green", f"green rule: {desc}"

    # 3. 默认：未知命令保守放行+通知（黑名单已兜底高危）
    return "yellow", "unknown command, default yellow"


if __name__ == "__main__":
    # 命令行自测：py risk_classify.py "rm -rf /tmp/x"
    import sys
    if len(sys.argv) > 1:
        lvl, reason = classify("Bash", " ".join(sys.argv[1:]))
        print(f"{lvl}: {reason}")
