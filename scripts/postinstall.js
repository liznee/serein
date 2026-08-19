#!/usr/bin/env node
/**
 * serein setup — 用户明确执行后配置 ~/.claude/settings.json
 *
 * 自动完成：
 *   1. 生成 HOOK_TOKEN（如果不存在）
 *   2. 合并 env 变量到 ~/.claude/settings.json
 *   3. 合并 PreToolUse hook 配置（绝对路径自动填充）
 *   4. 迁移已有硬编码项目到 ~/.serein/projects.json
 *
 * 用户只需 `npm install -g @serein/cli`，无需任何手动配置。
 */
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { execSync } = require('child_process');

// ── 路径常量 ──
const PKG_ROOT = path.resolve(__dirname, '..');
const HOME = os.homedir();
const CLAUDE_DIR = path.join(HOME, '.claude');
const SETTINGS_PATH = path.join(CLAUDE_DIR, 'settings.json');
const SEREIN_CONFIG_DIR = path.join(HOME, '.serein');
const PROJECTS_FILE = path.join(SEREIN_CONFIG_DIR, 'projects.json');
const HOOKS_DIR = path.join(PKG_ROOT, 'hooks');
const HOOK_SCRIPT = path.join(HOOKS_DIR, 'approval_hook.py');
const DEFAULT_BACKEND = process.env.SEREIN_BACKEND || 'http://localhost:8080';

// ── ANSI 颜色 ──
const C = {
  reset: '\x1b[0m',
  cyan: '\x1b[36m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  red: '\x1b[31m',
  dim: '\x1b[2m',
  bold: '\x1b[1m',
};

function log(msg) { console.log(msg); }
function ok(msg) { console.log(C.green + '  ✓ ' + C.reset + msg); }
function warn(msg) { console.log(C.yellow + '  ⚠ ' + C.reset + msg); }
function fail(msg) { console.log(C.red + '  ✗ ' + C.reset + msg); }

// ════════════════════════════════════════════
// 工具函数
// ════════════════════════════════════════════

/**
 * 安全读取 JSON 文件，不存在或解析失败返回 {}
 */
function readJSON(filePath) {
  try {
    const raw = fs.readFileSync(filePath, 'utf-8');
    return JSON.parse(raw);
  } catch (e) {
    if (e.code !== 'ENOENT') {
      warn('读取 ' + filePath + ' 失败: ' + e.message);
    }
    return {};
  }
}

/**
 * 安全写入 JSON 文件（格式化）
 */
function writeJSON(filePath, data) {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2), 'utf-8');
}

/**
 * 生成随机 HOOK_TOKEN（48 字符 hex = 24 字节随机数）
 */
function generateToken() {
  return crypto.randomBytes(24).toString('hex');
}

/**
 * 查找 Python 可执行文件
 * 返回完整的 hook 命令字符串
 */
function findPythonHookCommand() {
  // 1. 环境变量指定
  if (process.env.SEREIN_PYTHON) {
    return '"' + process.env.SEREIN_PYTHON + '" "' + HOOK_SCRIPT + '"';
  }

  // 2. 尝试常见命令
  const candidates = process.platform === 'win32'
    ? ['python', 'py', 'python3']
    : ['python3', 'python'];

  for (const cmd of candidates) {
    try {
      execSync(cmd + ' --version', { stdio: 'pipe', timeout: 5000 });
      return cmd + ' "' + HOOK_SCRIPT + '"';
    } catch {
      // 尝试下一个
    }
  }

  // 3. Windows 常见安装路径
  if (process.platform === 'win32') {
    const winPaths = [
      path.join(HOME, 'AppData', 'Local', 'Programs', 'Python', 'Python313', 'python.exe'),
      path.join(HOME, 'AppData', 'Local', 'Programs', 'Python', 'Python312', 'python.exe'),
      path.join(HOME, 'AppData', 'Local', 'Programs', 'Python', 'Python311', 'python.exe'),
    ];
    for (const p of winPaths) {
      if (fs.existsSync(p)) {
        return '"' + p + '" "' + HOOK_SCRIPT + '"';
      }
    }
  }

  warn('未找到 Python，hook 命令使用 "python" 占位');
  warn('请安装 Python 3.10+ 并确保在 PATH 中，或设置 SEREIN_PYTHON 环境变量');
  return 'python "' + HOOK_SCRIPT + '"';
}

