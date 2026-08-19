param(
  [string]$Destination = ""
)

$ErrorActionPreference = "Stop"
$sourceRoot = Split-Path -Parent $PSScriptRoot
if (-not $Destination) {
  $Destination = Join-Path (Split-Path -Parent $sourceRoot) ("serein-public-" + (Get-Date -Format "yyyy-MM-dd"))
}

if (Test-Path -LiteralPath $Destination) {
  throw "Destination already exists: $Destination. Choose a new dated directory or remove it after review."
}

$excludedSegments = @(
  ".git", ".claude", ".codex", ".codex-temp-order-audit", "private", "ohos-sdk", "uploads", "output", "_trash",
  ".hvigor", "node_modules", "logs", "build", "out", ".pytest_cache", "__pycache__",
  "tmp", ".idea", "coverage", "shots"
)
$excludedFiles = @(
  "AGENTS.md", "CLAUDE.md", "DESIGN.md", "*.log", "*.db", "*.db-wal", "*.db-shm", "*.hap", "*.exe",
  "*.pyc", "*.pid", "*.tmp", "*.bak", "*.bak-*", "*.exe~", "*.dll", "*.dll~", "*.pdb",
  "build_result*.txt", "func_test_*.py", "test_*.py", "check_db.py", "e2e_ntfy.py", "monitor.py",
  "test_*.txt", "serein-server", "serein-server-linux", "serein-server-linux-stripped",
  "local.properties", ".serein-bound"
)
$excludedDocs = @(
  "docs/domain-switch-guide.md",
  "docs/development-guide.md"
)
$excludedPublicPaths = @(
  # The personal file contains local DevEco signing paths and encrypted passwords.
  # A clean, unsigned profile is generated in the export instead.
  "harmony/build-profile.json5",
  # Personal CI runs private-only Python tests that are intentionally omitted.
  # The public workflow keeps portable package, compile, backend and Docker gates.
  ".github/workflows/ci.yml"
)
$publicDocs = @(
  "docs/DEPLOYMENT.md",
  "docs/SOFTWARE_USER_MANUAL_V1_0.md",
  "docs/PUBLIC_ROADMAP.md",
  "docs/V1_0_PRODUCT_BOUNDARY.md",
  "docs/V1_0_RELEASE_GATE.md",
  "docs/V1_0_STABILITY_RESULTS.md",
  "docs/PUSH_KIT_SETUP.md",
  "docs/WEBSITE_IMPLEMENTATION.md",
  "docs/dev-standards.md",
  "docs/release-checklist.md"
)
$publicScriptFiles = @(
  "scripts/cli.test.js",
  "scripts/doctor-lib.js",
  "scripts/doctor.js",
  "scripts/doctor.test.js",
  "scripts/pre-release-property.test.js",
  "scripts/export-public.ps1",
  "scripts/gen-tokens.sh",
  "scripts/postinstall.js",
  "scripts/release-check.js",
  "scripts/serve-ui.mjs"
)
$publicAgentFiles = @(
  "agent/agent_config.py",
  "agent/agent-registry.mjs",
  "agent/agent-registry.test.mjs",
  "agent/codex-app-events.mjs",
  "agent/codex-app-events.test.mjs",
  "agent/codex-app-server.mjs",
  "agent/codex-app-server.test.mjs",
  "agent/codex-jsonl.mjs",
  "agent/codex-jsonl.test.mjs",
  "agent/codex-pty-prompt.mjs",
  "agent/codex-pty-prompt.test.mjs",
  "agent/codex-thread-lease.mjs",
  "agent/codex-thread-lease.test.mjs",
  "agent/agent_daemon.py",
  "agent/agent_exec.py",
  "agent/agent_proc.py",
  "agent/agent_shell_chain.py",
  "agent/agent_watchdog.vbs",
  "agent/common.py",
  "agent/local_agent.py",
  "agent/remote_host_manager.py",
  "agent/package-lock.json",
  "agent/package.json",
  "agent/serein-jsonl.mjs",
  "agent/serein-jsonl.test.mjs",
  "agent/serein-util.mjs",
  "agent/serein-util.test.mjs",
  "agent/serein-watchdog.mjs",
  "agent/serein-ws.mjs",
  "agent/serein-ws.test.mjs",
  "agent/serein.bat",
  "agent/serein.mjs",
  "agent/sysinfo.py",
  "agent/terminal_client.py",
  "agent/trust-prompt.mjs",
  "agent/trust-prompt.test.mjs"
)
$publicUiFiles = @(
  "ui/index.html",
  "ui/landing.css",
  "ui/landing.js",
  "ui/pet-stories.css",
  "ui/pet-stories.js",
  "ui/water-buttons.js",
  "ui/assets/serein-mark.png",
  "ui/assets/og.png",
  "ui/assets/gsap.min.js",
  "ui/assets/ScrollTrigger.min.js",
  "ui/assets/workflow-scene.bundle.js",
  "ui/assets/serein-workflow.mp4",
  "ui/assets/THIRD_PARTY_NOTICES.md",
  "ui/assets/characters/hero-sofa-pair.png",
  "ui/assets/characters/approval-office-pair.png",
  "ui/assets/characters/agent-floor-pair.png",
  "ui/assets/characters/lounge-phone-pair-summer.png",
  "ui/screenshots/projects-showcase.jpg",
  "ui/screenshots/terminal-showcase.jpg",
  "ui/screenshots/approvals-showcase.jpg",
  "ui/screenshots/community-showcase.jpg",
  "ui/screenshots/remote-showcase.jpg"
)
$textExtensions = @(
  ".md", ".txt", ".json", ".json5", ".js", ".mjs", ".py", ".go", ".sh",
  ".ps1", ".bat", ".vbs", ".ets", ".yml", ".yaml", ".toml", ".html",
  ".css", ".svg", ".conf", ".service"
)

