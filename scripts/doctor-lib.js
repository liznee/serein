'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const TOKEN_RE = /^[a-zA-Z0-9._-]+$/;

function makeCheck(id, status, message, detail) {
  return { id, status, message, ...(detail ? { detail } : {}) };
}

function commandVersion(command, args = ['--version']) {
  try {
    const isWindowsScript = process.platform === 'win32' && /\.(?:cmd|bat)$/i.test(command);
    const result = isWindowsScript
      ? spawnSync(`"${command}" ${args.join(' ')}`, {
          shell: process.env.ComSpec || 'C:\\Windows\\System32\\cmd.exe',
          encoding: 'utf8',
          timeout: 5000,
          windowsHide: true,
        })
      : spawnSync(command, args, {
      encoding: 'utf8',
      timeout: 5000,
      windowsHide: true,
        });
    if (result.status !== 0) return null;
    return String(result.stdout || result.stderr || '').trim().split(/\r?\n/)[0] || null;
  } catch {
    return null;
  }
}

function findAgentCli(name) {
  if (process.platform === 'win32') {
    try {
      const where = spawnSync('C:\\Windows\\System32\\where.exe', [name], {
        encoding: 'utf8',
        timeout: 5000,
        windowsHide: true,
      });
      if (where.status === 0) {
        const cliPaths = String(where.stdout || '').trim().split(/\r?\n/).filter(Boolean);
        cliPaths.sort((left, right) => {
          const leftCmd = /\.cmd$/i.test(left) ? 0 : 1;
          const rightCmd = /\.cmd$/i.test(right) ? 0 : 1;
          return leftCmd - rightCmd;
        });
        for (const cliPath of cliPaths) {
          const version = commandVersion(cliPath, ['--version']);
          if (version) return { path: cliPath, version };
        }
      }
    } catch {
      return null;
    }
    return null;
  }
  const version = commandVersion(name, ['--version']);
  return version ? { path: name, version } : null;
}

function findPython() {
  const configured = process.env.SEREIN_PYTHON;
  const candidates = configured
    ? [[configured, ['--version']]]
    : process.platform === 'win32'
      ? [['python', ['--version']], ['py', ['--version']], ['python3', ['--version']]]
      : [['python3', ['--version']], ['python', ['--version']]];

  for (const [command, args] of candidates) {
    const version = commandVersion(command, args);
    if (version) return { command, version };
  }
  return null;
}

function readJson(filePath) {
  try {
    return { exists: true, value: JSON.parse(fs.readFileSync(filePath, 'utf8')) };
  } catch (error) {
    if (error && error.code === 'ENOENT') return { exists: false, value: null };
    return { exists: true, value: null, error: error.message };
  }
}

function findSereinHook(settings) {
  const entries = settings?.hooks?.PreToolUse;
  if (!Array.isArray(entries)) return null;
  for (const entry of entries) {
    for (const hook of Array.isArray(entry?.hooks) ? entry.hooks : []) {
      if (typeof hook?.command === 'string' && /approval_hook\.py/i.test(hook.command)) {
        return hook.command;
      }
    }
  }
  return null;
}

function normalizeBackend(raw) {
  if (!raw) return { error: '未配置 SEREIN_BACKEND' };
  try {
    const url = new URL(raw);
    if (!['http:', 'https:'].includes(url.protocol)) {
      return { error: '后端地址必须使用 http:// 或 https://' };
    }
    url.username = '';
    url.password = '';
    url.hash = '';
    url.search = '';
    url.pathname = url.pathname.replace(/\/+$/, '');
    return { url };
  } catch {
    return { error: 'SEREIN_BACKEND 不是有效 URL' };
  }
}

function isLoopback(hostname) {
  return ['localhost', '127.0.0.1', '::1', '[::1]'].includes(hostname.toLowerCase());
}

function redactHome(value, home) {
  if (!value || !home) return value;
  const normalizedValue = String(value).replace(/\\/g, '/');
  const normalizedHome = String(home).replace(/\\/g, '/').replace(/\/+$/, '');
  return normalizedValue.toLowerCase().startsWith(normalizedHome.toLowerCase())
    ? '~' + normalizedValue.slice(normalizedHome.length)
    : value;
}