/**
 * 检查 hook 配置是否已存在（避免重复添加）
 */
function findExistingHook(hooks, matcherPattern) {
  if (!Array.isArray(hooks.PreToolUse)) return null;
  for (const entry of hooks.PreToolUse) {
    if (entry.matcher === matcherPattern) return entry;
  }
  return null;
}

// ════════════════════════════════════════════
// 主流程
// ════════════════════════════════════════════

function main() {
  console.log('');
  console.log(C.cyan + C.bold + '  serein — 安装配置' + C.reset);
  console.log(C.dim + '  自动配置 ~/.claude/settings.json' + C.reset);
  console.log('');

  // ── 1. 检查 hook 脚本是否存在 ──
  if (!fs.existsSync(HOOK_SCRIPT)) {
    fail('hook 脚本不存在: ' + HOOK_SCRIPT);
    fail('安装可能不完整，请重新安装');
    process.exit(1);
  }
  ok('hook 脚本: ' + HOOK_SCRIPT);

  // ── 2. 读取现有 settings.json ──
  const settings = readJSON(SETTINGS_PATH);
  if (!settings.env) settings.env = {};
  if (!settings.hooks) settings.hooks = {};

  let changed = false;

  // ── 3. 生成/保留 HOOK_TOKEN ──
  if (!settings.env.SEREIN_HOOK_TOKEN) {
    settings.env.SEREIN_HOOK_TOKEN = process.env.SEREIN_HOOK_TOKEN || generateToken();
    ok('生成 HOOK_TOKEN: ' + settings.env.SEREIN_HOOK_TOKEN.substring(0, 12) + '...');
    changed = true;
  } else {
    ok('保留已有 HOOK_TOKEN');
  }

  // ── 4. 设置后端地址 ──
  if (!settings.env.SEREIN_BACKEND) {
    settings.env.SEREIN_BACKEND = DEFAULT_BACKEND;
    ok('设置后端地址: ' + DEFAULT_BACKEND);
    changed = true;
  } else {
    ok('保留已有后端地址: ' + settings.env.SEREIN_BACKEND);
  }

  // ── 5. 设置 hook 超时 ──
  if (!settings.env.SEREIN_HOOK_TIMEOUT) {
    settings.env.SEREIN_HOOK_TIMEOUT = '300';
    changed = true;
  }

  // ── 6. 合并 hook 配置 ──
  const hookCommand = findPythonHookCommand();
  const matcher = 'Bash|Edit|Write|NotebookEdit';

  let existing = findExistingHook(settings.hooks, matcher);
  if (!existing) {
    // 新增 hook 配置
    settings.hooks.PreToolUse = settings.hooks.PreToolUse || [];
    settings.hooks.PreToolUse.push({
      matcher: matcher,
      hooks: [{
        type: 'command',
        command: hookCommand,
        timeout: 360,
      }],
    });
    ok('添加 PreToolUse hook');
    changed = true;
  } else {
    // 已有 hook，更新命令路径（确保指向正确位置）
    if (existing.hooks && existing.hooks[0]) {
      const oldCmd = existing.hooks[0].command || '';
      if (oldCmd.indexOf(HOOK_SCRIPT) === -1) {
        // 旧 hook 指向其他脚本，保留但添加 serein hook
        settings.hooks.PreToolUse.push({
          matcher: matcher,
          hooks: [{
            type: 'command',
            command: hookCommand,
            timeout: 360,
          }],
        });
        ok('添加 serein PreToolUse hook（已有其他 hook 保留）');
        changed = true;
      } else {
        // 已指向 serein hook，更新命令确保路径正确
        existing.hooks[0].command = hookCommand;
        ok('更新已有 hook 命令路径');
        changed = true;
      }
    }
  }

  // ── 7. 写回 settings.json ──
  if (changed) {
    writeJSON(SETTINGS_PATH, settings);
    ok('写入 ~/.claude/settings.json');
  } else {
    ok('settings.json 无需修改');
  }

  // ── 8. 设置开机自启 watchdog（Windows）──
  if (process.platform === 'win32') {
    setupWatchdog();
  }

  // ── 9. 打印使用说明 ──
  printUsage(settings.env.SEREIN_HOOK_TOKEN, settings.env.SEREIN_BACKEND);
}