function IsExcludedPath([string]$relativePath) {
  $parts = $relativePath -split "[\\/]"
  foreach ($segment in $parts) {
    if ($excludedSegments -contains $segment) { return $true }
  }
  foreach ($pattern in $excludedFiles) {
    if ([IO.Path]::GetFileName($relativePath) -like $pattern) { return $true }
  }
  $normalized = $relativePath -replace "\\", "/"
  # Root-level screenshots are private QA artifacts, not public source assets.
  $isRootFile = $normalized.IndexOf('/') -lt 0
  $isScreenshot = @(".png", ".jpg", ".jpeg", ".webp") -contains [IO.Path]::GetExtension($normalized).ToLowerInvariant()
  if ($isRootFile -and $isScreenshot) { return $true }
  if ($excludedPublicPaths -contains $normalized) { return $true }
  if ($excludedDocs -contains $normalized) { return $true }
  if ($normalized.StartsWith("docs/") -and ($publicDocs -notcontains $normalized)) { return $true }
  if ($normalized.StartsWith("scripts/") -and ($publicScriptFiles -notcontains $normalized)) { return $true }
  if ($normalized.StartsWith("agent/") -and ($publicAgentFiles -notcontains $normalized)) { return $true }
  if ($normalized.StartsWith("ui/") -and ($publicUiFiles -notcontains $normalized)) { return $true }
  if ($normalized -like "deploy/ntfy/ntfy_2.24.0_windows_amd64/*") { return $true }
  return $false
}

function SanitizePublicText([string]$content) {
  $content = $content.Replace("wss://your-backend.example", "wss://your-backend.example")
  $content = $content.Replace("https://your-backend.example", "https://your-backend.example")
  $content = $content.Replace("https://your-ntfy.example", "https://your-ntfy.example")
  $content = $content.Replace("your-backend.example", "your-backend.example")
  $content = $content.Replace("your-ntfy.example", "your-ntfy.example")
  # Public website links must resolve to the sanitized deployment guide.
  $content = $content.Replace("../docs/DEPLOYMENT.md", "../docs/DEPLOYMENT.md")
  # 泛化个人主目录：用环境变量动态获取，不硬编码用户名
  $realProfile = [System.Environment]::GetFolderPath('UserProfile')
  if ($realProfile) { $content = $content.Replace($realProfile, "C:/Users/YourName") }
  # 文档和脚本里可能出现不同分隔符或未落在当前用户目录下的工作区路径。
  $content = [regex]::Replace($content, '(?i)[A-Z]:[\\/]Users[\\/][^\\/\r\n''"]+', 'C:/Users/YourName')
  $content = [regex]::Replace($content, '(?i)[A-Z]:(?:[\\/]{1,2})hobby(?:[\\/]{1,2})serein', 'C:/workspace/serein')
  $content = $content.Replace("/opt/serein", "/opt/serein")
  return $content
}

function WritePublicBuildProfile([string]$destinationRoot) {
  $target = Join-Path $destinationRoot "harmony/build-profile.json5"
  $targetDir = Split-Path -Parent $target
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
  $profile = @'
{
  "app": {
    "products": [
      {
        "name": "default",
        "compatibleSdkVersion": "6.1.1(24)",
        "runtimeOS": "HarmonyOS",
        "targetSdkVersion": "6.1.1(24)"
      }
    ]
  },
  "modules": [
    {
      "name": "entry",
      "srcPath": "./entry",
      "targets": [
        {
          "name": "default",
          "applyToProducts": ["default"]
        }
      ]
    }
  ]
}
'@
  [IO.File]::WriteAllText($target, $profile, [Text.UTF8Encoding]::new($false))
}