async function probeBackend(baseUrl, timeoutMs = 5000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const healthUrl = new URL(baseUrl.toString());
    healthUrl.pathname = healthUrl.pathname.replace(/\/+$/, '') + '/healthz';
    const response = await fetch(healthUrl, {
      method: 'GET',
      headers: { accept: 'application/json, text/plain;q=0.8' },
      redirect: 'error',
      signal: controller.signal,
    });
    const body = (await response.text()).slice(0, 300);
    if (!response.ok) return { ok: false, message: `HTTP ${response.status}`, detail: body };
    return { ok: true, message: `HTTP ${response.status}`, detail: body };
  } catch (error) {
    const message = error?.name === 'AbortError' ? `${timeoutMs}ms 超时` : error.message;
    return { ok: false, message };
  } finally {
    clearTimeout(timer);
  }
}

async function runDoctor(options = {}) {
  const root = options.root || path.resolve(__dirname, '..');
  const home = options.home || os.homedir();
  const env = options.env || process.env;
  const checks = [];
  const add = (id, status, message, detail) => checks.push(makeCheck(id, status, message, detail));

  const nodeMajor = Number(process.versions.node.split('.')[0]);
  add('node', nodeMajor >= 18 ? 'pass' : 'error', `Node.js ${process.versions.node}`, nodeMajor >= 18 ? undefined : '需要 Node.js 18 或更高版本');

  const requiredFiles = [
    'bin/serein.js',
    'agent/serein.mjs',
    'agent/local_agent.py',
    'hooks/approval_hook.py',
  ];
  const missing = requiredFiles.filter(file => !fs.existsSync(path.join(root, file)));
  add('installation', missing.length ? 'error' : 'pass', missing.length ? '安装文件不完整' : '核心安装文件完整', missing.join(', '));

  const python = options.findPython ? options.findPython() : findPython();
  add('python', python ? 'pass' : 'error', python ? `${python.version} (${path.basename(python.command)})` : '未找到 Python', python ? undefined : '安装 Python 3.10+，或设置 SEREIN_PYTHON');

  const settingsPath = path.join(home, '.claude', 'settings.json');
  const settingsResult = readJson(settingsPath);
  const settings = settingsResult.value || {};
  const configEnv = settings.env || {};
  const agentType = String(env.SEREIN_AGENT_TYPE || configEnv.SEREIN_AGENT_TYPE || 'claude').trim().toLowerCase();
  const supportedAgents = new Set(['claude', 'codex']);
  if (!settingsResult.exists) {
    if (agentType === 'codex' && env.SEREIN_BACKEND && env.SEREIN_HOOK_TOKEN) {
      add('settings', 'pass', 'Codex 使用当前环境变量配置', '仅会话同步不要求 Claude Code settings.json');
    } else {
      add('settings', 'error', '未找到 ~/.claude/settings.json', '运行 serein setup，或为 Codex 显式设置 SEREIN_BACKEND 与 SEREIN_HOOK_TOKEN');
    }
  } else if (settingsResult.error) add('settings', 'error', 'settings.json 不是有效 JSON', settingsResult.error);
  else add('settings', 'pass', 'Serein / Claude Code 配置可读取');

  if (!supportedAgents.has(agentType)) {
    add('agent_cli', 'error', `不支持的 SEREIN_AGENT_TYPE: ${agentType}`, '可选值：claude、codex');
  } else {
    const agentCli = options.findAgentCli
      ? options.findAgentCli(agentType)
      : options.commandVersion
        ? (options.commandVersion(agentType, ['--version']) ? { path: agentType } : null)
        : findAgentCli(agentType);
    const agentExeEnv = agentType === 'codex' ? 'CODEX_EXE' : 'CLAUDE_EXE';
    add('agent_cli', agentCli ? 'pass' : 'warn', agentCli ? `已找到可执行的 ${agentType} CLI` : `未找到可执行的 ${agentType} CLI`, agentCli ? redactHome(agentCli.path, home) : `仅安装桌面 App 不一定会提供可由终端启动的 CLI；也可以通过 ${agentExeEnv} 指定路径`);
    if (agentType === 'codex') {
      add('agent_capabilities', 'warn', 'Codex 结构化会话适配已启用（实验性）', '回复、思考和工具事件可同步；工具审批尚未达到 Claude Code 的完整兼容级别');
    } else {
      add('agent_capabilities', 'pass', 'Claude Code 结构化会话与审批能力可用');
    }
  }

  const backendRaw = env.SEREIN_BACKEND || configEnv.SEREIN_BACKEND || '';
  const token = env.SEREIN_HOOK_TOKEN || configEnv.SEREIN_HOOK_TOKEN || '';
  const backend = normalizeBackend(backendRaw);
  if (backend.error) add('backend_config', 'error', backend.error, '运行 serein setup 或设置 SEREIN_BACKEND');
  else if (backend.url.protocol === 'http:' && !isLoopback(backend.url.hostname)) add('backend_config', 'warn', `后端 ${backend.url.origin} 使用明文 HTTP`, '远程部署请使用 HTTPS');
  else add('backend_config', 'pass', `后端 ${backend.url.origin}${backend.url.pathname}`);

  if (!token) add('hook_token', 'error', '未配置 SEREIN_HOOK_TOKEN', '运行 serein setup');
  else if (!TOKEN_RE.test(token)) add('hook_token', 'error', 'HOOK_TOKEN 包含不支持的字符', '仅使用字母、数字、点、下划线和连字符');
  else if (token.length < 24) add('hook_token', 'warn', 'HOOK_TOKEN 长度偏短', '建议使用 serein setup 生成至少 24 字符的随机 Token');
  else add('hook_token', 'pass', 'HOOK_TOKEN 已配置（内容已隐藏）');

  const hookCommand = findSereinHook(settings);
  if (agentType === 'codex') add('hook', 'pass', 'Codex 会话同步不依赖 Claude Code Hook', 'Codex 工具审批仍是实验性能力');
  else if (!hookCommand) add('hook', 'error', '未找到 Serein PreToolUse Hook', '运行 serein setup');
  else if (!/Bash|Edit|Write|NotebookEdit/i.test(JSON.stringify(settings.hooks.PreToolUse))) add('hook', 'warn', 'Hook 已配置，但 matcher 可能不完整');
  else add('hook', 'pass', 'Serein PreToolUse Hook 已配置');

  const projectsPath = path.join(home, '.serein', 'projects.json');
  const projectsResult = readJson(projectsPath);
  if (!projectsResult.exists) add('projects', 'warn', '尚未注册项目', '首次运行 serein pair 或 serein 后会自动创建');
  else if (projectsResult.error) add('projects', 'error', 'projects.json 不是有效 JSON', projectsResult.error);
  else {
    const count = Array.isArray(projectsResult.value)
      ? projectsResult.value.length
      : Object.keys(projectsResult.value || {}).length;
    add('projects', 'pass', `已注册 ${count} 个项目`);
  }

  if (backend.url && options.skipNetwork !== true) {
    const probe = options.probeBackend
      ? await options.probeBackend(backend.url)
      : await probeBackend(backend.url, options.timeoutMs || 5000);
    add('backend_health', probe.ok ? 'pass' : 'error', probe.ok ? `后端可访问（${probe.message}）` : `后端不可访问：${probe.message}`, probe.ok ? undefined : probe.detail);
  }

  const summary = checks.reduce((acc, item) => {
    acc[item.status] += 1;
    return acc;
  }, { pass: 0, warn: 0, error: 0 });

  return {
    version: require(path.join(root, 'package.json')).version,
    platform: `${process.platform}/${process.arch}`,
    checks,
    summary,
  };
}

module.exports = {
  commandVersion,
  findAgentCli,
  findPython,
  findSereinHook,
  normalizeBackend,
  probeBackend,
  readJson,
  runDoctor,
};
