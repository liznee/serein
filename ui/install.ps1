# ════════════════════════════════════════════════════════
# serein 一行安装脚本
#
# 用法（PowerShell）:
#   irm https://www.serein.run/install.ps1 | iex
#
# 或本地执行:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -InstallUrl https://raw.githubusercontent.com/liznee/serein/main
#
# 功能:
#   1. 检查/安装 Node.js 和 Python 前置依赖
#   2. 下载 serein agent 文件到 ~/.serein/
#   3. npm install 安装 Node 依赖
#   4. 配置后端地址和 Token
#   5. 创建 serein 全局命令
#   6. 设置开机自启 watchdog
# ════════════════════════════════════════════════════════

param(
  [string]$Backend = "",
  [string]$Token = "",
  [string]$InstallUrl = "",
  [string]$InstallDir = "",
  [switch]$Force,
  [switch]$Update
)

$ErrorActionPreference = "Stop"

# ── 工具函数 ──
function Write-Step($msg) { Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host "    [!] $msg" -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host "    [X] $msg" -ForegroundColor Red }
function Write-Info($msg)  { Write-Host "    $msg" -ForegroundColor Gray }

# ── 安装目录 ──
if (-not $InstallDir) {
  $InstallDir = Join-Path $env:USERPROFILE ".serein"
}

Write-Host ""
Write-Host "  ╔══════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║     serein 一键安装程序           ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════
# Step 1: 检查前置依赖
# ═══════════════════════════════════════════
Write-Step "检查前置依赖..."

# Node.js
$nodeOk = $false
try {
  $nodeVer = (node --version 2>$null)
  if ($nodeVer) {
    Write-OK "Node.js $nodeVer 已安装"
    $nodeOk = $true
  }
} catch { }

if (-not $nodeOk) {
  Write-Warn "未检测到 Node.js，正在通过 winget 安装..."
  try {
    winget install OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements 2>$null
    # 刷新 PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $nodeVer = (node --version 2>$null)
    if ($nodeVer) {
      Write-OK "Node.js $nodeVer 安装成功"
    } else {
      Write-Err "Node.js 安装失败，请手动安装: https://nodejs.org"
      exit 1
    }
  } catch {
    Write-Err "Node.js 安装失败: $_"
    Write-Err "请手动安装 Node.js: https://nodejs.org"
    exit 1
  }
}

# Python
$pythonOk = $false
try {
  $pyVer = (python --version 2>&1)
  if ($pyVer -and $pyVer -match "Python") {
    Write-OK "Python $pyVer 已安装"
    $pythonOk = $true
  }
} catch { }

if (-not $pythonOk) {
  Write-Warn "未检测到 Python，正在通过 winget 安装..."
  try {
    winget install Python.Python.3.12 --accept-package-agreements --accept-source-agreements 2>$null
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $pyVer = (python --version 2>&1)
    if ($pyVer -and $pyVer -match "Python") {
      Write-OK "Python $pyVer 安装成功"
    } else {
      Write-Warn "Python 自动安装失败，请手动安装: https://python.org"
      Write-Warn "（Python 仅用于后台 watchdog，不影响核心功能）"
    }
  } catch {
    Write-Warn "Python 安装失败: $_"
    Write-Warn "请手动安装 Python: https://python.org"
    Write-Warn "（Python 仅用于后台 watchdog，不影响核心功能）"
  }
}

# ═══════════════════════════════════════════
# Step 2: 创建安装目录
# ═══════════════════════════════════════════
Write-Step "准备安装目录: $InstallDir"

if ((Test-Path $InstallDir) -and -not $Force -and -not $Update) {
  Write-Warn "目录已存在: $InstallDir"
  Write-Info "（重跑本脚本即从 GitHub main 拉取最新版本；使用 -Update 可免确认更新）"
  $choice = Read-Host "    是否覆盖安装？(y/N)"
  if ($choice -ne 'y' -and $choice -ne 'Y') {
    Write-Info "安装已取消"
    exit 0
  }
}