function WritePublicWorkflow([string]$destinationRoot) {
  $target = Join-Path $destinationRoot ".github/workflows/ci.yml"
  $targetDir = Split-Path -Parent $target
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
  $workflow = @'
name: CI

on:
  push:
    branches: [main, master]
  pull_request:

permissions:
  contents: read

jobs:
  cli-package:
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - run: npm test
      - run: npm run release:check

  backend:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.26.x'
          cache-dependency-path: backend/go.sum
      - run: go test ./...
      - run: go vet ./...

  agent:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: agent
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
          cache-dependency-path: agent/package-lock.json
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - run: npm ci
      - run: npm test
      - run: python -m py_compile local_agent.py agent_proc.py agent_exec.py remote_host_manager.py common.py

  hooks:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: hooks
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - run: python -m py_compile approval_hook.py risk_classify.py

  docker:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: docker build -t serein-ci backend
'@
  [IO.File]::WriteAllText($target, $workflow, [Text.UTF8Encoding]::new($false))
}

function AssertPublicExportIsClean([string]$destinationRoot) {
  $forbiddenArtifacts = @(
    "backend/serein-server",
    "backend/serein-server-linux",
    "backend/serein-server-linux-stripped"
  )
  foreach ($relativePath in $forbiddenArtifacts) {
    $candidate = Join-Path $destinationRoot $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath $candidate) {
      throw "Public export blocked by generated artifact: $relativePath"
    }
  }

  $checks = @(
    @{ Name = "private backend domain"; Pattern = "cli\.serein\.run|ntfy\.serein\.run" },
    # 用环境变量动态生成，不硬编码用户名
    @{ Name = "personal Windows path"; Pattern = ("C:\\\\Users\\\\" + [regex]::Escape([System.Environment]::UserName)) },
    @{ Name = "personal workspace path"; Pattern = "(?i)[A-Z]:(?:[\\\\/]{1,2})hobby(?:[\\\\/]{1,2})serein" },
    @{ Name = "Harmony signing password"; Pattern = '"(keyPassword|storePassword)"\s*:' },
    @{ Name = "private signing material"; Pattern = '"(certpath|storeFile|profile)"\s*:\s*"[A-Za-z]:\\' }
  )
  $violations = @()
  foreach ($file in Get-ChildItem -LiteralPath $destinationRoot -File -Recurse -Force) {
    if ($textExtensions -notcontains $file.Extension.ToLowerInvariant()) { continue }
    try {
      $content = [IO.File]::ReadAllText($file.FullName, [Text.UTF8Encoding]::new($false, $true))
    } catch {
      continue
    }
    foreach ($check in $checks) {
      if ($content -match $check.Pattern) {
        $relative = $file.FullName.Substring($destinationRoot.Length).TrimStart('\', '/')
        $violations += "$relative ($($check.Name))"
      }
    }
  }
  if ($violations.Count -gt 0) {
    throw "Public export blocked by sensitive-data scan:`n - $($violations -join "`n - ")"
  }
}

New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$copied = 0
foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force) {
  $relative = $file.FullName.Substring($sourceRoot.Length)
  while ($relative.StartsWith('\') -or $relative.StartsWith('/')) {
    $relative = $relative.Substring(1)
  }
  if (IsExcludedPath $relative) { continue }

  $target = Join-Path $Destination $relative
  $targetDir = Split-Path -Parent $target
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

  if ($textExtensions -contains $file.Extension.ToLowerInvariant()) {
    try {
      $content = [IO.File]::ReadAllText($file.FullName, [Text.UTF8Encoding]::new($false, $true))
      $content = SanitizePublicText $content
      [IO.File]::WriteAllText($target, $content, [Text.UTF8Encoding]::new($false))
    } catch {
      Write-Warning "Skipping non-UTF8 text file: $relative"
      continue
    }
  } else {
    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
  }
  $copied++
}

WritePublicBuildProfile $Destination
WritePublicWorkflow $Destination
AssertPublicExportIsClean $Destination

$manifest = @"
# Serein public export

Generated: $(Get-Date -Format "yyyy-MM-dd")

This directory is the Serein V1.0.0 open-source snapshot. Existing product
features, including Remote Desktop, Collaboration Center and Codex Desktop
integration, are retained; experimental features remain clearly labelled and
are not presented as stable. Private operator configuration, runtime logs, SDK
caches, internal deployment notes and local paths were excluded or sanitized.
HarmonyOS signing configuration is intentionally omitted; configure your own
signing identity in DevEco Studio.
Review `git diff` and run the release checklist before publishing.
"@
[IO.File]::WriteAllText((Join-Path $Destination "PUBLIC-EXPORT.md"), $manifest, [Text.UTF8Encoding]::new($false))
Write-Host "Public export created: $Destination ($copied files)"