/**
 * 设置 Windows 开机自启 watchdog（agent_watchdog.vbs 快捷方式）
 */
function setupWatchdog() {
  const vbsPath = path.join(PKG_ROOT, 'agent', 'agent_watchdog.vbs');
  if (!fs.existsSync(vbsPath)) {
    warn('watchdog VBS 不存在，跳过开机自启配置: ' + vbsPath);
    return;
  }

  const startupDir = path.join(HOME, 'AppData', 'Roaming',
    'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup');
  const shortcutPath = path.join(startupDir, 'serein-watchdog.lnk');

  try {
    // 使用 PowerShell 创建快捷方式（不依赖 WScript.Shell COM）
    const psCmd = `
      $s = (New-Object -ComObject WScript.Shell).CreateShortcut('${shortcutPath}')
      $s.TargetPath = 'wscript.exe'
      $s.Arguments = '"${vbsPath}"'
      $s.WorkingDirectory = '${path.dirname(vbsPath)}'
      $s.WindowStyle = 7
      $s.Save()
    `.trim();
    execSync(`powershell -NoProfile -Command "${psCmd.replace(/"/g, '\"')}"`,
      { stdio: 'pipe', timeout: 10000 });
    ok('开机自启已配置: serein-watchdog.lnk');

    // 立即启动 watchdog
    execSync(`wscript.exe "${vbsPath}"`, { stdio: 'ignore', timeout: 5000, detached: true });
    ok('watchdog 已启动');
  } catch (e) {
    warn('开机自启配置失败: ' + e.message);
    warn('可手动将 agent_watchdog.vbs 的快捷方式放入启动文件夹');
  }
}

/**
 * 打印使用说明
 */
function printUsage(hookToken, backend) {
  console.log('');
  console.log(C.cyan + C.bold + '  ════════════════════════════════════════' + C.reset);
  console.log(C.cyan + C.bold + '  serein 安装完成！' + C.reset);
  console.log(C.cyan + C.bold + '  ════════════════════════════════════════' + C.reset);
  console.log('');
  console.log('  ' + C.bold + '快速开始：' + C.reset);
  console.log('');
  console.log('  1. 进入任意项目目录');
  console.log('     ' + C.dim + 'cd C:\\YourProject' + C.reset);
  console.log('');
  console.log('  2. 启动 serein');
  console.log('     ' + C.dim + 'serein' + C.reset);
  console.log('     ' + C.dim + '→ 终端显示二维码 + 启动 Claude Code' + C.reset);
  console.log('');
  console.log('  3. 手机 App 扫码绑定项目');
  console.log('     ' + C.dim + '打开 App → 项目页 → 📷 扫码' + C.reset);
  console.log('');
  console.log('  4. 按 Enter 启动 Claude，手机实时同步');
  console.log('');
  console.log('  ' + C.bold + '其他命令：' + C.reset);
  console.log('     serein --qr     ' + C.dim + '仅显示二维码（不启动 Claude）' + C.reset);
  console.log('     serein --daemon ' + C.dim + '后台模式（手机 Start 触发）' + C.reset);
  console.log('');
  console.log('  ' + C.bold + '配置信息：' + C.reset);
  console.log('     后端:     ' + C.dim + (backend || '(未配置，请设置 SEREIN_BACKEND)') + C.reset);
  console.log('     Token:    ' + C.dim + hookToken.substring(0, 12) + '...' + C.reset);
  console.log('     配置文件: ' + C.dim + '~/.claude/settings.json' + C.reset);
  console.log('     项目注册: ' + C.dim + '~/.serein/projects.json' + C.reset);
  console.log('');
  console.log('  ' + C.yellow + '⚠ 首次使用需在手机 App 完成设备配对' + C.reset);
  console.log('     ' + C.dim + '浏览器访问 ' + (backend || '你的后端地址') + '/pair 获取配对码' + C.reset);
  console.log('');
}

// ── 运行 ──
try {
  main();
} catch (e) {
  console.error('');
  fail('postinstall 失败: ' + (e.message || e));
  console.error(e.stack);
  // 不 exit(1) — postinstall 失败不应阻断 npm install
  console.log('');
  warn('serein 配置未完成，请手动运行: node ' + path.join(PKG_ROOT, 'scripts', 'postinstall.js'));
}