if (-not (Test-Path $InstallDir)) {
  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Write-OK "安装目录就绪"

# ═══════════════════════════════════════════
# Step 3: 下载 serein 文件
# ═══════════════════════════════════════════
Write-Step "下载 serein agent 文件..."

# GitHub 下载基础 URL（可替换为自有 CDN）
$baseUrl = $InstallUrl
if (-not $baseUrl) { $baseUrl = $env:SEREIN_INSTALL_URL }
if (-not $baseUrl) {
  $baseUrl = "https://raw.githubusercontent.com/liznee/serein/main"
}
if ($env:SEREIN_INSTALL_URL) {
  $baseUrl = $env:SEREIN_INSTALL_URL
}

# 需要下载的文件列表
$files = @(
  @{ src = "agent/serein.mjs";         dst = "agent/serein.mjs" },
  @{ src = "agent/serein-jsonl.mjs";   dst = "agent/serein-jsonl.mjs" },
  @{ src = "agent/serein-util.mjs";    dst = "agent/serein-util.mjs" },
  @{ src = "agent/serein-ws.mjs";      dst = "agent/serein-ws.mjs" },
  @{ src = "agent/serein-watchdog.mjs"; dst = "agent/serein-watchdog.mjs" },
  @{ src = "agent/package.json";       dst = "agent/package.json" },
  @{ src = "agent/common.py";          dst = "agent/common.py" },
  @{ src = "agent/local_agent.py";     dst = "agent/local_agent.py" },
  @{ src = "agent/agent_proc.py";      dst = "agent/agent_proc.py" },
  @{ src = "agent/agent_config.py";    dst = "agent/agent_config.py" },
  @{ src = "agent/agent_exec.py";      dst = "agent/agent_exec.py" },
  @{ src = "agent/agent_daemon.py";    dst = "agent/agent_daemon.py" },
  @{ src = "agent/sysinfo.py";         dst = "agent/sysinfo.py" },
  @{ src = "agent/agent_watchdog.vbs"; dst = "agent/agent_watchdog.vbs" },
  @{ src = "agent/serein.bat";         dst = "agent/serein.bat" },
  @{ src = "bin/serein.js";            dst = "bin/serein.js" },
  @{ src = "hooks/approval_hook.py";   dst = "hooks/approval_hook.py" },
  @{ src = "hooks/risk_classify.py";   dst = "hooks/risk_classify.py" },
  @{ src = "VERSION";                  dst = "VERSION" }
)

$downloadOk = $true
foreach ($f in $files) {
  $dstPath = Join-Path $InstallDir $f.dst
  $dstDir = Split-Path $dstPath -Parent
  if (-not (Test-Path $dstDir)) {
    New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
  }
  try {
    $url = "$baseUrl/$($f.src)"
    Invoke-WebRequest -Uri $url -OutFile $dstPath -UseBasicParsing -TimeoutSec 30
    Write-OK "  $($f.dst)"
  } catch {
    Write-Err "  下载失败: $($f.dst) — $_"
    $downloadOk = $false
  }
}

# 如果远程下载失败，尝试从本地复制（开发模式）
if (-not $downloadOk) {
  $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
  if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
  if ($scriptDir -and (Test-Path (Join-Path $scriptDir "agent"))) {
    Write-Warn "远程下载失败，从本地目录复制: $scriptDir"
    foreach ($f in $files) {
      $srcPath = Join-Path $scriptDir $f.src
      $dstPath = Join-Path $InstallDir $f.dst
      if (Test-Path $srcPath) {
        Copy-Item $srcPath $dstPath -Force
        Write-OK "  $($f.dst) (local)"
      }
    }
    $downloadOk = $true
  }
}

if (-not $downloadOk) {
  Write-Err "文件下载失败，请检查网络连接或使用本地安装"
  exit 1
}

# ── 版本信息（下载 VERSION 文件后对比）──
$verFile = Join-Path $InstallDir "VERSION"
$newVer = ""
if (Test-Path $verFile) {
  try { $newVer = (Get-Content $verFile -Raw).Trim() } catch { $newVer = "" }
}
if ($newVer) {
  $verStamp = Join-Path $InstallDir ".installed-version"
  $oldVer = ""
  if (Test-Path $verStamp) { try { $oldVer = (Get-Content $verStamp -Raw).Trim() } catch { $oldVer = "" } }
  if ($oldVer -and $oldVer -ne $newVer) {
    Write-Host "    [↑] 已更新: v$oldVer -> v$newVer" -ForegroundColor Green
  } elseif ($oldVer -eq $newVer) {
    Write-Host "    [=] 已是最新版本 v$newVer" -ForegroundColor Green
  } else {
    Write-Host "    [*] 已安装 v$newVer" -ForegroundColor Green
  }
  Set-Content $verStamp $newVer -Encoding ASCII -NoNewline
} else {
  Write-Warn "未获取到版本信息（VERSION 文件缺失）"
}

# ═══════════════════════════════════════════
# Step 4: npm install
# ═══════════════════════════════════════════
Write-Step "安装 Node.js 依赖 (npm install)..."
$agentDir = Join-Path $InstallDir "agent"
Push-Location $agentDir
try {
  npm install --production 2>&1 | Out-Null
  if (Test-Path "node_modules/node-pty") {
    Write-OK "node-pty 安装成功"
  } else {
    Write-Err "node-pty 安装失败，请手动在 $agentDir 执行 npm install"
  }
  if (Test-Path "node_modules/ws") {
    Write-OK "ws 安装成功"
  }
} finally {
  Pop-Location
}

# ═══════════════════════════════════════════
# Step 5: 配置后端地址和 Token
# ═══════════════════════════════════════════
Write-Step "配置 serein..."

# 默认后端地址
if (-not $Backend) {
  $Backend = "http://localhost:8080"
}

# 交互式输入（如果未通过参数提供）
if (-not $Token) {
  Write-Host ""
  Write-Host "    请输入你的 serein Token（从手机 App 配对页面获取）:" -ForegroundColor Yellow
  $Token = Read-Host "    Token"
}

if (-not $Token) {
  Write-Warn "未设置 Token，稍后可手动配置"
  Write-Warn "在 ~/.claude/settings.json 中添加 env.SEREIN_HOOK_TOKEN"
} else {
  Write-OK "Token 已设置"
}

# 写入 ~/.claude/settings.json
$claudeDir = Join-Path $env:USERPROFILE ".claude"
if (-not (Test-Path $claudeDir)) {
  New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
}
$settingsPath = Join-Path $claudeDir "settings.json"
$settings = @{}
if (Test-Path $settingsPath) {
  try {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json -AsHashtable
  } catch { $settings = @{} }
}
if (-not $settings.ContainsKey("env")) {
  $settings["env"] = @{}
}
$settings["env"]["SEREIN_BACKEND"] = $Backend
if ($Token) {
  $settings["env"]["SEREIN_HOOK_TOKEN"] = $Token
}
$settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
Write-OK "配置已写入 ~/.claude/settings.json"

# ═══════════════════════════════════════════
# Step 6: 创建全局 serein 命令
# ═══════════════════════════════════════════
Write-Step "创建 serein 命令..."

# 创建 serein.cmd 到 npm 全局 bin 目录
$npmGlobalBin = (npm config get prefix 2>$null)
if ($npmGlobalBin) {
  $cmdPath = Join-Path $npmGlobalBin "serein.cmd"
  $binJs = Join-Path $InstallDir "bin\serein.js"
  $cmdContent = @"
@echo off
set "SEREIN_AGENT_DIR=$agentDir"
node "$binJs" %*
"@
  Set-Content $cmdPath $cmdContent -Encoding ASCII
  Write-OK "serein 命令已安装到 $cmdPath"
} else {
  # 回退：将安装目录加入 PATH
  Write-Warn "无法确定 npm 全局 bin 目录，将安装目录加入 PATH"
  $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
  if ($userPath -notlike "*$InstallDir*") {
    [System.Environment]::SetEnvironmentVariable("PATH", "$userPath;$InstallDir", "User")
    Write-OK "已将 $InstallDir 添加到用户 PATH"
  }
}

# ═══════════════════════════════════════════
# Step 7: 设置开机自启 watchdog
# ═══════════════════════════════════════════
Write-Step "配置开机自启..."

$startupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$shortcutPath = Join-Path $startupDir "serein-watchdog.lnk"
$vbsPath = Join-Path $agentDir "agent_watchdog.vbs"

try {
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = "wscript.exe"
  $shortcut.Arguments = "`"$vbsPath`""
  $shortcut.WorkingDirectory = $agentDir
  $shortcut.WindowStyle = 7  # Minimized
  $shortcut.Save()
  Write-OK "开机自启已配置: $shortcutPath"
} catch {
  Write-Warn "开机自启配置失败: $_"
  Write-Warn "可手动将 $vbsPath 的快捷方式放入启动文件夹"
}

# ═══════════════════════════════════════════
# Step 8: 启动 watchdog
# ═══════════════════════════════════════════
Write-Step "启动 serein watchdog..."
try {
  Start-Process "wscript.exe" -ArgumentList "`"$vbsPath`"" -WindowStyle Hidden
  Write-OK "watchdog 已启动"
} catch {
  Write-Warn "watchdog 启动失败: $_"
}

# ═══════════════════════════════════════════
# 完成
# ═══════════════════════════════════════════
Write-Host ""
Write-Host "  ╔══════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║       serein 安装完成!               ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  安装目录: $InstallDir" -ForegroundColor Gray
Write-Host "  后端地址: $Backend" -ForegroundColor Gray
Write-Host ""
Write-Host "  使用方法:" -ForegroundColor Cyan
Write-Host "    serein              - 在当前目录启动" -ForegroundColor White
Write-Host "    serein <project>    - 启动指定项目" -ForegroundColor White
Write-Host "    serein --qr         - 显示配对二维码" -ForegroundColor White
Write-Host ""
Write-Host "  打开手机 serein App 扫码配对即可开始使用" -ForegroundColor Cyan
Write-Host ""
